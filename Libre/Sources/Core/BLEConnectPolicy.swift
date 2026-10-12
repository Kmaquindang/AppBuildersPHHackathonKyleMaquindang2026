// BLEConnectPolicy.swift
// Libre: who to connect to over Bluetooth, and when (Oct 12, 2026). Pure Swift, tested on Linux.
// Our own design.
//
// Phones hold only a handful of Bluetooth LE links before links get slow and drop, and a scanner
// that connects to everything it hears thrashes in a crowded room. So outgoing connects go
// through one small queue:
// - Cap: at most `maxLinks` links (scanner and advertiser links together). Phones 7, the AI Mac
//   hub 12. Links other devices open to us still count, so a full device stops reaching out.
// - Signal floor: a device heard below `rssiFloor` (default -88 dBm) is not worth a link; a
//   device we already verified this session gets a little more room (`knownRssiFloor`).
// - Strongest first: waiting devices are tried in order of their last signal strength.
// - One or two at a time: at most `maxPending` connects run at once (Android's Bluetooth stack
//   handles parallel connects badly, so Android uses 1).
// - Timeouts and backoff: a connect that does not finish in `connectTimeout` counts as failed.
//   Failures back off 2, 4, 8 ... up to 60 s. Android's well known status 133 (GATT_ERROR) gets
//   3 quick retries first (0.5, 1, 2 s), because it is usually a stack hiccup, not a bad peer.
// Devices are identified here by the radio's id for them (CBPeripheral UUID on Apple, MAC on
// Android); who they really are is settled by the signed hello (BLEPeerBook).

import Foundation

public struct BLEConnectPolicy: Sendable {
    public struct Config: Equatable, Sendable {
        public var maxLinks: Int
        public var maxPending: Int
        public var rssiFloor: Int
        public var knownRssiFloor: Int
        public var connectTimeout: TimeInterval
        public var candidateLifetime: TimeInterval

        public init(maxLinks: Int = 7, maxPending: Int = 2, rssiFloor: Int = -88, knownRssiFloor: Int = -95,
                    connectTimeout: TimeInterval = 10, candidateLifetime: TimeInterval = 30) {
            self.maxLinks = maxLinks
            self.maxPending = maxPending
            self.rssiFloor = rssiFloor
            self.knownRssiFloor = knownRssiFloor
            self.connectTimeout = connectTimeout
            self.candidateLifetime = candidateLifetime
        }

        public static let phone = Config()
        public static let androidPhone = Config(maxPending: 1)
        public static let hub = Config(maxLinks: 12)
    }

    public enum Failure: Equatable, Sendable {
        /// Android GATT status 133: retry quickly a few times.
        case gattError133
        case other
    }

    public static let gattError133 = 133
    public static let quickRetries: [TimeInterval] = [0.5, 1, 2]
    public static let maxBackoff: TimeInterval = 60

    struct Candidate: Sendable { var rssi: Int; var seen: Date }
    struct Backoff: Sendable { var quick: Int; var slow: Int; var until: Date }

    public var config: Config
    private var candidates: [String: Candidate] = [:]
    private var pending: [String: Date] = [:]
    private var backoff: [String: Backoff] = [:]
    /// Radio ids of devices verified this session (allowed the weaker signal floor).
    private var known: Set<String> = []
    /// Radio ids we must not connect to (linked already, or dropped by the tie-break).
    private var excluded: Set<String> = []

    public init(config: Config = .phone) { self.config = config }

    public var pendingIDs: [String] { pending.keys.sorted() }
    public var waitingIDs: [String] { candidates.keys.sorted() }

    /// A scan heard `id` at `rssi` dBm. Returns false when it is ignored (too weak, backing off,
    /// linked or excluded).
    @discardableResult
    public mutating func discovered(_ id: String, rssi: Int, now: Date = Date()) -> Bool {
        guard !excluded.contains(id), pending[id] == nil else { return false }
        // 127 means "unknown" on Apple platforms: let it through at the floor.
        let strength = rssi == 127 ? config.rssiFloor : rssi
        let floor = known.contains(id) ? config.knownRssiFloor : config.rssiFloor
        guard strength >= floor else { candidates.removeValue(forKey: id); return false }
        if let b = backoff[id], b.until > now { return false }
        candidates[id] = Candidate(rssi: strength, seen: now)
        return true
    }

    /// Connects to start now, given how many links are up. Marks them pending.
    public mutating func next(linked: Int, now: Date = Date()) -> [String] {
        candidates = candidates.filter { now.timeIntervalSince($0.value.seen) < config.candidateLifetime }
        var room = min(config.maxLinks - linked - pending.count, config.maxPending - pending.count)
        guard room > 0 else { return [] }
        var out: [String] = []
        for (id, c) in candidates.sorted(by: { ($0.value.rssi, $1.key) > ($1.value.rssi, $0.key) }) where room > 0 {
            if let b = backoff[id], b.until > now { continue }
            _ = c
            candidates.removeValue(forKey: id)
            pending[id] = now
            out.append(id)
            room -= 1
        }
        return out
    }

    /// The connect finished (link up). Clears its backoff.
    public mutating func connected(_ id: String) {
        pending.removeValue(forKey: id)
        backoff.removeValue(forKey: id)
        excluded.insert(id)
    }

    /// The link to `id` was verified by its signed hello.
    public mutating func verified(_ id: String) { known.insert(id) }

    /// The link closed. The device may be tried again (after `delay`, for example a tie-break drop
    /// stays excluded by the caller via `exclude`).
    public mutating func disconnected(_ id: String) {
        pending.removeValue(forKey: id)
        excluded.remove(id)
    }

    public mutating func exclude(_ id: String) { excluded.insert(id); candidates.removeValue(forKey: id) }
    public mutating func include(_ id: String) { excluded.remove(id) }

    /// A connect failed. Returns how long to wait before that device may be tried again.
    @discardableResult
    public mutating func failed(_ id: String, _ failure: Failure, now: Date = Date()) -> TimeInterval {
        pending.removeValue(forKey: id)
        excluded.remove(id)
        var b = backoff[id] ?? Backoff(quick: 0, slow: 0, until: now)
        let delay: TimeInterval
        if failure == .gattError133 && b.quick < BLEConnectPolicy.quickRetries.count {
            delay = BLEConnectPolicy.quickRetries[b.quick]
            b.quick += 1
        } else {
            delay = min(BLEConnectPolicy.maxBackoff, 2 * pow(2, Double(b.slow)))
            b.slow += 1
        }
        b.until = now.addingTimeInterval(delay)
        backoff[id] = b
        return delay
    }

    /// Pending connects that ran past the timeout. The caller cancels them; each counts as failed.
    public mutating func timedOut(now: Date = Date()) -> [String] {
        let late = pending.filter { now.timeIntervalSince($0.value) >= config.connectTimeout }.map { $0.key }.sorted()
        for id in late { failed(id, .other, now: now) }
        return late
    }

    /// Ids whose backoff ended and that a fresh scan result should re-add.
    public func backingOff(_ id: String, now: Date = Date()) -> Bool { (backoff[id]?.until ?? .distantPast) > now }

    public mutating func reset() {
        candidates.removeAll(); pending.removeAll(); excluded.removeAll()
    }
}
