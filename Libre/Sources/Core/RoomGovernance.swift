// RoomGovernance.swift
// Pasa: per-room admin, membership, key epochs, kick and close. Pure Swift, tested on Linux.
//
// Room state is ONE signed document, the manifest: seq, pinned admin key, co-admins, key epoch,
// member cap, open or closed, listed or hidden, members (device id, name, signing and key
// agreement public keys), banned keys, and the current epoch key sealed to each member.
// Every admin action (admit, kick, close, reopen, cap, listed, promote) is a new manifest with
// seq + 1, signed by the room admin key or a co-admin already in the accepted manifest.
//
// Keys:
// - The base key comes from the passcode (or the QR code). It only seals room control traffic
//   (manifests, join requests) and proves you may ask to join.
// - Chat, asks, answers and media are sealed with the epoch key. New rooms start at epoch 1:
//   a random key that is NOT derivable from the passcode, handed out by an admin device.
// - Kick = remove the member, ban its key, make a new random epoch key and seal it to each
//   remaining member. The kicked device cannot read new traffic. What it already received stays
//   readable on that device.
// - Rooms from before this build stay at epoch 0 (the base key) until the first kick.

import Foundation

public enum RoomLimits {
    public static let defaultCap = 12
    public static let minCap = 2
    public static let maxCap = 30
    /// After a rotation, packets sealed with the previous epoch are still accepted this long
    /// (messages already in flight or in an outbox).
    public static let previousEpochGrace: TimeInterval = 120
    public static func clampCap(_ n: Int) -> Int { min(max(n, minCap), maxCap) }
}

public struct RoomMember: Codable, Equatable, Sendable, Identifiable {
    public var device: String
    public var name: String
    public var signKey: Data
    public var boxKey: Data
    public var joinedAt: Date
    public var id: String { RoomCrypto.base64url(signKey) }
    public var fingerprint: String { Fingerprint.of(signKey) }

    public init(device: String, name: String, signKey: Data, boxKey: Data, joinedAt: Date) {
        self.device = device
        self.name = name
        self.signKey = signKey
        self.boxKey = boxKey
        self.joinedAt = joinedAt
    }
}

public enum RoomOpenState: String, Codable, Sendable { case open, closed }

public struct RoomManifest: Codable, Equatable, Sendable {
    public var room: String
    public var label: String
    public var seq: Int
    public var adminKey: Data
    public var adminName: String
    public var coAdmins: [Data]
    public var epoch: Int
    public var cap: Int
    public var state: RoomOpenState
    public var listed: Bool
    public var passcode: Bool
    public var members: [RoomMember]
    public var banned: [Data]
    /// Member signing key (base64url) -> current epoch key sealed to that member. Empty at epoch 0.
    public var boxes: [String: Data]
    public var issuedAt: Date

    public var isFull: Bool { members.count >= cap }
    public func member(_ signKey: Data) -> RoomMember? { members.first { $0.signKey == signKey } }
    public func isCoAdmin(_ signKey: Data) -> Bool { coAdmins.contains(signKey) }
    /// "Open", "Closed" or "Full", for beacons and badges.
    public var statusWord: String { state == .closed ? "Closed" : (isFull ? "Full" : "Open") }
}

/// A device asking to be admitted. Signed by the device's own key and sealed with the base key,
/// so it proves the asker knows the passcode (or has the QR code) and owns the key it lists.
public struct JoinRequest: Codable, Equatable, Sendable {
    public var room: String
    public var device: String
    public var name: String
    public var signKey: Data
    public var boxKey: Data
    public var at: Date
}

/// Body of a `.roomControl` message (always sealed with the base key).
public struct RoomControl: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case manifest   // blob = signed manifest
        case join       // blob = signed join request
        case want       // "send me the newest manifest", haveSeq = what I have
    }
    public var type: Kind
    public var blob: SignedBlob?
    public var haveSeq: Int?

    public init(type: Kind, blob: SignedBlob? = nil, haveSeq: Int? = nil) {
        self.type = type
        self.blob = blob
        self.haveSeq = haveSeq
    }

    public func encoded() -> String? { PasaJSON.string(self) }
    public static func decode(_ body: String) -> RoomControl? { PasaJSON.value(RoomControl.self, from: body) }
}

/// What this device knows about a room's governance. Stored inside the Room record.
public struct RoomGov: Codable, Equatable, Sendable {
    /// Pinned admin signing key (from the QR code, or trust on first use from a manifest that
    /// opened with the passcode key).
    public var adminKey: Data?
    /// Admin signing private key. Only on the device that created the room.
    public var adminSecret: Data?
    public var manifest: RoomManifest?
    public var signed: SignedBlob?
    /// Epoch number (as text) -> 32-byte key this device holds.
    public var epochKeys: [String: Data]
    /// Joined, not admitted yet.
    public var pending: Bool
    /// Removed (kicked) by an admin.
    public var removed: Bool
    /// When this device accepted the latest rotation (previous epoch still accepted briefly).
    public var rotatedAt: Date?

    public init(adminKey: Data? = nil, adminSecret: Data? = nil, manifest: RoomManifest? = nil, signed: SignedBlob? = nil,
                epochKeys: [String: Data] = [:], pending: Bool = false, removed: Bool = false, rotatedAt: Date? = nil) {
        self.adminKey = adminKey
        self.adminSecret = adminSecret
        self.manifest = manifest
        self.signed = signed
        self.epochKeys = epochKeys
        self.pending = pending
        self.removed = removed
        self.rotatedAt = rotatedAt
    }

    public var seq: Int { manifest?.seq ?? 0 }
}

extension Room {
    /// Current key epoch (0 = the base key).
    public var epoch: Int { gov?.manifest?.epoch ?? 0 }

    /// Key for sealing new content, or nil when this device has no key for the current epoch
    /// (waiting to be admitted, or removed).
    public var contentKey: Data? {
        let e = epoch
        if e == 0 {
            // Joined and waiting for the first manifest: do not guess that the room still uses
            // the passcode key (new rooms do not).
            if let gov, gov.manifest == nil, gov.pending { return nil }
            return key
        }
        return gov?.epochKeys[String(e)]
    }

    /// Key to open content sealed at `epoch`. Older epochs only shortly after a rotation.
    public func openKey(epoch e: Int, now: Date = Date()) -> Data? {
        let current = epoch
        if e == current { return e == 0 ? key : gov?.epochKeys[String(e)] }
        guard e < current, e > 0 || current == 0, let rotated = gov?.rotatedAt,
              now.timeIntervalSince(rotated) <= RoomLimits.previousEpochGrace else { return nil }
        return gov?.epochKeys[String(e)]
    }

    public var isClosed: Bool { gov?.manifest?.state == .closed }
    public var isRemoved: Bool { gov?.removed == true }
    public var isPending: Bool { gov?.pending == true }
    public var isListed: Bool { gov?.manifest?.listed == true }
    public var memberCount: Int { gov?.manifest?.members.count ?? 0 }
    public var cap: Int { gov?.manifest?.cap ?? RoomLimits.defaultCap }
    public var adminFingerprint: String? { gov?.adminKey.map(Fingerprint.of) }

    /// This device may write new messages in the room.
    public var canSend: Bool { contentKey != nil && !isRemoved && !isClosed }

    /// Why this device cannot write here, or nil when it can.
    public var sendBlocker: String? {
        if isRemoved { return "An admin removed this device from \(label). Ask them to let you back in, or switch rooms." }
        if isClosed { return "\(label) is closed by its admin. Its chat and memory are read-only." }
        if contentKey == nil {
            if let m = gov?.manifest, m.isFull { return "\(label) is full (\(m.members.count)/\(m.cap)). Ask the admin to raise the cap or remove someone." }
            return "Waiting for a \(label) admin to let you in. An admin device must be nearby with Pasa open."
        }
        return nil
    }
}

public enum RoomGovernor {
    public static let manifestDomain = "manifest"
    public static let joinDomain = "join"

    // MARK: Create and migrate

    /// Sets up governance on the device that creates the room: a new admin key, this device as
    /// the first member, and (rotate: true) a random epoch 1 key. Returns the signed manifest.
    @discardableResult
    public static func setUp(_ room: inout Room, identity: DeviceIdentity, device: String, name: String, now: Date = Date(),
                             rotate: Bool = true, listed: Bool = true, cap: Int = RoomLimits.defaultCap) -> SignedBlob? {
        guard !room.isDefault else { return nil }
        let adminSecret = PasaSign.newSecret()
        guard let adminKey = PasaSign.publicKey(ofSecret: adminSecret) else { return nil }
        let me = RoomMember(device: device, name: name, signKey: identity.signKey, boxKey: identity.boxKey, joinedAt: now)
        var manifest = RoomManifest(room: room.id, label: room.label, seq: 1, adminKey: adminKey, adminName: name, coAdmins: [],
                                    epoch: 0, cap: RoomLimits.clampCap(cap), state: .open, listed: listed,
                                    passcode: room.usesPasscode, members: [me], banned: [], boxes: [:], issuedAt: now)
        let gov = RoomGov(adminKey: adminKey, adminSecret: adminSecret)
        if rotate {
            let fresh = RoomCrypto.randomKey()
            manifest.epoch = 1
            if let box = KeyBox.seal(fresh, to: identity.boxKey, room: room.id, epoch: 1) { manifest.boxes[me.id] = box }
        }
        guard let blob = PasaSign.sign(manifest, secret: adminSecret, domain: manifestDomain) else { return nil }
        let before = room.gov
        room.gov = gov
        if case .applied = accept(blob, into: &room, identity: identity, now: now) { return blob }
        room.gov = before
        return nil
    }

    /// Rooms from before admin keys: the creator device (pinned by device id) makes an admin key
    /// on the next launch. The room stays at epoch 0 (no rotation) and Hidden.
    @discardableResult
    public static func migrate(_ room: inout Room, selfID: String, identity: DeviceIdentity, name: String, now: Date = Date()) -> SignedBlob? {
        guard !room.isDefault, room.gov?.manifest == nil, room.gov?.adminKey == nil, !room.creator.isEmpty, room.creator == selfID else { return nil }
        return setUp(&room, identity: identity, device: selfID, name: name, now: now, rotate: false, listed: false)
    }

    // MARK: Roles

    /// Secret this device signs admin actions with: the room admin key (creator) or, for a
    /// co-admin, its own device key. nil when this device is not an admin of the room.
    public static func signerSecret(_ room: Room, identity: DeviceIdentity) -> Data? {
        guard let gov = room.gov, let m = gov.manifest else { return nil }
        if let secret = gov.adminSecret, PasaSign.publicKey(ofSecret: secret) == m.adminKey { return secret }
        if m.isCoAdmin(identity.signKey), m.member(identity.signKey) != nil { return identity.signSecret }
        return nil
    }

    public static func isAdmin(_ room: Room, identity: DeviceIdentity) -> Bool { signerSecret(room, identity: identity) != nil }
    public static func isCreatorAdmin(_ room: Room) -> Bool { room.gov?.adminSecret != nil }

    // MARK: Accept a manifest

    public struct Change: Equatable, Sendable {
        public var admitted = false
        public var removed = false
        public var rekeyed = false
        public var closed: Bool? = nil
        public var firstPin = false
    }

    public enum Acceptance: Equatable, Sendable {
        case applied(Change)
        case stale
        case rejected(String)
    }

    /// Checks and applies a signed manifest. Rules: valid signature; same room; signed by the
    /// pinned admin key or by a co-admin of the manifest this device already accepted; the
    /// admin key never changes once pinned (first one is pinned only if self-signed); seq must
    /// go up (replays and rollbacks are ignored); epoch never goes down.
    public static func accept(_ blob: SignedBlob, into room: inout Room, identity: DeviceIdentity, now: Date = Date()) -> Acceptance {
        guard blob.domain == manifestDomain, blob.isValid else { return .rejected("bad signature") }
        guard let m = blob.decode(RoomManifest.self) else { return .rejected("unreadable manifest") }
        guard m.room == room.id else { return .rejected("another room") }
        var gov = room.gov ?? RoomGov()
        var change = Change()
        if let pinned = gov.adminKey {
            guard m.adminKey == pinned else { return .rejected("admin key does not match the pinned admin") }
        } else {
            guard blob.signer == m.adminKey else { return .rejected("first manifest must be signed by its admin") }
            change.firstPin = true
        }
        let current = gov.manifest
        let byAdmin = blob.signer == m.adminKey
        let byCoAdmin = current.map { $0.isCoAdmin(blob.signer) && $0.member(blob.signer) != nil } ?? false
        guard byAdmin || byCoAdmin else { return .rejected("not signed by a room admin") }
        if let current {
            if m.seq <= current.seq { return .stale }
            guard m.epoch >= current.epoch else { return .rejected("epoch went backwards") }
        }
        guard m.cap >= RoomLimits.minCap, m.cap <= RoomLimits.maxCap, m.seq > 0, m.epoch >= 0 else { return .rejected("out of range") }

        gov.adminKey = m.adminKey
        let me = m.member(identity.signKey)
        let wasMember = current?.member(identity.signKey) != nil
        if m.epoch > 0, me != nil, gov.epochKeys[String(m.epoch)] == nil,
           let box = m.boxes[RoomCrypto.base64url(identity.signKey)],
           let key = KeyBox.open(box, secret: identity.boxSecret, room: room.id, epoch: m.epoch) {
            gov.epochKeys[String(m.epoch)] = key
        }
        if let current, m.epoch > current.epoch {
            change.rekeyed = true
            gov.rotatedAt = now
        }
        if me == nil {
            if wasMember || m.banned.contains(identity.signKey) {
                change.removed = !gov.removed
                gov.removed = true
                gov.pending = false
            } else {
                gov.pending = true
            }
        } else {
            change.admitted = gov.pending || gov.removed
            gov.pending = false
            gov.removed = false
        }
        if current?.state != m.state { change.closed = m.state == .closed }
        // Keep the current and the previous two epoch keys.
        let keep = Set((max(0, m.epoch - 2)...m.epoch).map(String.init))
        gov.epochKeys = gov.epochKeys.filter { keep.contains($0.key) }
        gov.manifest = m
        gov.signed = blob
        room.gov = gov
        return .applied(change)
    }

    // MARK: Admin actions (each returns the new signed manifest, already applied locally)

    static func issue(_ room: inout Room, identity: DeviceIdentity, now: Date, _ mutate: (inout RoomManifest) -> Bool) -> SignedBlob? {
        guard let current = room.gov?.manifest, let secret = signerSecret(room, identity: identity) else { return nil }
        var next = current
        guard mutate(&next) else { return nil }
        next.seq = current.seq + 1
        next.issuedAt = now
        guard let blob = PasaSign.sign(next, secret: secret, domain: manifestDomain) else { return nil }
        guard case .applied = accept(blob, into: &room, identity: identity, now: now) else { return nil }
        return blob
    }

    /// New random epoch key, sealed to every member in `m`. Never derivable from the passcode.
    static func rotate(_ m: inout RoomManifest, room: String) {
        let fresh = RoomCrypto.randomKey()
        m.epoch += 1
        m.boxes = [:]
        for member in m.members {
            if let box = KeyBox.seal(fresh, to: member.boxKey, room: room, epoch: m.epoch) { m.boxes[member.id] = box }
        }
    }

    public enum AdmitResult: Equatable, Sendable {
        case admitted(SignedBlob)
        /// Already a member: re-send the current manifest so it gets its key box.
        case already
        case refused(String)
        case invalid
    }

    /// Admin side of a join request: valid and signed by the key it lists, room open, key not
    /// banned, under the cap. Then the member is added and the current epoch key is sealed to it.
    public static func admit(_ request: SignedBlob, room: inout Room, identity: DeviceIdentity, now: Date = Date()) -> AdmitResult {
        guard request.domain == joinDomain, request.isValid, let r = request.decode(JoinRequest.self),
              r.signKey == request.signer, r.room == room.id, r.boxKey.count == 32 else { return .invalid }
        guard let m = room.gov?.manifest, signerSecret(room, identity: identity) != nil else { return .invalid }
        if let existing = m.member(r.signKey), existing.boxKey == r.boxKey { return .already }
        if m.banned.contains(r.signKey) { return .refused("removed by an admin") }
        if m.state == .closed { return .refused("room closed") }
        if m.isFull { return .refused("room full (\(m.members.count)/\(m.cap))") }
        let key = room.contentKey
        let roomID = room.id
        let blob = issue(&room, identity: identity, now: now) { next in
            next.members.removeAll { $0.signKey == r.signKey }
            let member = RoomMember(device: r.device, name: r.name, signKey: r.signKey, boxKey: r.boxKey, joinedAt: now)
            next.members.append(member)
            if next.epoch > 0 {
                guard let key, let box = KeyBox.seal(key, to: r.boxKey, room: roomID, epoch: next.epoch) else { return false }
                next.boxes[member.id] = box
            }
            return true
        }
        return blob.map { .admitted($0) } ?? .invalid
    }

    /// Removes a member, bans its key and rotates the room key. The admin key holder cannot be
    /// kicked, and nobody kicks themselves.
    public static func kick(_ signKey: Data, room: inout Room, identity: DeviceIdentity, now: Date = Date()) -> SignedBlob? {
        guard signKey != identity.signKey else { return nil }
        let roomID = room.id
        return issue(&room, identity: identity, now: now) { next in
            guard next.member(signKey) != nil, signKey != next.adminKey else { return false }
            next.members.removeAll { $0.signKey == signKey }
            next.coAdmins.removeAll { $0 == signKey }
            if !next.banned.contains(signKey) { next.banned.append(signKey) }
            rotate(&next, room: roomID)
            return true
        }
    }

    public static func setClosed(_ closed: Bool, room: inout Room, identity: DeviceIdentity, now: Date = Date()) -> SignedBlob? {
        issue(&room, identity: identity, now: now) { next in
            let state: RoomOpenState = closed ? .closed : .open
            guard next.state != state else { return false }
            next.state = state
            return true
        }
    }

    public static func setCap(_ cap: Int, room: inout Room, identity: DeviceIdentity, now: Date = Date()) -> SignedBlob? {
        issue(&room, identity: identity, now: now) { next in
            let clean = RoomLimits.clampCap(cap)
            guard next.cap != clean else { return false }
            next.cap = clean
            return true
        }
    }

    public static func setListed(_ listed: Bool, room: inout Room, identity: DeviceIdentity, now: Date = Date()) -> SignedBlob? {
        issue(&room, identity: identity, now: now) { next in
            guard next.listed != listed else { return false }
            next.listed = listed
            return true
        }
    }

    /// Only the room admin key may add or remove co-admins.
    public static func setCoAdmin(_ signKey: Data, on: Bool, room: inout Room, identity: DeviceIdentity, now: Date = Date()) -> SignedBlob? {
        guard isCreatorAdmin(room) else { return nil }
        return issue(&room, identity: identity, now: now) { next in
            guard next.member(signKey) != nil, signKey != identity.signKey else { return false }
            let has = next.coAdmins.contains(signKey)
            guard has != on else { return false }
            if on { next.coAdmins.append(signKey) } else { next.coAdmins.removeAll { $0 == signKey } }
            return true
        }
    }

    // MARK: Joiner side

    public static func joinRequest(room: Room, identity: DeviceIdentity, device: String, name: String, now: Date = Date()) -> SignedBlob? {
        let r = JoinRequest(room: room.id, device: device, name: name, signKey: identity.signKey, boxKey: identity.boxKey, at: now)
        return identity.sign((try? PasaJSON.encoder.encode(r)) ?? Data(), domain: joinDomain)
    }

    /// True when this device should (re)send a join request: it holds no current key (or is not
    /// on the roster yet), was not removed, and the room is open and not full as far as it knows.
    public static func wantsAdmission(_ room: Room, identity: DeviceIdentity) -> Bool {
        guard !room.isDefault, let gov = room.gov, !gov.removed else { return false }
        guard let m = gov.manifest else { return gov.pending }
        guard m.member(identity.signKey) == nil else { return false }
        return m.state == .open && !m.isFull && !m.banned.contains(identity.signKey)
    }
}
