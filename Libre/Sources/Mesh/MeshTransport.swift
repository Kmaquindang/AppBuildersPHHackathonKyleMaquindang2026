// MeshTransport.swift
// Libre: link layer. Apple MultipeerConnectivity finds nearby devices and opens encrypted
// links over peer-to-peer Wi-Fi (Bluetooth is only used by the OS for discovery, if at all).
// This file only moves bytes between directly connected devices. Multi-hop routing lives in
// RelayEngine, which is our own code.
//
// Threading: MultipeerConnectivity calls delegates on its own private queues. This class keeps
// its small mutable state behind a lock and reports everything through a @Sendable callback.
// MeshService hops those events to the main actor.

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
        if name.isEmpty { name = "Libre device" }
        while name.utf8.count > maxNameBytes { name.removeLast() }
        return name
    }

    // MARK: Control

    func start() {
        lock.lock()
        let wasRunning = running
        running = true
        lock.unlock()
        guard !wasRunning else { return }
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        lock.lock()
        running = false
        discovered.removeAll()
        lock.unlock()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func setBlocked(_ names: Set<String>) {
        lock.lock()
        let newlyUnblocked = blocked.subtracting(names)
        blocked = names
        let toInvite = newlyUnblocked.compactMap { discovered[$0] }
        lock.unlock()
        // Reconnect to peers that were just unblocked.
        for peer in toInvite where shouldInvite(peer) {
            invite(peer)
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

    /// Only one side invites, so two devices do not race to open two links.
    /// The device whose name sorts first invites. Equal names (avoid them) both invite.
    private func shouldInvite(_ peer: MCPeerID) -> Bool {
        if isBlocked(peer.displayName) { return false }
        if session.connectedPeers.contains(peer) { return false }
        return myPeerID.displayName <= peer.displayName
    }

    private func invite(_ peer: MCPeerID) {
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    /// After a link drops or an invite fails, try again while the peer is still nearby.
    private func scheduleRetry(for name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let peer = self.discovered[name]
            let running = self.running
            self.lock.unlock()
            guard running, let peer, self.shouldInvite(peer) else { return }
            self.invite(peer)
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
        lock.unlock()
        onEvent(.found(name))
        if shouldInvite(peerID) {
            invite(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let name = peerID.displayName
        lock.lock()
        if discovered[name] == peerID { discovered.removeValue(forKey: name) }
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
        onEvent(.state(name, linkState))
        if linkState == .disconnected {
            scheduleRetry(for: name)
        }
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
