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
