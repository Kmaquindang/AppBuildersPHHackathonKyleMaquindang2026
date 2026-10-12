// LinkHub.swift
// Libre: runs both links side by side (Oct 11, 2026).
// - Wi-Fi: MeshTransport (MultipeerConnectivity, peer-to-peer Wi-Fi). Fast; needs the Wi-Fi radio.
// - Bluetooth: BLETransport (CoreBluetooth). Slow; works with Wi-Fi switched off.
// Both always run. A peer reachable on both gets each packet once, over Wi-Fi (LinkRouter).
// Peer states are merged (connected on either link means connected), so MeshService sees one
// peer, not two. Relay, dedupe (RelayEngine) and room encryption are unchanged: the hub only
// decides which radio carries the already sealed bytes.

import Foundation

final class LinkHub: @unchecked Sendable {
    private var wifi: MeshTransport!
    private var bluetooth: BLETransport!
    private let onEvent: @Sendable (TransportEvent) -> Void

    private let lock = NSLock()
    private var wifiStates: [String: PeerLinkState] = [:]
    private var bleStates: [String: PeerLinkState] = [:]
    private var reported: [String: PeerLinkState] = [:]
    private var skippedTooBig = 0
    private var lastSlowWarning = Date.distantPast
    /// Packets bigger than this over Bluetooth are media chunks (photos, voice): warn they are slow.
    static let slowPacketBytes = 8 * 1024

    init(displayName: String, identity: DeviceIdentity, isHub: Bool = false, blocked: Set<String>, onEvent: @escaping @Sendable (TransportEvent) -> Void) {
        self.onEvent = onEvent
        wifi = MeshTransport(displayName: displayName, blocked: blocked) { [weak self] e in self?.handle(e, link: .wifi) }
        bluetooth = BLETransport(displayName: displayName, identity: identity, isHub: isHub, blocked: blocked) { [weak self] e in self?.handle(e, link: .bluetooth) }
    }

    // MARK: Control (main thread, like MeshTransport)

    func start() {
        wifi.start()
        bluetooth.start()
    }

    func stop() {
        wifi.stop()
        bluetooth.stop()
        lock.lock(); wifiStates.removeAll(); bleStates.removeAll(); reported.removeAll(); lock.unlock()
    }

    func restartDiscovery(_ reason: DiscoveryRestartPolicy.Reason) {
        wifi.restartDiscovery(reason)
        bluetooth.rescan()
    }

    func setBlocked(_ names: Set<String>) {
        wifi.setBlocked(names)
        bluetooth.setBlocked(names)
    }

    var restartCount: Int { wifi.restartCount }
    var coalescedRestarts: Int { wifi.coalescedRestarts }

    // MARK: Links

    var connectedPeerNames: [String] { Array(Set(wifi.connectedPeerNames).union(bluetooth.connectedPeerNames)).sorted() }

    /// Peers this device reaches over Bluetooth only (no Wi-Fi link to them).
    var bluetoothOnlyPeers: Set<String> { Set(bluetooth.connectedPeerNames).subtracting(wifi.connectedPeerNames) }

    func link(for name: String) -> LinkKind? {
        if wifi.connectedPeerNames.contains(name) { return .wifi }
        if bluetooth.connectedPeerNames.contains(name) { return .bluetooth }
        return nil
    }

    /// "Bluetooth", "Wi-Fi", "Wi-Fi and Bluetooth" for the names a packet was handed to.
    func linkLabel(for names: [String]) -> String? {
        let kinds = Set(names.compactMap { link(for: $0) })
        if kinds == [.bluetooth] { return "Bluetooth" }
        if kinds == [.wifi] { return "Wi-Fi" }
        return kinds.isEmpty ? nil : "Wi-Fi and Bluetooth"
    }

    var bluetoothState: String { bluetooth.state }
    var bluetoothProbes: [String: BLEProbeResult] { bluetooth.probeResults }
    var bluetoothStats: (frames: Int, bytes: Int) { bluetooth.stats }
    var packetsTooBigForBluetooth: Int { lock.lock(); defer { lock.unlock() }; return skippedTooBig }

    /// Each reachable, unblocked peer not in `excluding` gets one copy: over Wi-Fi when it has a
    /// Wi-Fi link, else over Bluetooth. Returns who it was handed to.
    @discardableResult
    func send(_ data: Data, excluding: Set<String>) -> [String] {
        let plan = LinkRouter.plan(wifi: Set(wifi.connectedPeerNames), bluetooth: Set(bluetooth.connectedPeerNames),
                                   blocked: [], excluding: excluding, bytes: data.count)
        if !plan.tooBigForBluetooth.isEmpty { lock.lock(); skippedTooBig += 1; lock.unlock() }
        var sent: [String] = []
        if !plan.wifi.isEmpty {
            let viaWifi = wifi.send(data, excluding: excluding)
            sent += viaWifi
            // Wi-Fi send failed: fall back to Bluetooth for peers that have it.
            if viaWifi.isEmpty {
                let fallback = plan.wifi.filter { bluetooth.connectedPeerNames.contains($0) }
                if !fallback.isEmpty { sent += bluetooth.send(data, to: fallback) }
            }
        }
        if !plan.bluetooth.isEmpty {
            sent += bluetooth.send(data, to: plan.bluetooth)
            if data.count > LinkHub.slowPacketBytes { warnSlow() }
        }
        return Array(Set(sent)).sorted()
    }

    private func warnSlow() {
        lock.lock()
        let due = Date().timeIntervalSince(lastSlowWarning) > 60
        if due { lastSlowWarning = Date() }
        lock.unlock()
        if due { onEvent(.problem("Bluetooth only (no Wi-Fi link): photos and voice notes are slow, often a minute or more. Text is fine.")) }
    }

    // MARK: Events

    private func handle(_ event: TransportEvent, link: LinkKind) {
        switch event {
        case .state(let name, let state):
            lock.lock()
            if link == .wifi { wifiStates[name] = state } else { bleStates[name] = state }
            let merged = LinkRouter.merged(wifiStates[name]?.rawValue, bleStates[name]?.rawValue).flatMap(PeerLinkState.init(rawValue:)) ?? state
            let changed = reported[name] != merged
            reported[name] = merged
            lock.unlock()
            if changed { onEvent(.state(name, merged)) }
        case .lost(let name):
            lock.lock()
            let other = link == .wifi ? bleStates[name] : wifiStates[name]
            lock.unlock()
            if other != .connected { onEvent(.lost(name)) }
        case .received(let data, let from, _):
            onEvent(.received(data, from: from, link: link))
        case .problem(let text):
            onEvent(.problem(text))
        case .found:
            onEvent(event)
        }
    }
}
