// Rooms.swift
// Pasa: rooms let unrelated teams share one physical mesh. Pure Swift, tested on Linux.
//
// - A room has a human label people can say out loud ("BOHOL-7") and a random 256-bit key. The
//   label is NOT the secret: the key is, and it travels only in the QR code / join string.
// - Every packet keeps a clear routing header (version, id, room tag, origin, destination, ttl,
//   hops) so any device can dedupe and relay it. Everything else is sealed with
//   ChaCha20-Poly1305 under a key derived from the room key (HKDF-SHA256). The room tag is also
//   derived from the key, so it does not reveal the label or the key.
// - A device relays other rooms' packets without being able to read them, and never shows or
//   stores them (only a small, short-lived outbox slot when no peer is linked).
// - The Default room uses a published key so devices from before rooms keep talking. It is
//   separated, not private. Create a room for privacy.
//
// Crypto: CryptoKit on Apple platforms; Apple's open-source swift-crypto (same API, module
// `Crypto`) for the Linux test build only.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct Room: Codable, Equatable, Identifiable, Sendable {
    /// Spoken label, for example "BOHOL-7". Not secret.
    public var label: String
    /// 32 random bytes. The secret.
    public var key: Data
    /// Device id of the creator: pinned admin of this room.
    public var creator: String
    public var createdAt: Date
    /// Admin device ids chosen on the AI Mac for this room (the creator is always admin too).
    public var admins: [String]
    /// "Clear timeline" watermark for this room.
    public var clearedAt: Date?

    public init(label: String, key: Data, creator: String, createdAt: Date = Date(), admins: [String] = [], clearedAt: Date? = nil) {
        self.label = label
        self.key = key
        self.creator = creator
        self.createdAt = createdAt
        self.admins = admins
        self.clearedAt = clearedAt
    }

    /// Room tag: first 8 bytes of HKDF(key), hex. Same on every member device. Also the folder name.
    public var id: String { RoomCrypto.tag(for: key) }
    public var isDefault: Bool { key == RoomCrypto.defaultKey }
    public var displayName: String { isDefault ? "Default (open)" : label }

    /// Admin device ids for this room: the pinned creator plus those ticked on the Mac.
    public func adminDevices(selfID: String) -> Set<String> {
        AdminPolicy.devices(adminIDs: admins + (creator.isEmpty ? [] : [creator]), selfID: selfID)
    }

    // MARK: Join string ("PASA1.<label>.<creator>.<key>", base64url parts)

    public static let joinPrefix = "PASA1"

    public var joinString: String {
        [Room.joinPrefix, label, RoomCrypto.base64url(Data(creator.utf8)), RoomCrypto.base64url(key)].joined(separator: ".")
    }

    /// Parses a pasted or scanned join string. nil when it is not a valid Pasa room code.
    public static func parse(joinString raw: String, now: Date = Date()) -> Room? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == joinPrefix else { return nil }
        let label = Room.cleanLabel(parts[1])
        guard !label.isEmpty,
              let creatorData = RoomCrypto.fromBase64url(parts[2]),
              let key = RoomCrypto.fromBase64url(parts[3]), key.count == 32 else { return nil }
        return Room(label: label, key: key, creator: String(decoding: creatorData, as: UTF8.self), createdAt: now)
    }

    /// Labels are short and easy to say: A-Z, 0-9 and "-", at most 16 characters.
    public static func cleanLabel(_ raw: String) -> String {
        let upper = raw.uppercased().replacingOccurrences(of: " ", with: "-")
        let kept = upper.unicodeScalars.filter { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }
        return String(String.UnicodeScalarView(kept).prefix(16))
    }

    /// A new room with a fresh random key. Empty label gets "ROOM-" plus 4 random characters.
    public static func create(label raw: String, creator: String, now: Date = Date()) -> Room {
        var label = cleanLabel(raw)
        if label.isEmpty {
            let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
            label = "ROOM-" + String((0..<4).map { _ in alphabet.randomElement()! })
        }
        return Room(label: label, key: RoomCrypto.randomKey(), creator: creator, createdAt: now, admins: [])
    }

    /// The open room every device starts in (and where data from before rooms is migrated).
    public static func makeDefault(now: Date = Date()) -> Room {
        Room(label: "DEFAULT", key: RoomCrypto.defaultKey, creator: "", createdAt: now)
    }
}

public enum RoomCrypto {
    static let salt = Data("pasa-room-v1".utf8)

    /// Published key of the Default room: SHA-256 of a fixed string. Anyone can read Default.
    public static let defaultKey: Data = Data(SHA256.hash(data: Data("pasa-default-room-v1".utf8)))

    public static func randomKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func derive(_ key: Data, info: String, bytes: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt, info: Data(info.utf8), outputByteCount: bytes)
    }

    /// 8-byte room tag as 16 hex characters.
    public static func tag(for key: Data) -> String {
        derive(key, info: "pasa-room-tag", bytes: 8).withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func sealingKey(_ key: Data) -> SymmetricKey { derive(key, info: "pasa-room-seal", bytes: 32) }

    /// ChaCha20-Poly1305 combined box (nonce + ciphertext + tag).
    public static func seal(_ plaintext: Data, key: Data, aad: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: sealingKey(key), authenticating: aad).combined
    }

    public static func open(_ combined: Data, key: Data, aad: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: sealingKey(key), authenticating: aad)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Seals a message for a room and opens it again. The clear header keeps what relays need.
public enum RoomEnvelope {
    /// Header fields bound to the ciphertext (relays may change ttl and hops, so those are not).
    static func aad(_ m: MeshMessage, room: String) -> Data {
        Data("\(m.wireVersion)|\(m.id.uuidString)|\(room)|\(m.origin)|\(m.destination?.label ?? "*")".utf8)
    }

    /// Outer packet: routing fields in the clear, everything else sealed.
    public static func seal(_ inner: MeshMessage, in room: Room) throws -> MeshMessage {
        var plain = inner
        plain.v = MeshMessage.protocolVersion
        let body = try MeshCodec.encode(plain)
        var outer = MeshMessage(id: inner.id, origin: inner.origin, destination: inner.destination, kind: .sealed, body: "",
                                ttl: inner.ttl, hops: inner.hops, createdAt: Date(timeIntervalSince1970: 0),
                                v: MeshMessage.protocolVersion)
        outer.room = room.id
        outer.sealed = RoomCrypto.base64url(try RoomCrypto.seal(body, key: room.key, aad: aad(outer, room: room.id)))
        return outer
    }

    /// Opens a packet of `room`. Returns the inner message with the outer hop path and ttl, or
    /// nil when it belongs to another room, was tampered with, or does not match its header.
    public static func open(_ outer: MeshMessage, in room: Room) -> MeshMessage? {
        guard outer.kind == .sealed, outer.room == room.id,
              let sealed = outer.sealed.flatMap(RoomCrypto.fromBase64url),
              let plain = try? RoomCrypto.open(sealed, key: room.key, aad: aad(outer, room: room.id)),
              var inner = try? MeshCodec.decode(plain),
              inner.id == outer.id, inner.origin == outer.origin, inner.destination == outer.destination else { return nil }
        inner.hops = outer.hops
        inner.ttl = outer.ttl
        return inner
    }
}

/// Rooms this device has joined, which one is active, and on-disk layout:
/// <base>/rooms.json and <base>/rooms/<room id>/{org-memory.json | org-cache.json, timeline.json}.
public final class RoomStore {
    public struct Saved: Codable, Equatable {
        public var rooms: [Room]
        public var activeID: String
    }

    public let baseURL: URL?
    public private(set) var rooms: [Room]
    public private(set) var activeID: String

    public var active: Room { rooms.first { $0.id == activeID } ?? rooms[0] }

    /// Loads rooms.json, or migrates data from before rooms into the Default room.
    /// - legacyFiles: file names in `base` to move into the Default room's folder (copied, the
    ///   original kept as <name>.bak).
    /// - legacyAdmins / legacyClearedAt: global settings from before rooms, kept for Default.
    public init(baseURL: URL?, legacyFiles: [String] = [], legacyAdmins: [String] = [], legacyClearedAt: Date? = nil, now: Date = Date()) {
        self.baseURL = baseURL
        if let url = baseURL?.appendingPathComponent("rooms.json"), let data = try? Data(contentsOf: url),
           let saved = try? RoomStore.decoder().decode(Saved.self, from: data), !saved.rooms.isEmpty {
            rooms = saved.rooms
            activeID = saved.rooms.contains { $0.id == saved.activeID } ? saved.activeID : saved.rooms[0].id
            return
        }
        var room = Room.makeDefault(now: now)
        room.admins = legacyAdmins
        room.clearedAt = legacyClearedAt
        rooms = [room]
        activeID = room.id
        if let base = baseURL {
            let fm = FileManager.default
            let folder = RoomStore.folder(base: base, roomID: room.id)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in legacyFiles {
                let old = base.appendingPathComponent(name)
                let new = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
                if (try? fm.copyItem(at: old, to: new)) != nil {
                    try? fm.moveItem(at: old, to: base.appendingPathComponent(name + ".bak"))
                }
            }
        }
        save()
    }

    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public static func folder(base: URL, roomID: String) -> URL {
        base.appendingPathComponent("rooms", isDirectory: true).appendingPathComponent(roomID, isDirectory: true)
    }

    /// File for the active (or given) room, for example org-memory.json.
    public func fileURL(_ name: String, roomID: String? = nil) -> URL? {
        baseURL.map { RoomStore.folder(base: $0, roomID: roomID ?? activeID).appendingPathComponent(name) }
    }

    public func room(withID id: String) -> Room? { rooms.first { $0.id == id } }

    /// Adds (or refreshes) a room and makes it active. Joining the same key twice keeps one copy.
    @discardableResult
    public func join(_ room: Room) -> Room {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            activeID = rooms[index].id
        } else {
            rooms.append(room)
            activeID = room.id
        }
        save()
        return active
    }

    public func activate(_ id: String) {
        guard rooms.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
    }

    /// Leaves a room (not the last one). Its files stay on disk.
    public func leave(_ id: String) {
        guard rooms.count > 1, let index = rooms.firstIndex(where: { $0.id == id }) else { return }
        rooms.remove(at: index)
        if activeID == id { activeID = rooms[0].id }
        save()
    }

    public func update(_ id: String, _ change: (inout Room) -> Void) {
        guard let index = rooms.firstIndex(where: { $0.id == id }) else { return }
        change(&rooms[index])
        save()
    }

    public func save() {
        guard let base = baseURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? encoder.encode(Saved(rooms: rooms, activeID: activeID)).write(to: base.appendingPathComponent("rooms.json"), options: .atomic)
    }
}
