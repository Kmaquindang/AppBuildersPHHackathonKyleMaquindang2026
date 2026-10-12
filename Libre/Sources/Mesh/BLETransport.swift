// BLETransport.swift
// Libre: Bluetooth Low Energy link (Oct 11, 2026). Works with Wi-Fi switched off.
//
// MultipeerConnectivity (MeshTransport) needs the Wi-Fi radio. This transport links devices
// over CoreBluetooth instead. Every device does both jobs:
// - Peripheral: advertises the Libre service with one characteristic (write without response +
//   notify). Scanners write frames to it; it notifies frames back.
// - Central: scans for the Libre service, connects, subscribes, and writes.
// Two devices that both scan open two links to each other; once both are verified the device
// whose key sorts last drops the link it opened (BLEPeerBook), so one stays.
//
// Bytes are the same encoded, room-sealed MeshMessage packets that MeshTransport moves. They
// are cut into frames that fit the link's largest single write (BLEChunker, Core) and put back
// together on the other side (BLEReassembler). Flow control: a central writes only while
// canSendWriteWithoutResponse is true and resumes in peripheralIsReady(toSendWriteWithoutResponse:);
// a peripheral notifies until updateValue returns false and resumes in
// peripheralManagerIsReady(toUpdateSubscribers:).
//
// Peers prove who they are with a signed hello plus a proof over a fresh challenge
// (BLEHandshake.swift). Links are keyed by the peer's device key; the mesh name from the signed
// hello is what RelayEngine, peer states and hop paths see, the same as on Wi-Fi. Data frames
// from a link that is not verified yet are dropped.
// iOS (issue #5): the bluetooth-central and bluetooth-peripheral background modes keep links up
// while Libre is in the background, and restore identifiers let iOS relaunch Libre for a
// Bluetooth event after it ended the app. willRestoreState only remembers what iOS hands back;
// the plan (BLERestore) runs once the radio reports powered on.
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
    #if os(iOS)
    static let centralRestoreID = "app.libre.ble.central"
    static let peripheralRestoreID = "app.libre.ble.peripheral"
    #endif

    private static let log = Logger(subsystem: "com.kmaquindang.libre", category: "ble")

    enum Role: String { case central, peripheral }

    final class Link {
        let id: String
        let role: Role
        var peripheral: CBPeripheral?
        var central: CBCentral?
        var remote: CBCharacteristic?
        var name: String?   // set once the link is verified
        var mtu: Int = BLEFrame.minimumMTU
        var ready = false
        var queue = BLESendQueue()   // lanes: control, urgent, bulk, media (BLEPriority)
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
    /// Retries the service add and advertising if they fail or stop (AdvertiseWatch).
    private var advertiseWatch = AdvertiseWatch()
    private var links: [String: Link] = [:]   // "c-" + peripheral id or "p-" + central id
    private var pending: [UUID: CBPeripheral] = [:]   // connecting as central
    private var heard: [UUID: CBPeripheral] = [:]     // scanned, waiting for a connect slot
    private var policy: BLEConnectPolicy
    private var tickTimer: DispatchSourceTimer?
    private var dropped: [UUID: String] = [:]          // central links dropped by the tie-break (peripheral id -> peer key id)
    private var book: BLEPeerBook
    private let isHub: Bool
    private var reassembler = BLEReassembler()
    private var rescanTimer: DispatchSourceTimer?
    private var running = false
    private var startedAt = Date()
    #if os(iOS)
    /// Handed back by iOS after a background relaunch; used once the radio is on.
    private var restoredPeripherals: [CBPeripheral] = []
    private var restoredSubscribers: [CBCentral] = []
    #endif

    // Read from the main thread (send, connectedPeerNames, stats).
    private let lock = NSLock()
    private var namedLinks: [String: [String]] = [:]
    private var blocked: Set<String>
    private var probes: [String: BLEProbeResult] = [:]
    private var radioState = "starting"
    private(set) var framesSent = 0
    private(set) var bytesSent = 0

    init(displayName: String, identity: DeviceIdentity, isHub: Bool = false, blocked: Set<String>, onEvent: @escaping @Sendable (TransportEvent) -> Void) {
        self.displayName = MeshTransport.sanitize(displayName)
        self.blocked = blocked
        self.onEvent = onEvent
        self.isHub = isHub
        var b = BLEPeerBook(identity: identity)
        _ = b.setBlocked(blocked)
        self.book = b
        self.policy = BLEConnectPolicy(config: isHub ? .hub : .phone)
        self.advertiseWatch = AdvertiseWatch(isHub: isHub)
        super.init()
    }

    // MARK: Control

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startedAt = Date()
            // ShowPowerAlert off: Libre explains Bluetooth itself, no system alert loop.
            var centralOptions: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
            var peripheralOptions: [String: Any] = [CBPeripheralManagerOptionShowPowerAlertKey: false]
            #if os(iOS)
            centralOptions[CBCentralManagerOptionRestoreIdentifierKey] = BLETransport.centralRestoreID
            peripheralOptions[CBPeripheralManagerOptionRestoreIdentifierKey] = BLETransport.peripheralRestoreID
            #endif
            centralManager = CBCentralManager(delegate: self, queue: queue, options: centralOptions)
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue, options: peripheralOptions)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 20, repeating: 20)
            timer.setEventHandler { [weak self] in self?.rescan() }
            timer.resume()
            rescanTimer = timer
            // Connect queue: time out slow connects and start the next ones.
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + 2, repeating: 2)
            tick.setEventHandler { [weak self] in self?.connectTick() }
            tick.resume()
            tickTimer = tick
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            rescanTimer?.cancel()
            rescanTimer = nil
            tickTimer?.cancel()
            tickTimer = nil
            centralManager?.stopScan()
            for link in links.values { if let p = link.peripheral { centralManager?.cancelPeripheralConnection(p) } }
            for p in pending.values { centralManager?.cancelPeripheralConnection(p) }
            peripheralManager?.stopAdvertising()
            peripheralManager?.removeAllServices()
            let names = Set(links.values.compactMap { $0.name })
            links.removeAll()
            pending.removeAll()
            heard.removeAll()
            dropped.removeAll()
            book.reset()
            policy.reset()
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
        queue.async { [self] in
            // Blocking follows the device key; an existing link to a blocked device is closed.
            for id in book.setBlocked(names) { drop(id) }
        }
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
    func send(_ data: Data, to names: [String], lane: BLELane = .urgent) -> [String] {
        guard data.count <= BLEChunker.maxMessageBytes else { return [] }
        lock.lock()
        let targets = names.filter { !(namedLinks[$0] ?? []).isEmpty && !blocked.contains($0) }
        let picks = targets.compactMap { namedLinks[$0]?.first }
        lock.unlock()
        guard !picks.isEmpty else { return [] }
        queue.async { [self] in
            for id in picks {
                guard let link = links[id], link.ready else { continue }
                enqueue(data, type: .data, on: link, lane: lane)
            }
        }
        return targets
    }

    // MARK: Frames

    private func enqueue(_ data: Data, type: BLEFrameType, on link: Link, lane: BLELane? = nil) {
        let id = link.nextID
        link.nextID &+= 1
        guard let frames = BLEChunker.frames(data, type: type, messageID: id, mtu: link.mtu) else { return }
        // Hello, proof and probe replies jump the queue; the 4 KB speed probe rides with media.
        let l = lane ?? (type == .probe ? .media : .control)
        guard link.queue.push(frames, lane: l) else {
            onEvent(.problem("Bluetooth link to \(link.name ?? "a device") is busy; a packet waits for Wi-Fi or the outbox."))
            return
        }
        pump(link)
    }

    private func pump(_ link: Link) {
        var sent = 0, bytes = 0
        switch link.role {
        case .central:
            guard let p = link.peripheral, let ch = link.remote else { return }
            while p.canSendWriteWithoutResponse, let f = link.queue.pop() {
                p.writeValue(f, for: ch, type: .withoutResponse)
                sent += 1; bytes += f.count
            }
        case .peripheral:
            guard let pm = peripheralManager, let ch = characteristic, let c = link.central else { return }
            while let f = link.queue.peek() {
                guard pm.updateValue(f, for: ch, onSubscribedCentrals: [c]) else { break }
                link.queue.pop()
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
        let challenge = book.opened(link.id, role: link.role == .central ? .central : .peripheral)
        guard let hello = BLEHello.make(identity: book.identity, name: displayName, nonce: challenge, hub: isHub) else {
            note("BLE hello not made (name too long?)")
            return
        }
        enqueue(hello, type: .hello, on: link)
    }

    /// Closes one link (blocked, refused hello, or tie-break).
    private func drop(_ id: String) {
        guard let link = links[id] else { return }
        if let p = link.peripheral { centralManager?.cancelPeripheralConnection(p) }
        closed(id)
    }

    private func received(_ raw: Data, on link: Link) {
        guard let done = reassembler.add(raw, link: link.id) else { return }
        switch done.type {
        case .hello:
            // A central's first writes can arrive before its subscribe: open the book entry now
            // (linkReady later reuses the same challenge for our hello).
            _ = book.opened(link.id, role: link.role == .central ? .central : .peripheral)
            switch book.received(hello: done.data, on: link.id) {
            case .sendProof(let proof):
                enqueue(proof, type: .proof, on: link)
            case .rejected(let why):
                note("BLE hello refused role=\(link.role.rawValue): \(why)")
                if why != "second hello" { drop(link.id) }
            }
        case .proof:
            switch book.received(proof: done.data, on: link.id) {
            case .verified(let name, let keyID, let newPeer, let dropLink, let replaced):
                if let replaced, links[replaced] != nil {
                    note("BLE \(name) came back on a new link; closing the old one")
                    drop(replaced)
                }
                if let p = link.peripheral { policy.verified(p.identifier.uuidString) }
                verified(link, name: name, keyID: keyID, newPeer: newPeer, dropLink: dropLink)
            case .rejected(let why):
                note("BLE proof refused role=\(link.role.rawValue): \(why)")
                drop(link.id)
            }
        case .data:
            guard let name = link.name, book.isVerified(link.id) else { return }
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

    private func verified(_ link: Link, name: String, keyID: String, newPeer: Bool, dropLink: String?) {
        let secs = String(format: "%.1f", Date().timeIntervalSince(link.openedAt))
        note("BLE verified \(name) key=\(keyID.prefix(8)) role=\(link.role.rawValue) mtu=\(link.mtu) after_s=\(secs)")
        link.name = name
        lock.lock()
        namedLinks[name] = book.linkIDs(forName: name)
        lock.unlock()
        if let dropID = dropLink, let central = links[dropID], let p = central.peripheral {
            // One link per pair: the device whose key sorts last drops the link it opened.
            dropped[p.identifier] = keyID
            policy.exclude(p.identifier.uuidString)
            links.removeValue(forKey: dropID)
            reassembler.reset(link: dropID)
            lock.lock(); namedLinks[name] = book.linkIDs(forName: name); lock.unlock()
            centralManager?.cancelPeripheralConnection(p)
            note("BLE kept one link to \(name)")
            if central === link { return }
        }
        if newPeer {
            onEvent(.found(name))
            onEvent(.state(name, .connected))
        }
        link.probeSentAt = Date()
        enqueue(Data(count: BLETransport.probeBytes), type: .probe, on: link)
    }

    private func closed(_ id: String) {
        guard let link = links.removeValue(forKey: id) else { _ = book.closed(id); return }
        reassembler.reset(link: id)
        let gone = book.closed(id)
        guard let name = link.name, let gone else { return }
        lock.lock()
        let ids = book.linkIDs(forName: name)
        if ids.isEmpty { namedLinks.removeValue(forKey: name) } else { namedLinks[name] = ids }
        lock.unlock()
        let still = gone.stillLinked
        note("BLE link closed \(name) role=\(link.role.rawValue)")
        // The peer's link to us died: reconnect the one we dropped in the tie-break.
        if link.role == .peripheral, let (pid, _) = dropped.first(where: { $0.value == gone.keyID }) {
            dropped.removeValue(forKey: pid)
            policy.include(pid.uuidString)
            if let p = centralManager?.retrievePeripherals(withIdentifiers: [pid]).first {
                heard[pid] = p
                policy.discovered(pid.uuidString, rssi: 127)
                startConnects()
            }
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

    /// Starts the connects the policy allows now (cap, signal floor, strongest first, backoff).
    private func startConnects() {
        guard running, let c = centralManager, c.state == .poweredOn else { return }
        for id in policy.next(linked: links.count) {
            guard let uuid = UUID(uuidString: id), let p = heard[uuid] ?? pending[uuid] else { policy.disconnected(id); continue }
            guard links[ck(p)] == nil else { policy.connected(id); continue }
            pending[uuid] = p
            c.connect(p, options: nil)
        }
    }

    private func connectTick() {
        watchAdvertising()
        for id in policy.timedOut() {
            guard let uuid = UUID(uuidString: id), let p = pending.removeValue(forKey: uuid) else { continue }
            centralManager?.cancelPeripheralConnection(p)
            note("BLE connect timed out; backing off")
        }
        startConnects()
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
            heard.removeAll()
            policy.reset()
            return
        }
        central.scanForPeripherals(withServices: [BLETransport.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        #if os(iOS)
        resumeRestoredPeripherals(central)
        #endif
    }

    #if os(iOS)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        note("BLE restored by iOS: \(restoredPeripherals.count) peripherals")
    }

    /// Runs the restore plan: adopt links that are still connected (find the service, subscribe,
    /// signed hello again), queue the rest, cancel what is over the cap.
    private func resumeRestoredPeripherals(_ central: CBCentralManager) {
        guard !restoredPeripherals.isEmpty else { return }
        let byID = Dictionary(restoredPeripherals.map { ($0.identifier.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let states = restoredPeripherals.map { p -> (id: String, state: BLERestore.State) in
            (p.identifier.uuidString, p.state == .connected ? .connected : (p.state == .connecting ? .connecting : .disconnected))
        }
        restoredPeripherals = []
        let plan = BLERestore.plan(states, openLinks: links.count, cap: policy.config.maxLinks)
        note("BLE restore plan adopt=\(plan.adopt.count) reconnect=\(plan.reconnect.count) cancel=\(plan.cancel.count)")
        for id in plan.adopt {
            guard let p = byID[id], links[ck(p)] == nil else { continue }
            policy.connected(id)
            let link = Link(id: ck(p), role: .central)
            link.peripheral = p
            links[ck(p)] = link
            p.delegate = self
            p.discoverServices([BLETransport.serviceUUID])
        }
        for id in plan.reconnect {
            guard let p = byID[id] else { continue }
            p.delegate = self
            heard[p.identifier] = p
            policy.discovered(id, rssi: 127)
        }
        for id in plan.cancel { if let p = byID[id] { central.cancelPeripheralConnection(p) } }
        startConnects()
    }
    #endif

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard dropped[peripheral.identifier] == nil, links[ck(peripheral)] == nil else { return }
        if policy.discovered(peripheral.identifier.uuidString, rssi: RSSI.intValue) {
            if heard[peripheral.identifier] == nil {
                note("BLE found a Libre device rssi=\(RSSI) after_start_s=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))")
            }
            heard[peripheral.identifier] = peripheral
            startConnects()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pending.removeValue(forKey: peripheral.identifier)
        heard.removeValue(forKey: peripheral.identifier)
        policy.connected(peripheral.identifier.uuidString)
        let link = Link(id: ck(peripheral), role: .central)
        link.peripheral = peripheral
        links[ck(peripheral)] = link
        peripheral.delegate = self
        peripheral.discoverServices([BLETransport.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pending.removeValue(forKey: peripheral.identifier)
        let wait = policy.failed(peripheral.identifier.uuidString, .other)
        note("BLE connect failed; retry in \(Int(wait)) s")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        pending.removeValue(forKey: peripheral.identifier)
        let wasLinked = links[ck(peripheral)] != nil
        closed(ck(peripheral))
        policy.disconnected(peripheral.identifier.uuidString)
        // Out of range or the app went away: queue it again; the next scan result or the
        // connect queue brings it back (with backoff if it keeps failing).
        if wasLinked, running, dropped[peripheral.identifier] == nil {
            heard[peripheral.identifier] = peripheral
            policy.discovered(peripheral.identifier.uuidString, rssi: 127)
            startConnects()
        }
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
        #if os(iOS)
        resumeRestoredSubscribers()
        #endif
        guard !serviceAdded else { return }
        addServiceAndAdvertise(peripheral)
    }

    #if os(iOS)
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        guard let service = services.first(where: { $0.uuid == BLETransport.serviceUUID }),
              let ch = service.characteristics?.first(where: { $0.uuid == BLETransport.characteristicUUID }) as? CBMutableCharacteristic else { return }
        // The service is still published: keep using it instead of adding a second copy.
        characteristic = ch
        serviceAdded = true
        restoredSubscribers = ch.subscribedCentrals ?? []
        note("BLE restored by iOS: service and \(restoredSubscribers.count) subscribed centrals")
    }

    /// Centrals still subscribed to our service after a relaunch: open their links again (signed
    /// hello again; the old verified state was in memory).
    private func resumeRestoredSubscribers() {
        let centrals = restoredSubscribers
        restoredSubscribers = []
        for central in centrals where links[pk(central)] == nil {
            let link = Link(id: pk(central), role: .peripheral)
            link.central = central
            link.mtu = min(512, central.maximumUpdateValueLength)
            links[pk(central)] = link
            linkReady(link)
        }
    }
    #endif

    /// Peripheral side health: re-add the service or restart advertising when it failed or stopped.
    func watchAdvertising() {
        guard running, let p = peripheralManager else { return }
        guard advertiseWatch.check(poweredOn: p.state == .poweredOn, advertising: p.isAdvertising) == .restart else { return }
        if serviceAdded { advertiseWatch.attempted(); startAdvertising(p) } else { addServiceAndAdvertise(p) }
    }

    private func startAdvertising(_ peripheral: CBPeripheralManager) {
        peripheral.stopAdvertising()
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BLETransport.serviceUUID],
                                     CBAdvertisementDataLocalNameKey: "Libre"])
    }

    private func addServiceAndAdvertise(_ peripheral: CBPeripheralManager) {
        advertiseWatch.attempted()
        peripheral.removeAllServices()
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
            advertiseWatch.failed()
            onEvent(.problem("Bluetooth service failed: \(error.localizedDescription). Trying again."))
            return
        }
        startAdvertising(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { advertiseWatch.failed(); onEvent(.problem("Bluetooth advertising failed: \(error.localizedDescription). Trying again.")) }
        else { advertiseWatch.started(); note("BLE advertising as \(displayName)") }
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
