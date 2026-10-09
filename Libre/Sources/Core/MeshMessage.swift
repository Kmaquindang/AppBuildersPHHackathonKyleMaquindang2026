// MeshMessage.swift
// Pasa: offline device-to-device mesh team chat.
// Pure Swift (Foundation only). Compiles on Apple platforms and on Linux for tests.

import Foundation

/// What a mesh message is for.
public enum MessageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case chat     // human chat line
    case ask      // question for the AI peer
    case answer   // AI peer reply to an ask
    case ack      // delivery receipt (reserved for later milestones)
    case rule     // team knowledge base entry (milestone 3)
    case task     // to-do item (milestone 3)
    case sync     // timeline backfill: phone asks the AI Mac for missed messages, Mac replies in chunks
    case sealed   // protocol v2: a room packet; the real kind and body are inside `sealed`
    // Media (inside sealed room packets only; a build without these kinds drops them unread):
    case media      // photo or voice note: body is a MediaManifest, shown in the timeline
    case chunk      // one piece of a media file (MediaChunk); never shown
    case mediaNack  // "send me these chunks again" (MediaNack); never shown
    case transcript // text of a voice note (TranscriptPayload), replyTo = the media message id
    // Multi-room (Oct 9 night):
    case roomControl // signed manifest, join request or "send me the manifest" (sealed with the base key)
    case beacon      // CLEAR: signed "this room exists" for the Nearby rooms list (no key, no passcode)
    case aiStatus    // CLEAR: signed AI Mac status (awake or asleep, model, queue depth, rooms served)
}

/// Who a message is addressed to. A nil destination on MeshMessage means broadcast.
public enum MeshDestination: Codable, Hashable, Sendable {
    /// A single device, by its mesh display name.
    case peer(String)
    /// Any device that holds this role, for example "ai".
    case role(String)

    public static let aiRole = "ai"

    public var label: String {
        switch self {
        case .peer(let name): return name
        case .role(let role): return "@" + role
        }
    }
}

/// The unit that travels over the mesh. Encoded as JSON for milestone 1.
public struct MeshMessage: Codable, Hashable, Identifiable, Sendable {
    public static let defaultTTL = 7
    /// Wire format version this build reads and writes. Messages without `v` are version 1
    /// (builds before Oct 9, 2026 evening). A device that meets a newer version relays the raw
    /// bytes untouched (see MeshCodec.decodeLenient) instead of dropping them.
    public static let protocolVersion = 2   // 2 = rooms: sealed payload plus clear room tag

    public var id: UUID
    /// Display name of the device that created the message.
    public var origin: String
    /// nil means broadcast to everyone in the mesh.
    public var destination: MeshDestination?
    public var kind: MessageKind
    public var body: String
    /// Remaining hop budget. Each relay forwards with ttl - 1. Not forwarded when ttl <= 1.
    public var ttl: Int
    /// Path so far. Starts as [origin]; each receiving device appends itself.
    public var hops: [String]
    public var createdAt: Date
    /// For answers and acks: the id of the message being answered.
    public var replyTo: UUID?
    /// For answers: the hop path the original ask took to reach the answering device.
    public var replyPath: [String]?
    /// For answers: true when the body is a shortened first packet ("@pasa more" gets the rest).
    public var compact: Bool?
    /// For answers: local model that produced the reply, for example "qwen3:8b".
    public var model: String?
    /// For answers: time the AI peer spent producing the reply, in milliseconds.
    public var latencyMs: Int?
    /// For answers: generation speed reported by Ollama (eval_count / eval_duration).
    public var tokensPerSecond: Double?
    /// Display name the sender chose ("Kyle", "Ana"). The UI shows it instead of the device id.
    public var senderName: String?
    /// Wire format version (nil means 1, from builds before the field existed).
    public var v: Int?
    /// Rule and task updates sent by the Mac when a device links: update the cache only, never
    /// add a card to the timeline.
    public var silent: Bool?
    /// For asks: the asker was away (app in the background or no links) since this time, so
    /// "what did I miss" can summarize only what came after it.
    public var since: Date?
    /// For answers: titles of the rules and notes the AI checked for this answer.
    public var checked: [String]?
    /// Protocol v2: room tag (hex, derived from the room key). Clear, for relays.
    public var room: String?
    /// Protocol v2: ChaCha20-Poly1305 box (base64url) holding the real message.
    public var sealed: String?
    /// Room key epoch the packet is sealed with (nil means 0, the base key). Clear, bound to the box.
    public var epoch: Int?
    /// For asks resent after the AI Mac woke up: id of the original ask. The Mac answers each
    /// original id once and re-delivers the stored answer for repeats.
    public var retryOf: UUID?

    public init(
        id: UUID = UUID(),
        origin: String,
        destination: MeshDestination? = nil,
        kind: MessageKind,
        body: String,
        ttl: Int = MeshMessage.defaultTTL,
        hops: [String]? = nil,
        createdAt: Date = Date(),
        replyTo: UUID? = nil,
        replyPath: [String]? = nil,
        compact: Bool? = nil,
        model: String? = nil,
        latencyMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        senderName: String? = nil,
        v: Int? = nil,
        silent: Bool? = nil,
        since: Date? = nil
    ) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.kind = kind
        self.body = body
        self.ttl = ttl
        self.hops = hops ?? [origin]
        self.createdAt = createdAt
        self.replyTo = replyTo
        self.replyPath = replyPath
        self.compact = compact
        self.model = model
        self.latencyMs = latencyMs
        self.tokensPerSecond = tokensPerSecond
        self.senderName = senderName
        self.v = v
        self.silent = silent
        self.since = since
    }

    /// Version this message was written with (1 when the field is missing).
    public var wireVersion: Int { v ?? 1 }

    /// Number of device-to-device hops travelled so far.
    public var hopCount: Int { max(0, hops.count - 1) }

    /// Human readable path, for example "iPhone 12 -> iPhone 14 Pro Max -> MacBook Air".
    public var pathDescription: String { hops.joined(separator: " -> ") }

    /// Id the AI Mac dedupes asks by.
    public var askKey: UUID { retryOf ?? id }

    /// True when the message is a broadcast (no destination).
    public var isBroadcast: Bool { destination == nil }
}

/// What a received packet turned out to be.
public enum DecodedPacket {
    /// A message this build understands.
    case message(MeshMessage)
    /// A packet from a newer (or unknown) format: routing fields are readable, the rest is not.
    /// Relay it untouched; never show or act on it.
    case opaque(OpaquePacket)
    /// Not a Pasa packet at all.
    case unreadable
}

/// A packet this build cannot fully read. Keeps the raw JSON so every unknown field survives
/// the relay, and only rewrites the two fields relays must change (ttl and hops).
public struct OpaquePacket {
    /// Routing fields only (id, origin, destination, ttl, hops). Kind and body are placeholders.
    public var envelope: MeshMessage
    public var version: Int
    public var kindName: String?
    private var raw: [String: Any]

    init(envelope: MeshMessage, version: Int, kindName: String?, raw: [String: Any]) {
        self.envelope = envelope
        self.version = version
        self.kindName = kindName
        self.raw = raw
    }

    /// Raw bytes with only ttl and hops replaced, ready to forward.
    public func rewritten(ttl: Int, hops: [String]) -> Data? {
        var copy = raw
        copy["ttl"] = ttl
        copy["hops"] = hops
        return try? JSONSerialization.data(withJSONObject: copy, options: [])
    }
}

/// JSON wire format. Kept in one place so a compact binary format can replace it later.
public enum MeshCodec {
    public static func encode(_ message: MeshMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(message)
    }

    public static func decode(_ data: Data) throws -> MeshMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(MeshMessage.self, from: data)
    }

    /// Routing fields every version must keep readable so older devices can still relay.
    private struct Envelope: Decodable {
        var id: UUID
        var origin: String
        var destination: MeshDestination?
        var ttl: Int
        var hops: [String]
        var v: Int?
        var kind: String?
    }

    /// Full decode when this build understands the packet; otherwise the routing envelope plus
    /// the raw JSON so the packet can be relayed untouched (newer version or unknown kind).
    public static func decodeLenient(_ data: Data) -> DecodedPacket {
        if let message = try? decode(data), message.wireVersion <= MeshMessage.protocolVersion {
            return .message(message)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable
        }
        let stub = MeshMessage(id: envelope.id, origin: envelope.origin, destination: envelope.destination,
                               kind: .ack, body: "", ttl: envelope.ttl, hops: envelope.hops,
                               createdAt: Date(timeIntervalSince1970: 0), v: envelope.v)
        return .opaque(OpaquePacket(envelope: stub, version: envelope.v ?? 1, kindName: envelope.kind, raw: raw))
    }
}
