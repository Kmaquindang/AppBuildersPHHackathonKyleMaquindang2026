// AnswerStream.swift
// Libre: streamed @libre answers (issue #2, Oct 2026). Our own design.
//
// Wire: while the model writes, the AI Mac sends `.answerPart` messages inside sealed room packets:
// replyTo = the ask's id (askKey), part = 0, 1, 2..., body = the text added since the previous
// part. It always sends the normal whole `.answer` at the end, and that replaces the partial text.
// Builds from before this kind cannot decode the inner message and drop it unread (relays still
// forward the sealed packet), so they keep seeing only the final answer, as before.
//
// AnswerStreamer (AI Mac) turns raw model text into parts. It hides <think> blocks and [...]
// citation tags (the final answer shows those as chips), sends at most one part per `interval`
// and only once `minChars` new characters are ready, and stops after `maxParts` parts or
// `maxChars` characters (the final answer's first packet is 300 characters; see Compactor). The
// last few words are never streamed: the final answer brings them.
// AnswerStreams (phones) keeps parts per ask, shows only the in-order prefix (a missing part hides
// everything after it), forgets an ask when its final answer arrives (late parts are ignored),
// and drops a stream that saw no final answer within `timeout`.

import Foundation

public struct AnswerStreamer: Sendable {
    public struct Part: Equatable, Sendable {
        public var seq: Int
        public var text: String
    }

    public static let minChars = 40
    public static let interval: TimeInterval = 0.6
    public static let maxParts = 8
    public static let maxChars = Compactor.firstPacketLimit - Compactor.moreHint.count

    private var raw = ""
    private var sent = ""
    private var nextSeq = 0
    private var lastSent: Date?
    private var stopped = false

    public init() {}

    /// Adds model output. Returns the next part when one is due.
    public mutating func add(_ delta: String, now: Date = Date()) -> Part? {
        raw += delta
        guard !stopped, nextSeq < AnswerStreamer.maxParts else { return nil }
        let shown = String(AnswerStreamer.visible(raw).prefix(AnswerStreamer.maxChars))
        // Visible text only ever grows at the end. If it did not (an odd tag), stop streaming;
        // the final answer replaces whatever was shown.
        guard shown.hasPrefix(sent) else { stopped = true; return nil }
        let fresh = String(shown.dropFirst(sent.count))
        guard fresh.count >= AnswerStreamer.minChars else { return nil }
        if let lastSent, now.timeIntervalSince(lastSent) < AnswerStreamer.interval { return nil }
        let part = Part(seq: nextSeq, text: fresh)
        sent = shown
        nextSeq += 1
        lastSent = now
        return part
    }

    /// Text a reader may see: complete <think> blocks and [...] tags removed, nothing from an
    /// unclosed "<" or "[" on, and no leading or trailing white space (so a tag that closes later
    /// never changes text already sent).
    public static func visible(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        if let open = text.range(of: "<think>") { text = String(text[..<open.lowerBound]) }
        text = text.replacingOccurrences(of: "[ \\t]*\\[[^\\]\\n]*\\]", with: "", options: .regularExpression)
        if let i = text.lastIndex(of: "["), !text[i...].contains("]") { text = String(text[..<i]) }
        if let i = text.lastIndex(of: "<"), !text[i...].contains(">") { text = String(text[..<i]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AnswerStreams: Sendable {
    public static let timeout: TimeInterval = 120
    public static let maxParts = 16
    public static let maxChars = 2000

    private struct Stream: Sendable {
        var room: String
        var parts: [Int: String] = [:]
        var chars = 0
        var updated: Date
    }

    private var streams: [UUID: Stream] = [:]
    private var finished: [UUID: Date] = [:]

    public init() {}

    /// Adds one part. Returns true when the text shown for that ask changed.
    @discardableResult
    public mutating func add(askID: UUID, seq: Int, text: String, room: String, now: Date = Date()) -> Bool {
        guard finished[askID] == nil, seq >= 0, seq < AnswerStreams.maxParts, !text.isEmpty else { return false }
        var stream = streams[askID] ?? Stream(room: room, updated: now)
        guard stream.room == room, stream.parts[seq] == nil, stream.chars + text.count <= AnswerStreams.maxChars else { return false }
        let before = AnswerStreams.prefix(stream.parts)
        stream.parts[seq] = text
        stream.chars += text.count
        stream.updated = now
        streams[askID] = stream
        return AnswerStreams.prefix(stream.parts) != before
    }

    /// In-order text for an ask (parts 0, 1, 2... up to the first gap), nil when nothing shows yet.
    public func text(for askID: UUID) -> String? {
        guard let stream = streams[askID] else { return nil }
        let shown = AnswerStreams.prefix(stream.parts)
        return shown.isEmpty ? nil : shown
    }

    /// Asks in `room` with text to show, oldest first.
    public func open(in room: String) -> [UUID] {
        streams.filter { $0.value.room == room && text(for: $0.key) != nil }
            .sorted { $0.value.updated < $1.value.updated }.map(\.key)
    }

    /// The final answer arrived: drop the partial text and ignore late parts.
    public mutating func finish(_ askID: UUID, now: Date = Date()) {
        streams.removeValue(forKey: askID)
        finished[askID] = now
    }

    /// Drops streams with no part for `timeout` (no final answer came). Returns the asks dropped.
    @discardableResult
    public mutating func expire(now: Date = Date()) -> [UUID] {
        let old = streams.filter { now.timeIntervalSince($0.value.updated) >= AnswerStreams.timeout }.map(\.key)
        for id in old { streams.removeValue(forKey: id) }
        finished = finished.filter { now.timeIntervalSince($0.value) < AnswerStreams.timeout * 5 }
        return old
    }

    public mutating func removeAll() { streams.removeAll() }

    private static func prefix(_ parts: [Int: String]) -> String {
        var out = ""
        var i = 0
        // Parts are exact deltas (spaces included), so they join as is.
        while let piece = parts[i] {
            out += piece
            i += 1
        }
        return out
    }
}

/// One streamed answer shown on a phone: the ask it answers and the text so far.
public struct PartialAnswer: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public init(id: UUID, text: String) { self.id = id; self.text = text }
}

/// AnswerStreamer behind a lock: the model's text arrives off the main thread.
public final class AnswerPartPacer: @unchecked Sendable {
    private let lock = NSLock()
    private var streamer = AnswerStreamer()

    public init() {}

    public func add(_ delta: String, now: Date = Date()) -> AnswerStreamer.Part? {
        lock.lock(); defer { lock.unlock() }
        return streamer.add(delta, now: now)
    }
}
