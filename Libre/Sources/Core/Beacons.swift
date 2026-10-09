// Beacons.swift
// Pasa: Nearby rooms (signed room beacons) and AI Mac status (awake, asleep, offline).
// Pure Swift, tested on Linux.
//
// Room beacons are CLEAR on purpose: anyone nearby sees a Listed room's name, member count,
// cap, open/closed/full, whether it needs a passcode, the admin's display name and admin key.
// They never carry the room key or the passcode. Hidden rooms send no beacon.
// A beacon is signed by the room admin key, so a relay cannot change the counts or the name.
// A stranger can still sign a beacon for any room tag with their OWN key; joiners pin the admin
// key from the first manifest that opens with the passcode key and show its fingerprint.

import Foundation

public struct RoomBeacon: Codable, Equatable, Sendable, Identifiable {
    public static let proto = 3
    public var room: String
    public var label: String
    public var members: Int
    public var cap: Int
    /// "open", "closed" or "full".
    public var status: String
    public var passcode: Bool
    public var adminName: String
    public var adminKey: Data
    public var proto: Int
    public var seq: Int
    public var at: Date

    public var id: String { room }
    public var isFull: Bool { status == "full" }
    public var isClosed: Bool { status == "closed" }
    public var badge: String {
        switch status {
        case "closed": return "Closed"
        case "full": return "Full \(members)/\(cap)"
        default: return "\(members)/\(cap)"
        }
    }
    public var adminFingerprint: String { Fingerprint.of(adminKey) }

    /// Beacon for a Listed room this device administers (holds the admin key). nil otherwise.
    public static func make(for room: Room, now: Date = Date()) -> SignedBlob? {
        guard let gov = room.gov, let m = gov.manifest, m.listed, let secret = gov.adminSecret,
              PasaSign.publicKey(ofSecret: secret) == m.adminKey else { return nil }
        let status = m.state == .closed ? "closed" : (m.isFull ? "full" : "open")
        let beacon = RoomBeacon(room: room.id, label: room.label, members: m.members.count, cap: m.cap, status: status,
                                passcode: m.passcode, adminName: m.adminName, adminKey: m.adminKey, proto: proto, seq: m.seq, at: now)
        return PasaSign.sign(beacon, secret: secret, domain: BeaconRegistry.domain)
    }
}

/// Beacons heard recently. Expire 45 s after they were last heard.
public final class BeaconRegistry {
    public static let domain = "beacon"
    public static let expireAfter: TimeInterval = 45
    public static let sendEvery: TimeInterval = 12
    public static let ttl = 3

    public struct Heard: Equatable {
        public var beacon: RoomBeacon
        public var heardAt: Date
        /// Two different admin keys claimed this room tag recently.
        public var conflict: Bool
    }

    public private(set) var heard: [String: Heard] = [:]

    public init() {}

    /// Checks and stores a beacon. False when it is unsigned, tampered, signed by a key other
    /// than the admin key it names, or older (lower seq) than one already heard from that admin.
    @discardableResult
    public func ingest(_ blob: SignedBlob, now: Date = Date()) -> Bool {
        guard blob.domain == BeaconRegistry.domain, blob.isValid, let b = blob.decode(RoomBeacon.self),
              b.adminKey == blob.signer, !b.room.isEmpty, !b.label.isEmpty, b.cap > 0 else { return false }
        prune(now: now)
        if let old = heard[b.room] {
            if old.beacon.adminKey == b.adminKey {
                if b.seq < old.beacon.seq { return false }
                heard[b.room] = Heard(beacon: b, heardAt: now, conflict: old.conflict)
            } else {
                // Keep the first admin heard, flag the clash.
                heard[b.room]?.conflict = true
                heard[b.room]?.heardAt = now
                return false
            }
        } else {
            heard[b.room] = Heard(beacon: b, heardAt: now, conflict: false)
        }
        return true
    }

    public func prune(now: Date = Date()) {
        heard = heard.filter { now.timeIntervalSince($0.value.heardAt) <= BeaconRegistry.expireAfter }
    }

    /// Nearby rooms, newest first by name.
    public func nearby(now: Date = Date()) -> [Heard] {
        prune(now: now)
        return heard.values.sorted { $0.beacon.label < $1.beacon.label }
    }
}

// MARK: AI Mac status

public struct AIStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case awake, asleep }
    public var device: String
    public var state: State
    public var model: String
    public var queue: Int
    /// Room tags this Mac answers in.
    public var rooms: [String]
    public var at: Date

    public init(device: String, state: State, model: String, queue: Int, rooms: [String], at: Date) {
        self.device = device
        self.state = state
        self.model = model
        self.queue = queue
        self.rooms = rooms
        self.at = at
    }
}

public enum AIAvailability: String, Equatable, Sendable {
    case awake = "Awake"
    case asleep = "Asleep"
    case offline = "Offline"
    /// An AI Mac is awake nearby but has not joined this room.
    case notServing = "Not in this room"
    case unknown = "No AI Mac heard"
}

/// Phone side: tracks signed AI status from AI Macs. "Signed-ish": the Mac's device key is
/// pinned the first time a device id is heard (trust on first use), not authenticated.
public final class AIStatusTracker {
    public static let domain = "ai-status"
    public static let sendEvery: TimeInterval = 10
    public static let offlineAfter: TimeInterval = 35
    public static let asleepFor: TimeInterval = 86_400
    public static let ttl = 4

    public enum Transition: Equatable { case woke(String), slept(String) }

    public private(set) var pins: [String: Data] = [:]
    public private(set) var latest: [String: (status: AIStatus, heardAt: Date)] = [:]
    /// Last time an AI Mac was heard waking (asleep or offline -> awake).
    public private(set) var wokeAt: Date?

    public init() {}

    public static func make(_ status: AIStatus, identity: DeviceIdentity) -> SignedBlob? {
        guard let body = try? PasaJSON.encoder.encode(status) else { return nil }
        return identity.sign(body, domain: domain)
    }

    @discardableResult
    public func ingest(_ blob: SignedBlob, now: Date = Date()) -> Transition? {
        guard blob.domain == AIStatusTracker.domain, blob.isValid, let s = blob.decode(AIStatus.self), !s.device.isEmpty else { return nil }
        if let pinned = pins[s.device], pinned != blob.signer { return nil }
        pins[s.device] = blob.signer
        let before = availability(of: s.device, now: now)
        if let old = latest[s.device], old.status.at > s.at { return nil }
        latest[s.device] = (s, now)
        switch (before, s.state) {
        case (.awake, .awake): return nil
        case (_, .awake):
            wokeAt = now
            return .woke(s.device)
        case (.asleep, .asleep): return nil
        case (_, .asleep): return .slept(s.device)
        }
    }

    func availability(of device: String, now: Date) -> AIAvailability {
        guard let entry = latest[device] else { return .unknown }
        let age = now.timeIntervalSince(entry.heardAt)
        switch entry.status.state {
        case .asleep: return age <= AIStatusTracker.asleepFor ? .asleep : .offline
        case .awake: return age <= AIStatusTracker.offlineAfter ? .awake : .offline
        }
    }

    /// Best status for a room: awake beats asleep beats offline; a Mac that is not in the room
    /// only shows as notServing.
    public func availability(room: String, now: Date = Date()) -> AIAvailability {
        var best: AIAvailability = .unknown
        let rank: [AIAvailability: Int] = [.awake: 4, .asleep: 3, .offline: 2, .notServing: 1, .unknown: 0]
        for (device, entry) in latest {
            var a = availability(of: device, now: now)
            if a == .awake || a == .asleep, !entry.status.rooms.contains(room) { a = .notServing }
            if (rank[a] ?? 0) > (rank[best] ?? 0) { best = a }
        }
        return best
    }

    /// Model and queue depth of an awake Mac serving the room (for the header).
    public func detail(room: String, now: Date = Date()) -> AIStatus? {
        latest.values.filter { $0.status.rooms.contains(room) && now.timeIntervalSince($0.heardAt) <= AIStatusTracker.offlineAfter }
            .max { $0.heardAt < $1.heardAt }?.status
    }
}
