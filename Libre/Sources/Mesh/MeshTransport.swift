// MeshTransport.swift
// Pasa: link layer. Apple MultipeerConnectivity finds nearby devices and opens encrypted
// links over peer-to-peer Wi-Fi (Bluetooth is only used by the OS for discovery, if at all).
// This file only moves bytes between directly connected devices. Multi-hop routing lives in
// RelayEngine, which is our own code.
//
// Threading: MultipeerConnectivity calls delegates on its own private queues. This class keeps
// its small mutable state behind a lock and reports everything through a @Sendable callback.
// MeshService hops those events to the main actor. Every call INTO MultipeerConnectivity that
// starts, stops or invites (start/stop advertising and browsing, invitePeer, cancelConnectPeer,
// disconnect) runs on the main thread: the watchdog timer fires on the main queue and delegate
// callbacks hop to main before they invite.
//
// Reconnect: links drop (phone screen off, app backgrounded, Wi-Fi hiccup, an invite that times
// out, or a session stuck in "connecting"). A watchdog timer re-invites nearby peers with
// exponential backoff and cancels links stuck in "connecting". The browser keeps running and
// reports peers again on its own, so a dropped link does NOT restart discovery. Restarts
// (stop, settle 1.5 s, start, at most one per 15 s, never overlapping) only happen after the Mac
// wakes, for a forced relay reset, or when the mesh has been stale for 2 minutes. See
// DiscoveryRestartPolicy (crash fix, Oct 9 2026 8:37 PM: rapid, overlapping stop/start from
// several queues raced CFNetService teardown inside MultipeerConnectivity).

import Foundation
import MultipeerConnectivity

enum PeerLinkState: String, Sendable {
    case discovered   // seen nearby, not connected
    case connecting
    case connected
    case disconnected
}

enum TransportEvent: Sendable {
    case found(String)
    case lost(String)
    case state(String, PeerLinkState)
    case received(Data, from: String)
    case problem(String)
}

final class MeshTransport: NSObject, @unchecked Sendable {
    static let serviceType = "libre-mesh"   // must match NSBonjourServices (_libre-mesh._tcp / _udp)
    static let maxNameBytes = 63            // MCPeerID displayName limit (UTF-8 bytes)

    // Reconnect tuning (seconds).
    static let inviteTimeout: TimeInterval = 12
    static let connectingLimit: TimeInterval = 20      // cancel a link stuck in "connecting" after this
    static let watchdogInterval: TimeInterval = 3
    static let maxBackoff: TimeInterval = 30
    static let bothSidesInviteAfter = 3                // after this many failures, either side may invite
    static let passiveSideWaits: TimeInterval = 15     // or once a peer has sat unlinked this long
    static let minSessionResetGap: TimeInterval = 30   // forced relay: restart the session at most this often

    let displayName: String

    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let onEvent: @Sendable (TransportEvent) -> Void

    private let lock = NSLock()
    private var blocked: Set<String>
    private var discovered: [String: MCPeerID] = [:]
    private var running = false

    // Reconnect state, all guarded by `lock`.
    private var failures: [String: Int] = [:]          // consecutive failed link attempts per peer
    private var nextInviteAt: [String: Date] = [:]     // backoff: do not invite before this time
    private var inviteSentAt: [String: Date] = [:]     // invite in flight
    private var connectingSince: [String: Date] = [:]
    private var unlinkedSince: [String: Date] = [:]    // first seen nearby without a link
    private var lastSessionReset = Date.distantPast
    private var lastFound = Date.distantPast
    private var watchdog: DispatchSourceTimer?

    // Restart state machine: main thread only.
    private var policy = DiscoveryRestartPolicy()
    private var deferredRestart: DispatchWorkItem?
    /// Clock (tests and debugging).
    var now: () -> Date = { Date() }

    init(displayName: String, blocked: Set<String>, onEvent: @escaping @Sendable (TransportEvent) -> Void) {
        let name = MeshTransport.sanitize(displayName)
        let peerID = MCPeerID(displayName: name)
        self.displayName = name
        self.myPeerID = peerID
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: MeshTransport.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: peerID, serviceType: MeshTransport.serviceType)
        self.onEvent = onEvent
        self.blocked = blocked
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    /// MCPeerID crashes on an empty name or one longer than 63 UTF-8 bytes.
    static func sanitize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Pasa device" }
        while name.utf8.count > maxNameBytes { name.removeLast() }
        return name
    }

    // MARK: Control

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard policy.begin(now: now()) else { return }
        lock.lock()
        running = true
        lock.unlock()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startWatchdog()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        policy.shutdown()
        deferredRestart?.cancel()
        deferredRestart = nil
        lock.lock()
        running = false
        discovered.removeAll()
        failures.removeAll()
        nextInviteAt.removeAll()
        inviteSentAt.removeAll()
        connectingSince.removeAll()
        unlinkedSince.removeAll()
        let timer = watchdog
        watchdog = nil
        lock.unlock()
        timer?.cancel()
        // Delegates first, so no callback lands on a half-stopped transport.
        advertiser.delegate = nil
        browser.delegate = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        session.delegate = nil
    }

    /// Restarts performed since start (debug counter for the Mac dashboard and the connection sheet).
    var restartCount: Int { policy.restartCount }
    /// Restart requests folded into another restart or deferred by the 15 s gap.
    var coalescedRestarts: Int { policy.coalescedCount }

    /// Asks for a discovery restart. Main thread only. The policy decides:
    /// - foreground with the browser running: no restart, re-invite the peers already found;
    /// - inside the 15 s gap: deferred to the end of the gap (one pending restart at most);
    /// - otherwise: stop advertising and browsing, wait 1.5 s, start them again (same objects).
    /// Connected links are kept.
    func restartDiscovery(_ reason: DiscoveryRestartPolicy.Reason) {
        dispatchPrecondition(condition: .onQueue(.main))
        apply(policy.request(reason, now: now()), reason: reason)
    }

    private func apply(_ action: DiscoveryRestartPolicy.Action, reason: DiscoveryRestartPolicy.Reason) {
        switch action {
        case .none:
            if reason == .foreground { reinviteFound() }
        case .deferUntil(let at):
            scheduleDeferred(at: at)
        case .stop(let settle):
            performStop(settle: settle)
        }
    }

    private func scheduleDeferred(at: Date) {
        guard deferredRestart == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredRestart = nil
            let action = self.policy.firePending(now: self.now())
            self.apply(action, reason: .stale)
        }
        deferredRestart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, at.timeIntervalSince(now())), execute: item)
    }

    private func performStop(settle: TimeInterval) {
        // Read MultipeerConnectivity state before taking our lock (never call into MC while holding it).
        let linked = Set(session.connectedPeers.map { $0.displayName })
        lock.lock()
        // Discovered-but-unlinked peers are forgotten until the browser reports them again, so a
        // device that left (or an old install) is not invited forever.
        discovered = discovered.filter { linked.contains($0.key) }
        inviteSentAt.removeAll()
        lock.unlock()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, self.policy.stopSettled() else { return }
            self.advertiser.startAdvertisingPeer()
            self.browser.startBrowsingForPeers()
            if let next = self.policy.started(now: self.now()) { self.scheduleDeferred(at: next) }
        }
    }

    /// Foreground: give every found, unlinked peer a fresh invite chance (backoff cleared).
    private func reinviteFound() {
        lock.lock()
        let peers = Array(discovered.values)
        for p in peers where connectingSince[p.displayName] == nil {
            nextInviteAt.removeValue(forKey: p.displayName)
            inviteSentAt.removeValue(forKey: p.displayName)
        }
        lock.unlock()
        for peer in peers where shouldInvite(peer) { invite(peer) }
    }

    /// Forced relay: blocking refuses invites both ways, rejects the connection handshake (which
    /// also covers MultipeerConnectivity joining two peers of the same session on its own), drops
    /// packets, and now also ends an existing direct link with a newly blocked peer.
    func setBlocked(_ names: Set<String>) {
        lock.lock()
        let newlyUnblocked = blocked.subtracting(names)
        let newlyBlocked = names.subtracting(blocked)
        blocked = names
        let toInvite = newlyUnblocked.compactMap { discovered[$0] }
        lock.unlock()
        // Reconnect to peers that were just unblocked.
        for peer in toInvite where shouldInvite(peer) {
            invite(peer)
        }
        if !newlyBlocked.isEmpty { dropDirectLinks(to: newlyBlocked) }
    }

    /// Ends direct links with blocked peers. MultipeerConnectivity has no per-peer disconnect, so
    /// first ask it to cancel that peer; if the link is still up a moment later, restart the
    /// whole session once (other peers re-link within seconds, blocked peers are refused).
    private func dropDirectLinks(to names: Set<String>) {
        let linked = session.connectedPeers.filter { names.contains($0.displayName) }
        guard !linked.isEmpty else { return }
        for peer in linked { session.cancelConnectPeer(peer) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let blockedNow = self.currentBlocked()
            let stillLinked = self.session.connectedPeers.contains { blockedNow.contains($0.displayName) }
            guard stillLinked else { return }
            self.lock.lock()
            let running = self.running
            let now = Date()
            let allowed = now.timeIntervalSince(self.lastSessionReset) >= MeshTransport.minSessionResetGap
            if allowed { self.lastSessionReset = now }
            self.lock.unlock()
            guard running, allowed else { return }
            self.session.disconnect()
            self.onEvent(.problem("Forced relay: restarted links so the blocked device is no longer linked directly."))
            self.restartDiscovery(.forcedRelay)
        }
    }

    var connectedPeerNames: [String] {
        let blockedNow = currentBlocked()
        return session.connectedPeers.map { $0.displayName }.filter { !blockedNow.contains($0) }
    }

    /// Sends to every connected, unblocked peer that is not in `excluding`.
    /// Returns the names it was handed to (empty means nothing was sent).
    @discardableResult
    func send(_ data: Data, excluding: Set<String>) -> [String] {
        let blockedNow = currentBlocked()
        let targets = session.connectedPeers.filter {
            !blockedNow.contains($0.displayName) && !excluding.contains($0.displayName)
        }
        guard !targets.isEmpty else { return [] }
        do {
            try session.send(data, toPeers: targets, with: .reliable)
            return targets.map { $0.displayName }
        } catch {
            onEvent(.problem("Send failed: \(error.localizedDescription)"))
            return []
        }
    }

    // MARK: Helpers

    private func currentBlocked() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    private func isBlocked(_ name: String) -> Bool {
        currentBlocked().contains(name)
    }

    /// Normally only one side invites, so two devices do not race to open two links: the device
    /// whose name sorts first invites. If that keeps failing, either side may invite.
    private func shouldInvite(_ peer: MCPeerID) -> Bool {
        if isBlocked(peer.displayName) { return false }
        if session.connectedPeers.contains(where: { $0.displayName == peer.displayName }) { return false }
        lock.lock()
        let failed = failures[peer.displayName] ?? 0
        let waiting = unlinkedSince[peer.displayName].map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()
        return myPeerID.displayName <= peer.displayName
            || failed >= MeshTransport.bothSidesInviteAfter
            || waiting >= MeshTransport.passiveSideWaits
    }

    private func invite(_ peer: MCPeerID) {
        lock.lock()
        inviteSentAt[peer.displayName] = Date()
        lock.unlock()
        browser.invitePeer(peer, to: session, withContext: nil, timeout: MeshTransport.inviteTimeout)
    }

    /// Counts a failed attempt and pushes the next invite out: 2, 4, 8, 16, then 30 s.
    /// Caller must hold `lock`.
    private func noteFailureLocked(_ name: String, now: Date) {
        let count = (failures[name] ?? 0) + 1
        failures[name] = count
        let delay = min(MeshTransport.maxBackoff, pow(2, Double(min(count, 5))))
        nextInviteAt[name] = now.addingTimeInterval(delay)
        inviteSentAt.removeValue(forKey: name)
        connectingSince.removeValue(forKey: name)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + MeshTransport.watchdogInterval, repeating: MeshTransport.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.lock()
        watchdog?.cancel()
        watchdog = timer
        lock.unlock()
        timer.resume()
    }

    /// Watchdog: re-invite unlinked peers whose backoff expired, cancel stuck "connecting" links,
    /// expire invites that never answered. Runs on the main queue. Restarts discovery only when
    /// the mesh is stale (no links, nothing found for 2 minutes), through the restart policy.
    private func tick() {
        let now = self.now()
        let linked = Set(session.connectedPeers.map { $0.displayName })

        lock.lock()
        guard running else { lock.unlock(); return }
        var toCancel: [MCPeerID] = []
        var candidates: [MCPeerID] = []
        for (name, peer) in discovered where !linked.contains(name) && !blocked.contains(name) {
            if let since = connectingSince[name] {
                if now.timeIntervalSince(since) > MeshTransport.connectingLimit {
                    toCancel.append(peer)
                    noteFailureLocked(name, now: now)
                }
                continue
            }
            if let sent = inviteSentAt[name] {
                if now.timeIntervalSince(sent) < MeshTransport.inviteTimeout + 3 { continue }
                noteFailureLocked(name, now: now)   // invite never answered
                continue
            }
            if now >= (nextInviteAt[name] ?? .distantPast) {
                candidates.append(peer)
            }
        }
        for name in linked {
            connectingSince.removeValue(forKey: name)
            unlinkedSince.removeValue(forKey: name)
        }
        let discoveredCount = discovered.count
        let found = lastFound
        lock.unlock()
        let restartDue = policy.isStale(linked: linked.count, discovered: discoveredCount, lastFound: found, now: now)

        for peer in toCancel {
            session.cancelConnectPeer(peer)
        }
        for peer in candidates where shouldInvite(peer) {
            invite(peer)
        }
        if restartDue {
            restartDiscovery(.stale)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let name = peerID.displayName
        guard name != myPeerID.displayName else { return }
        lock.lock()
        discovered[name] = peerID
        lastFound = Date()
        if unlinkedSince[name] == nil { unlinkedSince[name] = Date() }
        // A fresh sighting is a new chance: invite now unless an invite is already in flight
        // or the peer is mid-connect. Backoff still applies to repeated failures.
        let busy = inviteSentAt[name] != nil || connectingSince[name] != nil
        let waitUntil = nextInviteAt[name] ?? .distantPast
        lock.unlock()
        onEvent(.found(name))
        guard !busy, Date() >= waitUntil else { return }
        // Invite from the main thread (never from MultipeerConnectivity's queues).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shouldInvite(peerID) else { return }
            self.invite(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let name = peerID.displayName
        lock.lock()
        if discovered[name] == peerID {
            discovered.removeValue(forKey: name)
            unlinkedSince.removeValue(forKey: name)
        }
        lock.unlock()
        onEvent(.lost(name))
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        onEvent(.problem("Browsing failed: \(error.localizedDescription). Check Local Network permission."))
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Forced-relay demo: refuse direct links to blocked peers.
        let accept = !isBlocked(peerID.displayName)
        invitationHandler(accept, accept ? session : nil)
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        onEvent(.problem("Advertising failed: \(error.localizedDescription). Check Local Network permission."))
    }
}

// MARK: - MCSessionDelegate

extension MeshTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        let linkState: PeerLinkState
        switch state {
        case .connected: linkState = .connected
        case .connecting: linkState = .connecting
        case .notConnected: linkState = .disconnected
        @unknown default: linkState = .disconnected
        }
        let now = Date()
        lock.lock()
        switch linkState {
        case .connected:
            unlinkedSince.removeValue(forKey: name)
            failures.removeValue(forKey: name)
            nextInviteAt.removeValue(forKey: name)
            inviteSentAt.removeValue(forKey: name)
            connectingSince.removeValue(forKey: name)
        case .connecting:
            if connectingSince[name] == nil { connectingSince[name] = now }
        case .disconnected, .discovered:
            noteFailureLocked(name, now: now)
            if unlinkedSince[name] == nil { unlinkedSince[name] = now }
        }
        lock.unlock()
        onEvent(.state(name, linkState))
        // A dropped link does not restart discovery: the browser is still running, and the
        // watchdog re-invites the peer once its backoff expires.
        if linkState == .connected && isBlocked(name) {
            // A blocked peer got linked anyway (for example joined through another member of the session).
            DispatchQueue.main.async { [weak self] in self?.dropDirectLinks(to: [name]) }
        }
    }

    /// Called for every incoming connection, including ones MultipeerConnectivity sets up between
    /// members of the same session without an invite. Refusing here keeps forced relay airtight.
    /// (No certificates are used: links are encrypted but devices are not authenticated.)
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(!isBlocked(peerID.displayName))
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        // Forced-relay demo: ignore anything that arrives directly from a blocked peer.
        guard !isBlocked(name) else { return }
        onEvent(.received(data, from: name))
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
