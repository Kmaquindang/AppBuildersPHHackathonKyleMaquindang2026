// Media.swift
// Pasa: photos and voice notes over the mesh. Pure Swift (Foundation + CryptoKit/swift-crypto),
// tested on Linux.
//
// - A media message (kind .media) carries a small manifest: media id, kind, type, size, SHA-256,
//   chunk count, and duration or pixel size. It shows in the timeline like a chat line.
// - The bytes travel as chunks (kind .chunk) of at most 12 KB. Each chunk is its own mesh message,
//   sealed with the room key like everything else, and relayed with the normal ttl and dedupe (each
//   chunk packet has its own message id). The chunk header repeats the media id, index, count and
//   the SHA-256 of the whole file.
// - The receiver puts chunks back together, checks the SHA-256, and saves the file in a capped
//   cache (LRU eviction: 200 MB on phones, 1 GB on the Mac).
// - Missing pieces: when a transfer stalls for a few seconds, or a link comes back, the receiver
//   broadcasts a NACK (kind .mediaNack) listing the missing chunk numbers. Any room member that
//   has those chunks (the sender, the Mac, or another phone) sends them again. This is also how
//   store and forward works for media: chunks are never parked in the outbox; whoever has the file
//   serves it when asked.
// - Transcripts (kind .transcript) are small text attachments for a voice note (replyTo = the
//   media message id), made on the Mac with Apple's on-device speech recognition.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum MediaKind: String, Codable, Sendable { case image, audio }

public enum MediaLimits {
    /// Raw bytes per chunk. About 22 KB per packet on the wire after sealing and encoding.
    public static let chunkSize = 12 * 1024
    /// Largest chunk a receiver accepts (a sender with another chunk size still interoperates).
    public static let maxChunkSize = 32 * 1024
    /// Largest media file accepted (photos target 200 KB, a 30 s voice note is about 90 KB).
    public static let maxBytes = 640 * 1024
    public static let maxChunks = 64
    public static let imageTargetBytes = 200_000
    public static let imageMaxEdge = 1024
    public static let audioMaxSeconds: Double = 30
    public static let phoneCacheBytes = 200 * 1024 * 1024
    public static let macCacheBytes = 1024 * 1024 * 1024
    /// Ask again for missing chunks after this long without progress.
    public static let nackAfter: TimeInterval = 6
    public static let maxNacks = 6
    /// At most this many unfinished transfers are kept in memory.
    public static let maxPending = 24
    /// An unfinished transfer is dropped after this long.
    public static let pendingLifetime: TimeInterval = 1800
    /// Pause between chunk packets when sending, so the link is not flooded.
    public static let paceSeconds: Double = 0.04
}

/// What a .media message carries in its body.
public struct MediaManifest: Codable, Equatable, Sendable {
    public var mediaId: UUID
    public var kind: MediaKind
    /// For example "image/jpeg" or "audio/mp4".
    public var mime: String
    public var byteCount: Int
    /// SHA-256 of the whole file, lowercase hex.
    public var sha256: String
    public var chunkCount: Int
    public var chunkSize: Int
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?

    public init(mediaId: UUID = UUID(), kind: MediaKind, mime: String, byteCount: Int, sha256: String, chunkCount: Int,
                chunkSize: Int, durationSeconds: Double? = nil, width: Int? = nil, height: Int? = nil) {
        self.mediaId = mediaId
        self.kind = kind
        self.mime = mime
        self.byteCount = byteCount
        self.sha256 = sha256
        self.chunkCount = chunkCount
        self.chunkSize = chunkSize
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
    }

    /// Sizes and counts agree and stay under the limits.
    public var isValid: Bool {
        guard byteCount >= 1, byteCount <= MediaLimits.maxBytes,
              chunkSize >= 1024, chunkSize <= MediaLimits.maxChunkSize,
              chunkCount >= 1, chunkCount <= MediaLimits.maxChunks,
              chunkCount == (byteCount + chunkSize - 1) / chunkSize,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { return false }
        if let d = durationSeconds, !(d >= 0 && d <= MediaLimits.audioMaxSeconds + 2) { return false }
        return true
    }

    public var fileExtension: String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/heic": return "heic"
        case "image/png": return "png"
        case "audio/mp4", "audio/m4a", "audio/aac": return "m4a"
        default: return "bin"
        }
    }

    /// "Photo" or "Voice note 0:12".
    public var displayLine: String {
        switch kind {
        case .image: return "Photo"
        case .audio: return "Voice note \(MediaManifest.clock(durationSeconds ?? 0))"
        }
    }

    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    public func encoded() -> String? { MeshPayload.encode(self) }

    public static func decode(_ body: String) -> MediaManifest? {
        guard let data = body.data(using: .utf8),
              let m = try? JSONDecoder().decode(MediaManifest.self, from: data), m.isValid else { return nil }
        return m
    }
}

/// One piece of a media file (body of a .chunk message).
public struct MediaChunk: Codable, Equatable, Sendable {
    public var mediaId: UUID
    public var index: Int
    public var count: Int
    /// SHA-256 of the whole file, so chunks can be checked and assembled even before the manifest.
    public var sha256: String
    public var data: Data

    public init(mediaId: UUID, index: Int, count: Int, sha256: String, data: Data) {
        self.mediaId = mediaId
        self.index = index
        self.count = count
        self.sha256 = sha256
        self.data = data
    }

    public func encoded() -> String? { MeshPayload.encode(self) }

    public static func decode(_ body: String) -> MediaChunk? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaChunk.self, from: data)
    }
}

/// "I am missing these chunks of this file" (body of a .mediaNack message).
public struct MediaNack: Codable, Equatable, Sendable {
    public var mediaId: UUID
    public var missing: [Int]

    public init(mediaId: UUID, missing: [Int]) {
        self.mediaId = mediaId
        self.missing = missing
    }

    public func encoded() -> String? { MeshPayload.encode(self) }

    public static func decode(_ body: String) -> MediaNack? {
        guard let data = body.data(using: .utf8),
              let nack = try? JSONDecoder().decode(MediaNack.self, from: data) else { return nil }
        let clean = Array(Set(nack.missing.filter { $0 >= 0 && $0 < MediaLimits.maxChunks })).sorted()
        return clean.isEmpty ? nil : MediaNack(mediaId: nack.mediaId, missing: clean)
    }
}

/// Body of a .transcript message: the text of a voice note, made on the Mac.
public struct TranscriptPayload: Codable, Equatable, Sendable {
    public var text: String
    /// Locale used, for example "en-US" or "fil-PH".
    public var locale: String
    /// Set instead of text when transcription was not possible (for example no on-device model).
    public var note: String?

    public init(text: String, locale: String, note: String? = nil) {
        self.text = text
        self.locale = locale
        self.note = note
    }

    public func encoded() -> String? { MeshPayload.encode(self) }

    public static func decode(_ body: String) -> TranscriptPayload? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TranscriptPayload.self, from: data)
    }

    /// Line shown under the voice note bubble.
    public var displayLine: String {
        if let note, text.isEmpty { return note }
        return text
    }
}

public enum MediaChunker {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func manifest(for data: Data, kind: MediaKind, mime: String, mediaId: UUID = UUID(),
                                durationSeconds: Double? = nil, width: Int? = nil, height: Int? = nil,
                                chunkSize: Int = MediaLimits.chunkSize) -> MediaManifest {
        MediaManifest(mediaId: mediaId, kind: kind, mime: mime, byteCount: data.count, sha256: sha256Hex(data),
                      chunkCount: max(1, (data.count + chunkSize - 1) / chunkSize), chunkSize: chunkSize,
                      durationSeconds: durationSeconds, width: width, height: height)
    }

    public static func chunk(of data: Data, manifest: MediaManifest, index: Int) -> MediaChunk? {
        guard index >= 0, index < manifest.chunkCount else { return nil }
        let start = index * manifest.chunkSize
        let end = min(data.count, start + manifest.chunkSize)
        guard start < end else { return nil }
        let slice = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
        return MediaChunk(mediaId: manifest.mediaId, index: index, count: manifest.chunkCount, sha256: manifest.sha256, data: slice)
    }

    public static func chunks(of data: Data, manifest: MediaManifest) -> [MediaChunk] {
        (0..<manifest.chunkCount).compactMap { chunk(of: data, manifest: manifest, index: $0) }
    }
}

/// Puts chunks back together. Chunks may arrive in any order, more than once, and before the
/// manifest. A finished file is returned only when its SHA-256 matches.
public final class MediaAssembler {
    public enum Outcome: Equatable {
        /// Duplicate, unknown or invalid chunk.
        case ignored
        /// Fraction of chunks received so far.
        case progress(Double)
        /// All chunks received and the SHA-256 matched.
        case complete(Data)
        /// All chunks received but the SHA-256 did not match: the parts were dropped (asked again).
        case corrupt
    }

    struct Pending {
        var manifest: MediaManifest?
        var count: Int
        var sha256: String
        var parts: [Int: Data] = [:]
        var firstSeen: Date
        var lastProgress: Date
        var nacks = 0
        var lastNack: Date?
    }

    private var pending: [UUID: Pending] = [:]

    public init() {}

    public var pendingIDs: [UUID] { Array(pending.keys) }

    public func isPending(_ id: UUID) -> Bool { pending[id] != nil }

    /// Registers a manifest so missing chunks can be asked for even if none arrived yet.
    public func expect(_ manifest: MediaManifest, now: Date = Date()) {
        guard manifest.isValid else { return }
        if var p = pending[manifest.mediaId] {
            guard p.count == manifest.chunkCount, p.sha256 == manifest.sha256 else {
                // Chunks that do not match the manifest were bogus: start over from the manifest.
                pending[manifest.mediaId] = Pending(manifest: manifest, count: manifest.chunkCount, sha256: manifest.sha256,
                                                    firstSeen: now, lastProgress: now)
                return
            }
            p.manifest = manifest
            pending[manifest.mediaId] = p
            return
        }
        makeRoom()
        pending[manifest.mediaId] = Pending(manifest: manifest, count: manifest.chunkCount, sha256: manifest.sha256,
                                            firstSeen: now, lastProgress: now)
    }

    public func add(_ chunk: MediaChunk, now: Date = Date()) -> Outcome {
        guard chunk.count >= 1, chunk.count <= MediaLimits.maxChunks, chunk.index >= 0, chunk.index < chunk.count,
              !chunk.data.isEmpty, chunk.data.count <= MediaLimits.maxChunkSize,
              chunk.sha256.count == 64 else { return .ignored }
        var p: Pending
        if let existing = pending[chunk.mediaId] {
            guard existing.count == chunk.count, existing.sha256 == chunk.sha256 else { return .ignored }
            p = existing
        } else {
            makeRoom()
            p = Pending(manifest: nil, count: chunk.count, sha256: chunk.sha256, firstSeen: now, lastProgress: now)
        }
        guard p.parts[chunk.index] == nil else { return .ignored }
        p.parts[chunk.index] = chunk.data
        p.lastProgress = now
        p.nacks = 0
        if p.parts.count < p.count {
            pending[chunk.mediaId] = p
            return .progress(Double(p.parts.count) / Double(p.count))
        }
        var whole = Data()
        for i in 0..<p.count { whole.append(p.parts[i]!) }
        let sizeOK = p.manifest.map { $0.byteCount == whole.count } ?? (whole.count <= MediaLimits.maxBytes)
        if sizeOK && MediaChunker.sha256Hex(whole) == p.sha256 {
            pending.removeValue(forKey: chunk.mediaId)
            return .complete(whole)
        }
        p.parts.removeAll()
        pending[chunk.mediaId] = p
        return .corrupt
    }

    public func progress(_ id: UUID) -> Double? {
        guard let p = pending[id] else { return nil }
        return Double(p.parts.count) / Double(p.count)
    }

    public func manifest(_ id: UUID) -> MediaManifest? { pending[id]?.manifest }

    public func missing(_ id: UUID) -> [Int] {
        guard let p = pending[id] else { return [] }
        return (0..<p.count).filter { p.parts[$0] == nil }
    }

    /// A chunk this device holds for an unfinished transfer (to answer someone else's NACK).
    public func part(_ id: UUID, index: Int) -> MediaChunk? {
        guard let p = pending[id], let data = p.parts[index] else { return nil }
        return MediaChunk(mediaId: id, index: index, count: p.count, sha256: p.sha256, data: data)
    }

    /// Transfers that stalled: no progress (and no NACK) for `after` seconds, fewer than `maxNacks`
    /// tries. Marks them as asked. `force` asks for every unfinished transfer (a link just came up).
    public func dueForNack(now: Date = Date(), after: TimeInterval = MediaLimits.nackAfter, force: Bool = false) -> [MediaNack] {
        var out: [MediaNack] = []
        for (id, var p) in pending {
            let quietSince = max(p.lastProgress, p.lastNack ?? .distantPast)
            guard force || (now.timeIntervalSince(quietSince) >= after && p.nacks < MediaLimits.maxNacks) else { continue }
            let missing = (0..<p.count).filter { p.parts[$0] == nil }
            guard !missing.isEmpty else { continue }
            p.nacks += 1
            p.lastNack = now
            pending[id] = p
            out.append(MediaNack(mediaId: id, missing: missing))
        }
        return out.sorted { $0.mediaId.uuidString < $1.mediaId.uuidString }
    }

    public func cancel(_ id: UUID) { pending.removeValue(forKey: id) }

    /// Drops transfers older than the lifetime.
    public func prune(now: Date = Date(), lifetime: TimeInterval = MediaLimits.pendingLifetime) {
        pending = pending.filter { now.timeIntervalSince($0.value.lastProgress) < lifetime }
    }

    private func makeRoom() {
        while pending.count >= MediaLimits.maxPending,
              let oldest = pending.min(by: { $0.value.lastProgress < $1.value.lastProgress })?.key {
            pending.removeValue(forKey: oldest)
        }
    }
}

/// Finished media files on disk, with a size cap and least-recently-used eviction.
/// Layout: <directory>/<media id>.<ext> plus <directory>/index.json. With a nil directory it keeps
/// files in memory (tests).
public final class MediaStore {
    public struct Item: Codable, Equatable, Sendable {
        public var bytes: Int
        public var lastAccess: Date
        public var ext: String
    }

    public let directory: URL?
    public let capBytes: Int
    public private(set) var items: [UUID: Item] = [:]
    private var memory: [UUID: Data] = [:]

    public init(directory: URL?, capBytes: Int) {
        self.directory = directory
        self.capBytes = capBytes
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
               let saved = try? MediaStore.decoder().decode([String: Item].self, from: data) {
                for (key, item) in saved {
                    guard let id = UUID(uuidString: key) else { continue }
                    let url = directory.appendingPathComponent("\(key).\(item.ext)")
                    if FileManager.default.fileExists(atPath: url.path) { items[id] = item }
                }
            }
        }
    }

    public var totalBytes: Int { items.values.reduce(0) { $0 + $1.bytes } }

    public func has(_ id: UUID) -> Bool { items[id] != nil }

    /// File URL of a stored item (nil in memory mode or when missing).
    public func url(_ id: UUID) -> URL? {
        guard let directory, let item = items[id] else { return nil }
        return directory.appendingPathComponent("\(id.uuidString).\(item.ext)")
    }

    /// Reads a file and marks it as recently used.
    public func data(_ id: UUID, now: Date = Date()) -> Data? {
        guard items[id] != nil else { return nil }
        let data: Data?
        if directory == nil { data = memory[id] } else { data = url(id).flatMap { try? Data(contentsOf: $0) } }
        guard let data else {
            items.removeValue(forKey: id)
            saveIndex()
            return nil
        }
        items[id]?.lastAccess = now
        saveIndex()
        return data
    }

    /// Saves a file, evicting the least recently used others until it fits. False when the file
    /// alone is larger than the cap or cannot be written.
    @discardableResult
    public func put(_ id: UUID, data: Data, ext: String, now: Date = Date()) -> Bool {
        guard data.count <= capBytes else { return false }
        if let directory {
            let url = directory.appendingPathComponent("\(id.uuidString).\(ext)")
            do { try data.write(to: url, options: .atomic) } catch { return false }
        } else {
            memory[id] = data
        }
        items[id] = Item(bytes: data.count, lastAccess: now, ext: ext)
        evict(keeping: id)
        saveIndex()
        return true
    }

    public func remove(_ id: UUID) {
        if let url = url(id) { try? FileManager.default.removeItem(at: url) }
        memory.removeValue(forKey: id)
        items.removeValue(forKey: id)
        saveIndex()
    }

    private func evict(keeping keep: UUID) {
        while totalBytes > capBytes,
              let victim = items.filter({ $0.key != keep }).min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            if let url = url(victim) { try? FileManager.default.removeItem(at: url) }
            memory.removeValue(forKey: victim)
            items.removeValue(forKey: victim)
        }
    }

    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }

    private func saveIndex() {
        guard let directory else { return }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.key.uuidString, $0.value) })
        try? e.encode(map).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}
