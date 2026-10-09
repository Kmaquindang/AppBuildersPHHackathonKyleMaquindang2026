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
        senderName: String? = nil
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
    }

    /// Number of device-to-device hops travelled so far.
    public var hopCount: Int { max(0, hops.count - 1) }

    /// Human readable path, for example "iPhone 12 -> iPhone 14 Pro Max -> MacBook Air".
    public var pathDescription: String { hops.joined(separator: " -> ") }

    /// True when the message is a broadcast (no destination).
    public var isBroadcast: Bool { destination == nil }
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
}
