// BLETransport.swift
// Libre: Bluetooth Low Energy link (Oct 11, 2026). Works with Wi-Fi switched off.
//
// MultipeerConnectivity (MeshTransport) needs the Wi-Fi radio. This transport links devices
// over CoreBluetooth instead. Every device does both jobs:
// - Peripheral: advertises the Libre service with one characteristic (write without response +
//   notify). Scanners write frames to it; it notifies frames back.
// - Central: scans for the Libre service, connects, subscribes, and writes.
// Two devices that both scan open two links to each other; after the hello the device whose
// name sorts last drops the link it opened (LinkRouter.dropOwnCentralLink), so one stays.
//
// Bytes are the same encoded, room-sealed MeshMessage packets that MeshTransport moves. They
// are cut into frames that fit the link's largest single write (BLEChunker, Core) and put back
// together on the other side (BLEReassembler). Flow control: a central writes only while
// canSendWriteWithoutResponse is true and resumes in peripheralIsReady(toSendWriteWithoutResponse:);
// a peripheral notifies until updateValue returns false and resumes in
// peripheralManagerIsReady(toUpdateSubscribers:).
//
// Peers are named by a hello frame carrying the same display name MultipeerConnectivity uses,
// so RelayEngine, peer states and hop paths treat a peer the same on either link.
// After the hello each side sends one 4 KB probe and times the reply (speed shown in logs and
// the Connection sheet). Threading: all CoreBluetooth work runs on one serial queue; the small
// snapshot that send() reads from the main thread sits behind a lock.

import Foundation
@preconcurrency import CoreBluetooth
import os

final class BLETransport: NSObject, @unchecked Sendable {
    static let serviceUUID = CBUUID(string: "BAA354FA-5C3F-4FD8-A2FB-A2F30E6C73F2")
    static let characteristicUUID = CBUUID(string: "05F51AD3-42F8-4ABD-A52C-BD6C6537FAF7")
    static let probeBytes = 4096
    /// Frames waiting per link before new packets are refused (about 1 MB at MTU 182).
    static let maxQueuedFrames = 6000

    private static let log = Logger(subsystem: "com.kmaquindang.libre", category: "ble")

    enum Role: String { case central, peripheral }

    final class Link {
        let id: String
        let role: Role
        var peripheral: CBPeripheral?
        var central: CBCentral?
        var remote: CBCharacteristic?
        var name: String?
        var mtu: Int = BLEFrame.minimumMTU
        var ready = false
        var queue: [Data] = []
        var nextID = UInt32.random(in: 0...UInt32.max)
        var probeSentAt: Date?
        var openedAt = Date()
        init(id: String, role: Role) { self.id = id; self.role = role }
    }

    let displayName: String
    private let onEvent: @Sendable (TransportEvent) -> Void
    private let queue = DispatchQueue(label: "com.kmaquindang.libre.ble")
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var links: [String: Link] = [:]   // "c-" + peripheral id or "p-" + central id
    private var pending: [UUID: CBPeripheral] = [:]   // connecting as central
    private var dropped: [UUID: String] = [:]          // central links dropped by the tie-break
    private var reassembler = BLEReassembler()
    private var rescanTimer: DispatchSourceTimer?
    private var running = false
    private var startedAt = Date()

    // Read from the main thread (send, connectedPeerNames, stats).
    private let lock = NSLock()
    private var namedLinks: [String: [String]] = [:]
    private var blocked: Set<String>
    private var probes: [String: BLEProbeResult] = [:]
    private var radioState = "starting"
    private(set) var framesSent = 0
    private(set) var bytesSent = 0

    init(displayName: String, blocked: Set<String>, onEvent: @escaping @Sendable (TransportEvent) -> Void) {
        self.displayName = MeshTransport.sanitize(displayName)
        self.blocked = blocked
        self.onEvent = onEvent
        super.init()
    }

    // MARK: Control

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startedAt = Date()
            // ShowPowerAlert off: Libre explains Bluetooth itself, no system alert loop.
            centralManager = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 20, repeating: 20)
            timer.setEventHandler { [weak self] in self?.rescan() }
            timer.resume()
            rescanTimer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            rescanTimer?.cancel()
            rescanTimer = nil
            centralManager?.stopScan()
            for link in links.values { if let p = link.peripheral { centralManager?.cancelPeripheralConnection(p) } }
            for p in pending.values { centralManager?.cancelPeripheralConnection(p) }
            peripheralManager?.stopAdvertising()
            peripheralManager?.removeAllServices()
            let names = Set(links.values.compactMap { $0.name })
            links.removeAll()
            pending.removeAll()
            dropped.removeAll()
            serviceAdded = false
            centralManager = nil
            peripheralManager = nil
            lock.lock(); namedLinks.removeAll(); lock.unlock()
            for n in names { onEvent(.state(n, .disconnected)) }
        }
    }

    /// Foreground or forced reset: scan again so peers that moved are found quickly.
    func rescan() {
        queue.async { [self] in
            guard running, let c = centralManager, c.state == .poweredOn else { return }
            c.stopScan()
            c.scanForPeripherals(withServices: [BLETransport.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func setBlocked(_ names: Set<String>) {
        lock.lock(); blocked = names; lock.unlock()
    }

    // MARK: Read from main

    var connectedPeerNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return namedLinks.filter { !$0.value.isEmpty && !blocked.contains($0.key) }.map { $0.key }.sorted()
    }

    var probeResults: [String: BLEProbeResult] {
        lock.lock(); defer { lock.unlock() }
        return probes
    }

    /// "on", "off", "unauthorized", "unsupported", "starting".
    var state: String {
        lock.lock(); defer { lock.unlock() }
        return radioState
    }

    var stats: (frames: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (framesSent, bytesSent)
    }

    /// Sends `data` to each named peer that has a ready Bluetooth link. Returns who it was
    /// handed to. Frames are queued and paced by CoreBluetooth flow control.
    @discardableResult
    func send(_ data: Data, to names: [String]) -> [String] {
        guard data.count <= BLEChunker.maxMessageBytes else { return [] }
        lock.lock()
        let targets = names.filter { !(namedLinks[$0] ?? []).isEmpty && !blocked.contains($0) }
        let picks = targets.compactMap { namedLinks[$0]?.first }
        lock.unlock()
        guard !picks.isEmpty else { return [] }
        queue.async { [self] in
            for id in picks {
                guard let link = links[id], link.ready else { continue }
                enqueue(data, type: .data, on: link)
            }
        }
        return targets
    }

    // MARK: Frames

    private func enqueue(_ data: Data, type: BLEFrameType, on link: Link) {
        let id = link.nextID
        link.nextID &+= 1
        guard let frames = BLEChunker.frames(data, type: type, messageID: id, mtu: link.mtu) else { return }
        guard link.queue.count + frames.count <= BLETransport.maxQueuedFrames else {
            onEvent(.problem("Bluetooth link to \(link.name ?? "a device") is busy; a packet waits for Wi-Fi or the outbox."))
            return
        }
        link.queue.append(contentsOf: frames)
        pump(link)
    }

    private func pump(_ link: Link) {
        var sent = 0, bytes = 0
        switch link.role {
        case .central:
            guard let p = link.peripheral, let ch = link.remote else { return }
            while !link.queue.isEmpty && p.canSendWriteWithoutResponse {
                let f = link.queue.removeFirst()
                p.writeValue(f, for: ch, type: .withoutResponse)
                sent += 1; bytes += f.count
            }
        case .peripheral:
            guard let pm = peripheralManager, let ch = characteristic, let c = link.central else { return }
            while let f = link.queue.first {
                guard pm.updateValue(f, for: ch, onSubscribedCentrals: [c]) else { break }
                link.queue.removeFirst()
                sent += 1; bytes += f.count
            }
        }
        if sent > 0 {
            lock.lock(); framesSent += sent; bytesSent += bytes; lock.unlock()
        }
    }

    private func linkReady(_ link: Link) {
        guard !link.ready else { return }
        link.ready = true
        note("BLE link open role=\(link.role.rawValue) mtu=\(link.mtu)")
        enqueue(Data(displayName.utf8), type: .hello, on: link)
    }

    private func received(_ raw: Data, on link: Link) {
        guard let done = reassembler.add(raw, link: link.id) else { return }
        switch done.type {
        case .hello:
            guard let name = String(data: done.data, encoding: .utf8), !name.isEmpty, name != displayName else { return }
            named(link, name)
        case .data:
            guard let name = link.name else { return }
            lock.lock(); let isBlocked = blocked.contains(name); lock.unlock()
            if isBlocked { return }
            onEvent(.received(done.data, from: name, link: .bluetooth))
        case .probe:
            enqueue(Data("ok".utf8), type: .probeReply, on: link)
        case .probeReply:
            guard let at = link.probeSentAt, let name = link.name else { return }
            link.probeSentAt = nil
            let result = BLEProbeResult(bytes: BLETransport.probeBytes, mtu: link.mtu, roundTripMs: Int(Date().timeIntervalSince(at) * 1000))
            lock.lock(); probes[name] = result; lock.unlock()
            note("BLE probe \(name) role=\(link.role.rawValue) mtu=\(link.mtu) bytes=\(result.bytes) rtt_ms=\(result.roundTripMs) Bps=\(Int(result.bytesPerSecond))")
        }
    }

    private func named(_ link: Link, _ name: String) {
        guard link.name == nil else { return }
        link.name = name
        let secs = String(format: "%.1f", Date().timeIntervalSince(link.openedAt))
        note("BLE hello from \(name) role=\(link.role.rawValue) mtu=\(link.mtu) after_s=\(secs)")
        // One link per pair: the device whose name sorts last drops the link it opened.
        let central = link.role == .central ? link : links.values.first { $0.role == .central && $0.name == name }
        let alsoPeripheral = links.values.contains { $0.role == .peripheral && $0.name == name }
        if let central, central.role == .central,
           LinkRouter.dropOwnCentralLink(myName: displayName, peerName: name, alsoLinkedAsPeripheral: alsoPeripheral),
           let p = central.peripheral {
            dropped[p.identifier] = name
            links.removeValue(forKey: central.id)
            reassembler.reset(link: central.id)
            lock.lock(); namedLinks[name]?.removeAll { $0 == central.id }; lock.unlock()
            centralManager?.cancelPeripheralConnection(p)
            note("BLE kept one link to \(name)")
            if central === link { return }
        }
        lock.lock()
        let wasLinked = !(namedLinks[name] ?? []).isEmpty
        namedLinks[name, default: []].append(link.id)
        // A central link writes without waiting on the peer's notify queue: list it first.
        if link.role == .central, let ids = namedLinks[name] { namedLinks[name] = [link.id] + ids.filter { $0 != link.id } }
        lock.unlock()
        if !wasLinked {
            onEvent(.found(name))
            onEvent(.state(name, .connected))
        }
        link.probeSentAt = Date()
        enqueue(Data(count: BLETransport.probeBytes), type: .probe, on: link)
    }

    private func closed(_ id: String) {
        guard let link = links.removeValue(forKey: id) else { return }
        reassembler.reset(link: id)
        guard let name = link.name else { return }
        lock.lock()
        namedLinks[name]?.removeAll { $0 == id }
        let still = !(namedLinks[name] ?? []).isEmpty
        if !still { namedLinks.removeValue(forKey: name) }
        lock.unlock()
        note("BLE link closed \(name) role=\(link.role.rawValue)")
        // The peer's link to us died: reconnect the one we dropped in the tie-break.
        if link.role == .peripheral, let (pid, _) = dropped.first(where: { $0.value == name }) {
            dropped.removeValue(forKey: pid)
            if let p = centralManager?.retrievePeripherals(withIdentifiers: [pid]).first { connect(p) }
        }
        if !still { onEvent(.state(name, .disconnected)) }
    }

    /// Log line to os_log (category "ble") and to Application Support/Libre/ble-log.txt, so link
    /// timings can be read back from a phone. Only device names and numbers, never message text.
    private func note(_ line: String) {
        BLETransport.log.notice("\(line, privacy: .public)")
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = base.appendingPathComponent("Libre", isDirectory: true).appendingPathComponent("ble-log.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            if size > 64 * 1024, let old = try? Data(contentsOf: url) {
                try? (old.suffix(32 * 1024) + data).write(to: url)
            } else {
                h.write(data)
            }
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func ck(_ p: CBPeripheral) -> String { "c-" + p.identifier.uuidString }
    private func pk(_ c: CBCentral) -> String { "p-" + c.identifier.uuidString }

    private func connect(_ p: CBPeripheral) {
        guard let c = centralManager, pending[p.identifier] == nil, links[ck(p)] == nil else { return }
        pending[p.identifier] = p
        c.connect(p, options: nil)
    }

    private func setRadio(_ s: String) {
        lock.lock(); let changed = radioState != s; radioState = s; lock.unlock()
        guard changed else { return }
        note("BLE radio \(s)")
        if s == "unauthorized" { onEvent(.problem("Bluetooth permission is off for Libre. Turn it on in Settings so Libre works without Wi-Fi.")) }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        default: return "starting"
        }
    }
}

// MARK: Central (scan, connect, write)

extension BLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        setRadio(BLETransport.describe(central.state))
        guard central.state == .poweredOn else {
            for id in Array(links.keys) where links[id]?.role == .central { closed(id) }
            pending.removeAll()
            return
        }
        central.scanForPeripherals(withServices: [BLETransport.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard dropped[peripheral.identifier] == nil else { return }
        if pending[peripheral.identifier] == nil && links[ck(peripheral)] == nil {
            note("BLE found a Libre device rssi=\(RSSI) after_start_s=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))")
        }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pending.removeValue(forKey: peripheral.identifier)
        let link = Link(id: ck(peripheral), role: .central)
        link.peripheral = peripheral
        links[ck(peripheral)] = link
        peripheral.delegate = self
        peripheral.discoverServices([BLETransport.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pending.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        pending.removeValue(forKey: peripheral.identifier)
        let wasLinked = links[ck(peripheral)] != nil
        closed(ck(peripheral))
        // Out of range or the app went away: ask again; iOS completes it when the peer is back.
        if wasLinked, running, dropped[peripheral.identifier] == nil { connect(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == BLETransport.serviceUUID }) else {
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([BLETransport.characteristicUUID], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == BLETransport.characteristicUUID }),
              let link = links[ck(peripheral)] else {
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        link.remote = ch
        link.mtu = min(512, peripheral.maximumWriteValueLength(for: .withoutResponse))
        peripheral.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = links[ck(peripheral)] else { return }
        if error != nil || !characteristic.isNotifying {
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        linkReady(link)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = links[ck(peripheral)], let value = characteristic.value else { return }
        received(value, on: link)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let link = links[ck(peripheral)] { pump(link) }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == BLETransport.serviceUUID }) {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
}

// MARK: Peripheral (advertise, receive writes, notify)

extension BLETransport: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            for id in Array(links.keys) where links[id]?.role == .peripheral { closed(id) }
            serviceAdded = false
            return
        }
        guard !serviceAdded else { return }
        let ch = CBMutableCharacteristic(type: BLETransport.characteristicUUID,
                                         properties: [.writeWithoutResponse, .notify],
                                         value: nil, permissions: [.writeable])
        let service = CBMutableService(type: BLETransport.serviceUUID, primary: true)
        service.characteristics = [ch]
        characteristic = ch
        serviceAdded = true
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            serviceAdded = false
            onEvent(.problem("Bluetooth service failed: \(error.localizedDescription)"))
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BLETransport.serviceUUID],
                                     CBAdvertisementDataLocalNameKey: "Libre"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { onEvent(.problem("Bluetooth advertising failed: \(error.localizedDescription)")) }
        else { note("BLE advertising as \(displayName)") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let link = links[pk(central)] ?? Link(id: pk(central), role: .peripheral)
        link.central = central
        link.mtu = min(512, central.maximumUpdateValueLength)
        links[pk(central)] = link
        linkReady(link)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        closed(pk(central))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            guard r.characteristic.uuid == BLETransport.characteristicUUID, let value = r.value else { continue }
            // Writes can arrive just before the subscribe; keep them on a link for that central.
            let link = links[pk(r.central)] ?? {
                let l = Link(id: pk(r.central), role: .peripheral)
                l.central = r.central
                links[pk(r.central)] = l
                return l
            }()
            received(value, on: link)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for link in links.values where link.role == .peripheral { pump(link) }
    }
}
