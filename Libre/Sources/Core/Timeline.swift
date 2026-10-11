// Timeline.swift
// Pasa: persistent chat timeline, persistent outbox, and Mac backfill. Pure Swift, tested on Linux.
//
// - Every device saves its timeline (and its outbox) as JSON in Application Support and reloads
//   it on launch. Entries are deduplicated by message id. Phones keep the newest 500; the Mac keeps
//   a much longer history because it is the team's source of truth.
// - When a phone links, it sends the AI Mac a sync request (newest message time it has plus its
//   recent message ids). The Mac answers with the messages that phone missed, at most 200 per
//   sync, split into small chunks so each mesh packet stays small.

import Foundation

/// One row in the timeline.
public struct ChatEntry: Identifiable, Equatable, Codable, Sendable {
    public enum Direction: String, Codable, Sendable { case sent, received }

    public let id: UUID
    public var message: MeshMessage
    public var direction: Direction
    public var receivedAt: Date
    /// For sent messages: who the first copy was handed to, or empty if it was queued.
    public var sentTo: [String]
    /// For answers to our own asks: local send-to-answer time, measured on one clock.
    public var roundTripMs: Int?
    /// True when the Mac filled this message in after the device missed it.
    public var backfilled: Bool?
    /// Voice notes: the transcript made on the Mac (or a note why there is none).
    public var transcript: String?
    /// Which radio carried it: "Wi-Fi", "Bluetooth" or "Wi-Fi and Bluetooth" (nil: older entry or local).
    public var link: String?

    public init(id: UUID, message: MeshMessage, direction: Direction, receivedAt: Date,
                sentTo: [String] = [], roundTripMs: Int? = nil, backfilled: Bool? = nil) {
        self.id = id
        self.message = message
        self.direction = direction
        self.receivedAt = receivedAt
        self.sentTo = sentTo
        self.roundTripMs = roundTripMs
        self.backfilled = backfilled
    }

    /// One-way latency from the origin's clock to ours. Only as good as device clock sync.
    public var oneWayMs: Int {
        Int((receivedAt.timeIntervalSince(message.createdAt) * 1000).rounded())
    }
}

/// What is saved on disk: the timeline plus anything still waiting in the outbox.
public struct PersistedTimeline: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var entries: [ChatEntry]
    public var outbox: [OutboxItem]
    /// Phones: asks with no answer yet, resent when the AI Mac wakes (see PendingAskBook).
    public var pendingAsks: [PendingAsk]?

    public init(entries: [ChatEntry] = [], outbox: [OutboxItem] = []) {
        self.entries = entries
        self.outbox = outbox
    }
}

public enum TimelineStore {
    public static let phoneLimit = 500
    public static let macLimit = 20_000

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// Drops repeated message ids (first copy wins) and keeps the newest `limit` entries.
    public static func dedupedAndCapped(_ entries: [ChatEntry], limit: Int) -> [ChatEntry] {
        var seen = Set<UUID>()
        var unique: [ChatEntry] = []
        unique.reserveCapacity(entries.count)
        for entry in entries where seen.insert(entry.id).inserted {
            unique.append(entry)
        }
        if unique.count > limit { unique.removeFirst(unique.count - limit) }
        return unique
    }

    public static func encode(_ timeline: PersistedTimeline, limit: Int) throws -> Data {
        var copy = timeline
        copy.entries = dedupedAndCapped(timeline.entries, limit: limit)
        return try encoder().encode(copy)
    }

    public static func decode(_ data: Data, limit: Int) throws -> PersistedTimeline {
        var loaded = try decoder().decode(PersistedTimeline.self, from: data)
        loaded.entries = dedupedAndCapped(loaded.entries, limit: limit)
        return loaded
    }

    @discardableResult
    public static func save(_ timeline: PersistedTimeline, to url: URL, limit: Int) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(timeline, limit: limit).write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Empty timeline when the file is missing or unreadable (never crashes on launch).
    public static func load(from url: URL, limit: Int) -> PersistedTimeline {
        guard let data = try? Data(contentsOf: url), let loaded = try? decode(data, limit: limit) else {
            return PersistedTimeline()
        }
        return loaded
    }

    /// Inserts entries whose id is new, keeping the timeline in createdAt order around them.
    /// Returns the merged list and how many entries were actually added.
    public static func mergeBackfill(_ existing: [ChatEntry], _ incoming: [ChatEntry]) -> (entries: [ChatEntry], added: Int) {
        var known = Set(existing.map { $0.id })
        var result = existing
        var added = 0
        for entry in incoming.sorted(by: { $0.message.createdAt < $1.message.createdAt }) where known.insert(entry.id).inserted {
            let at = result.lastIndex(where: { $0.message.createdAt <= entry.message.createdAt }).map { $0 + 1 } ?? 0
            result.insert(entry, at: at)
            added += 1
        }
        return (result, added)
    }

    /// Drops entries created before a "clear timeline" watermark.
    public static func dropping(_ entries: [ChatEntry], before watermark: Date?) -> [ChatEntry] {
        guard let watermark else { return entries }
        return entries.filter { $0.message.createdAt >= watermark }
    }
}

// MARK: - Backfill over the mesh

public struct SyncRequest: Codable, Equatable, Sendable {
    /// Newest createdAt the phone already has, nil for an empty timeline.
    public var newest: Date?
    /// Ids of the phone's most recent messages, so the Mac does not resend them.
    public var knownIDs: [UUID]
    /// The phone cleared its timeline at this time: never send anything older.
    public var clearedAt: Date?

    public init(newest: Date?, knownIDs: [UUID], clearedAt: Date? = nil) {
        self.newest = newest
        self.knownIDs = knownIDs
        self.clearedAt = clearedAt
    }
}

public struct SyncBatch: Codable, Equatable, Sendable {
    public var messages: [MeshMessage]
    public var part: Int
    public var parts: Int

    public init(messages: [MeshMessage], part: Int, parts: Int) {
        self.messages = messages
        self.part = part
        self.parts = parts
    }
}

/// Body of a `.sync` mesh message: one of request, batch or manifest.
public struct SyncPayload: Codable, Equatable, Sendable {
    public var request: SyncRequest?
    public var batch: SyncBatch?
    /// Mac to phone on link: what the Mac holds, so stale cached rules and tasks are dropped.
    public var manifest: MemoryManifest?

    public init(request: SyncRequest? = nil, batch: SyncBatch? = nil, manifest: MemoryManifest? = nil) {
        self.request = request
        self.batch = batch
        self.manifest = manifest
    }

    public func encoded() -> String? { MeshPayload.encode(self) }

    public static func decode(_ body: String) -> SyncPayload? {
        guard let data = body.data(using: .utf8) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return try? d.decode(SyncPayload.self, from: data)
    }
}

public enum Backfill {
    public static let maxPerSync = 200
    public static let knownIDsInRequest = 150
    /// Look back a little before the phone's newest message, to cover clock differences.
    public static let slack: TimeInterval = 600
    /// Target size of one sync packet (JSON bytes of the messages it carries).
    public static let maxChunkBytes = 12_000
    /// Kinds that belong in a timeline backfill. Asks are private to the asker and the AI.
    public static let kinds: Set<MessageKind> = [.chat, .answer, .rule, .task, .media, .transcript]

    public static func request(from entries: [ChatEntry], clearedAt: Date? = nil) -> SyncRequest {
        let relevant = entries.filter { kinds.contains($0.message.kind) || $0.message.kind == .ask }
        let newest = relevant.map { $0.message.createdAt }.max()
        let ids = relevant.suffix(knownIDsInRequest).map { $0.id }
        return SyncRequest(newest: newest, knownIDs: ids, clearedAt: clearedAt)
    }

    /// Messages from the Mac's timeline that `device` should have but did not list as known.
    /// Broadcasts and messages addressed to that device only, oldest first, newest `cap` kept.
    /// Nothing older than the phone's or the Mac's clear-timeline watermark is sent.
    public static func select(from entries: [ChatEntry], for device: String, request: SyncRequest,
                              macClearedAt: Date? = nil, cap: Int = maxPerSync) -> [MeshMessage] {
        let known = Set(request.knownIDs)
        let since = request.newest.map { $0.addingTimeInterval(-slack) }
        let floor = CacheSync.latest(request.clearedAt, macClearedAt)
        var seen = Set<UUID>()
        var picked: [MeshMessage] = []
        for entry in entries {
            let m = entry.message
            guard kinds.contains(m.kind), !known.contains(m.id), seen.insert(m.id).inserted else { continue }
            switch m.destination {
            case .none: break
            case .some(.peer(let name)) where name == device: break
            default: continue
            }
            if let since, m.createdAt < since { continue }
            if let floor, m.createdAt < floor { continue }
            if m.silent == true { continue }
            picked.append(m)
        }
        picked.sort { $0.createdAt < $1.createdAt }
        if picked.count > cap { picked.removeFirst(picked.count - cap) }
        return picked
    }

    /// Splits messages into chunks whose encoded size stays under `maxBytes` (a single oversize
    /// message still gets its own chunk).
    public static func chunk(_ messages: [MeshMessage], maxBytes: Int = maxChunkBytes) -> [[MeshMessage]] {
        var chunks: [[MeshMessage]] = []
        var current: [MeshMessage] = []
        var size = 0
        for m in messages {
            let bytes = (try? MeshCodec.encode(m).count) ?? 512
            if !current.isEmpty && size + bytes > maxBytes {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(m)
            size += bytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
