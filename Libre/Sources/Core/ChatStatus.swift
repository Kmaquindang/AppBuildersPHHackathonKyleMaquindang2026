// ChatStatus.swift
// Pasa: plain-word status for the chat screen (pure, tested on Linux).
// - Duplicate asks: the same @pasa question, still unanswered in the same room, is not queued twice.
// - Bubble delivery state as an icon plus a VoiceOver label, instead of repeated caption text.
// - One offline banner and one header status line in plain words.

import Foundation

public enum AskCoalescer {
    /// "What did I miss?" and "what did i miss" are the same ask.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return lowered.trimmingCharacters(in: CharacterSet(charactersIn: "?!.。 "))
    }

    /// Ask ids that already have an answer in this timeline.
    public static func answered(_ entries: [ChatEntry]) -> Set<UUID> {
        Set(entries.compactMap { $0.message.kind == .answer ? $0.message.replyTo : nil })
    }

    /// The pending ask (sent by `device`, no answer yet, younger than `window`) with the same text, if any.
    public static func pendingDuplicate(of question: String, from device: String, in entries: [ChatEntry],
                                        now: Date = Date(), window: TimeInterval = 24 * 3600) -> ChatEntry? {
        let key = normalize(question)
        guard !key.isEmpty else { return nil }
        let done = answered(entries)
        return entries.last { e in
            e.message.kind == .ask && e.direction == .sent && e.message.origin == device
                && !done.contains(e.message.askKey) && !done.contains(e.id)
                && now.timeIntervalSince(e.message.createdAt) < window
                && normalize(e.message.body) == key
        }
    }
}

extension AskCoalescer {
    /// How long an answered question counts as "Answered above" (round 2, Kyle's 8:55 PM screenshot:
    /// the same Christmas tree question was sent and answered twice).
    public static let answeredWindow: TimeInterval = 10 * 60

    /// The newest answer (younger than `window`) to an ask in this room's timeline with the same
    /// text, from anyone. Returns the ask and its answer so the UI can scroll to the answer.
    public static func recentAnswer(of question: String, in entries: [ChatEntry], now: Date = Date(),
                                    window: TimeInterval = answeredWindow) -> (ask: ChatEntry, answer: ChatEntry)? {
        let key = normalize(question)
        guard !key.isEmpty else { return nil }
        for answer in entries.reversed() where answer.message.kind == .answer {
            let age = now.timeIntervalSince(answer.message.createdAt)
            guard age < window, age > -window, let reply = answer.message.replyTo else { continue }
            if let ask = entries.last(where: { $0.message.kind == .ask && ($0.message.askKey == reply || $0.id == reply) }),
               normalize(ask.message.body) == key {
                return (ask, answer)
            }
        }
        return nil
    }
}

/// Composer hint after a repeat question: "Answered above" (scrolls to it) or "Ask again".
public struct AnsweredHint: Equatable, Sendable {
    public var question: String
    public var answerID: UUID
    public init(question: String, answerID: UUID) {
        self.question = question
        self.answerID = answerID
    }
}

/// A request for the timeline to scroll to a row. `token` makes repeated taps on the same row work.
public struct ScrollRequest: Equatable, Sendable {
    public var id: UUID
    public var token = UUID()
    public init(id: UUID) { self.id = id }
}

/// Typing "@" in the composer: an inline list of ready asks (round 2).
public enum MentionSuggest {
    public static let items = ["@pasa", "@pasa my tasks", "@pasa what did I miss?", "@pasa summary"]

    /// The "@..." word being typed at the end of the text, when it can still become "@pasa"
    /// (including "@pasa" itself, before a space).
    public static func partial(in text: String) -> String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last else { return nil }
        let word = String(last).lowercased()
        guard word.hasPrefix("@"), "@pasa".hasPrefix(word) else { return nil }
        return String(last)
    }

    /// Suggestions for the current text: only while an "@" word is being typed at the very start
    /// of the message (asks must start with @pasa). Mid-sentence it offers just "@pasa".
    public static func suggestions(for text: String) -> [String] {
        guard let partial = partial(in: text) else { return [] }
        let before = text.dropLast(partial.count).trimmingCharacters(in: .whitespaces)
        return before.isEmpty ? items : ["@pasa"]
    }

    /// The new composer text after picking `item`. "@pasa" alone leaves a space to keep typing.
    public static func apply(_ item: String, to text: String) -> String {
        guard let partial = partial(in: text) else { return text }
        let head = String(text.dropLast(partial.count))
        return item == "@pasa" ? head + "@pasa " : head + item
    }
}

/// Starter chips: shown only in an empty timeline or right after onboarding (round 2).
public enum StarterChipPolicy {
    public static let asks: [(title: String, ask: String)] = [
        ("What did I miss?", "what did I miss?"),
        ("My tasks", "my tasks"),
        ("Summary", "summary"),
        ("Our rules", "what are our rules?"),
    ]

    public static func visible(entriesEmpty: Bool, afterOnboarding: Bool, canSend: Bool, typing: Bool) -> Bool {
        canSend && !typing && (entriesEmpty || afterOnboarding)
    }
}

public enum BubbleStatus: Equatable, Sendable {
    case queued, sent, waiting, answered, received, synced

    public var symbol: String {
        switch self {
        case .queued: return "clock"
        case .sent: return "checkmark"
        case .waiting: return "hourglass"
        case .answered: return "checkmark.bubble"
        case .received: return ""
        case .synced: return "arrow.triangle.2.circlepath"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .queued: return "Queued. Sends when a teammate is in range."
        case .sent: return "Sent"
        case .waiting: return "Sent. Waiting for the AI Mac."
        case .answered: return "Answered"
        case .received: return "Received"
        case .synced: return "Synced from the AI Mac"
        }
    }

    public static func of(_ entry: ChatEntry, answered: Set<UUID>, waiting: Bool) -> BubbleStatus {
        if entry.backfilled == true { return .synced }
        guard entry.direction == .sent, entry.message.kind != .answer || entry.sentTo.isEmpty else { return .received }
        if entry.message.kind == .ask && (answered.contains(entry.message.askKey) || answered.contains(entry.id)) { return .answered }
        if entry.sentTo.isEmpty { return .queued }
        if entry.message.kind == .ask && waiting { return .waiting }
        return .sent
    }
}

public enum StatusWords {
    /// Second header line, for example "No devices nearby · AI Mac asleep".
    public static func line(linked: Int, nearby: Int, isAIPeer: Bool, ai: AIAvailability) -> String {
        let devices: String
        if linked > 0 { devices = linked == 1 ? "1 device linked" : "\(linked) devices linked" }
        else if nearby > 0 { devices = nearby == 1 ? "1 device nearby, linking" : "\(nearby) devices nearby, linking" }
        else { devices = "No devices nearby" }
        return devices + " · " + aiWords(isAIPeer: isAIPeer, ai: ai)
    }

    public static func aiWords(isAIPeer: Bool, ai: AIAvailability) -> String {
        if isAIPeer { return "This Mac is the AI" }
        switch ai {
        case .awake: return "AI Mac connected"
        case .asleep: return "AI Mac asleep"
        case .offline: return "AI Mac out of range"
        case .notServing: return "AI Mac is not in this room"
        case .unknown: return "No AI Mac yet"
        }
    }

    /// Chat header subtitle: one short line ("Kyle's Mac nearby", "No one nearby").
    /// - Parameters:
    ///   - aiMac: name of the AI Mac serving this room, when one is heard.
    ///   - firstPeer: name of a linked device, for "Ana nearby".
    public static func subtitle(linked: Int, nearby: Int, isAIPeer: Bool, ai: AIAvailability,
                                aiMac: String?, firstPeer: String?) -> String {
        func others(_ lead: String, _ more: Int) -> String {
            more <= 0 ? "\(lead) nearby" : "\(lead) and \(more) more nearby"
        }
        if !isAIPeer, let mac = aiMac, !mac.isEmpty {
            switch ai {
            case .awake: return linked > 0 ? others(mac, linked - 1) : "\(mac) nearby"
            case .asleep: return "\(mac) is asleep"
            case .notServing: return "\(mac) is not in this room"
            case .offline, .unknown: break
            }
        }
        if linked == 0 { return nearby > 0 ? "Connecting..." : "No one nearby" }
        if let first = firstPeer, !first.isEmpty { return others(first, linked - 1) }
        return linked == 1 ? "1 device nearby" : "\(linked) devices nearby"
    }

    /// Green dot next to the room name: Pasa can answer right now.
    public static func aiReady(isAIPeer: Bool, ai: AIAvailability) -> Bool {
        isAIPeer || ai == .awake
    }

    /// The one offline banner, or nil when it is not needed.
    public static func offlineBanner(linked: Int, queued: Int) -> String? {
        guard linked == 0, queued > 0 else { return nil }
        return queued == 1
            ? "No one nearby. 1 message will send when a teammate is in range."
            : "No one nearby. \(queued) messages will send when a teammate is in range."
    }
}

// MARK: - Composer staging (iMessage style: nothing sends until the send arrow)

/// A photo (or voice note) waiting in the composer.
public struct StagedItem: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MediaKind
    public var data: Data
    public var mime: String
    public var width: Int?
    public var height: Int?
    public var seconds: Double?

    public init(id: UUID = UUID(), kind: MediaKind, data: Data, mime: String, width: Int? = nil, height: Int? = nil, seconds: Double? = nil) {
        self.id = id
        self.kind = kind
        self.data = data
        self.mime = mime
        self.width = width
        self.height = height
        self.seconds = seconds
    }
}

/// What the composer holds before the send arrow: text and up to 4 photos.
public struct ComposerDraft: Equatable, Sendable {
    public static let maxPhotos = 4

    public var text: String
    public private(set) var photos: [StagedItem]

    public init(text: String = "", photos: [StagedItem] = []) {
        self.text = text
        self.photos = []
        addPhotos(photos)
    }

    public var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The send arrow shows when there is text or at least one staged photo.
    public var canSend: Bool { !trimmed.isEmpty || !photos.isEmpty }
    public var photoSlots: Int { max(0, Self.maxPhotos - photos.count) }
    public var isEmpty: Bool { trimmed.isEmpty && photos.isEmpty }

    /// Adds photos up to the cap of 4. Returns how many did not fit.
    @discardableResult
    public mutating func addPhotos(_ items: [StagedItem]) -> Int {
        let images = items.filter { $0.kind == .image }
        let fit = Array(images.prefix(photoSlots))
        photos.append(contentsOf: fit)
        return items.count - fit.count
    }

    public mutating func removePhoto(_ id: UUID) {
        photos.removeAll { $0.id == id }
    }

    public mutating func clear() {
        text = ""
        photos = []
    }

    public struct Plan: Equatable, Sendable {
        public var photos: [StagedItem]
        /// The caption or message text, nil when empty.
        public var text: String?
        /// The text starts with @pasa: with photos it becomes ONE ask about the photos.
        public var isAsk: Bool
        public var isEmpty: Bool { photos.isEmpty && text == nil }
    }

    /// Photos go first (each chunked as before), then the caption. An @pasa caption travels as one
    /// ask that names the photos, so the AI Mac waits for them and answers about them.
    public var plan: Plan {
        let caption = trimmed.isEmpty ? nil : trimmed
        return Plan(photos: photos, text: caption, isAsk: caption.map { AssistantMention.strip($0) != nil } ?? false)
    }

    /// VoiceOver label for a staged photo: "Photo 2 of 3, staged. Not sent yet."
    public func accessibilityLabel(for id: UUID) -> String {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return "Photo" }
        return "Photo \(index + 1) of \(photos.count), staged. Not sent yet."
    }
}
