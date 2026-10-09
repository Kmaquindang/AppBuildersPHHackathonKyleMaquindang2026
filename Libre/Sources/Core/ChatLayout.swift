// ChatLayout.swift
// Pasa: iMessage-style timeline layout decisions (pure, tested on Linux).
// - Consecutive messages from the same sender form a group: other people's name shows once above
//   their group, never for your own messages. Pasa AI shows a small avatar on its last bubble.
// - A centered timestamp only when more than 15 minutes passed since the previous message, or a
//   new day started (and above the first message).
// - One short status word ("Queued", "Delivered", "Answered") under your LAST own message only.
// - Pasa's typing dots while your question is on its way and the AI Mac is awake; one quiet
//   system line instead when the Mac is asleep, away, or not in this room.

import Foundation

public struct ChatRowLayout: Equatable, Sendable {
    /// Centered timestamp text above this row, nil when not needed.
    public var timestamp: String?
    /// Sender name above the bubble (others only, first of a group).
    public var showName: Bool
    /// First and last bubble of a same-sender group (spacing, avatar).
    public var firstInGroup: Bool
    public var lastInGroup: Bool
    /// Status word under this row (only the last own message gets one).
    public var statusWord: String?
}

public enum ChatLayout {
    public static let timestampGap: TimeInterval = 15 * 60
    /// Asks older than this no longer show the typing dots (the Mac would have answered or failed).
    public static let typingWindow: TimeInterval = 10 * 60

    /// Who a bubble belongs to, for grouping: Pasa AI for answers, else the device.
    public static func senderKey(_ entry: ChatEntry) -> String {
        entry.message.kind == .answer ? "pasa-ai" : entry.message.origin
    }

    public static func isMine(_ entry: ChatEntry) -> Bool {
        entry.direction == .sent && entry.message.kind != .answer
    }

    public static func layout(_ entries: [ChatEntry], statuses: [UUID: BubbleStatus],
                              now: Date = Date(), calendar: Calendar = .current) -> [UUID: ChatRowLayout] {
        var out: [UUID: ChatRowLayout] = [:]
        let lastMine = entries.last(where: isMine)?.id
        for (i, entry) in entries.enumerated() {
            let prev = i > 0 ? entries[i - 1] : nil
            let next = i + 1 < entries.count ? entries[i + 1] : nil
            let at = entry.message.createdAt
            var stamp: String?
            if let prev {
                let gap = at.timeIntervalSince(prev.message.createdAt)
                if gap > timestampGap || !calendar.isDate(at, inSameDayAs: prev.message.createdAt) {
                    stamp = timestampText(at, now: now, calendar: calendar)
                }
            } else {
                stamp = timestampText(at, now: now, calendar: calendar)
            }
            let breaksBefore = prev == nil || stamp != nil || senderKey(prev!) != senderKey(entry)
            var breaksAfter = next == nil || senderKey(next!) != senderKey(entry)
            if let next, !breaksAfter {
                let gap = next.message.createdAt.timeIntervalSince(at)
                if gap > timestampGap || !calendar.isDate(next.message.createdAt, inSameDayAs: at) { breaksAfter = true }
            }
            let mine = isMine(entry)
            out[entry.id] = ChatRowLayout(
                timestamp: stamp,
                showName: !mine && breaksBefore,
                firstInGroup: breaksBefore,
                lastInGroup: breaksAfter,
                statusWord: entry.id == lastMine ? statusWord(statuses[entry.id] ?? .received) : nil
            )
        }
        return out
    }

    /// "Today 8:33 PM", "Yesterday 9:10 AM", "Wed, Oct 7 4:02 PM".
    public static func timestampText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = calendar.timeZone
        time.dateFormat = "h:mm a"
        if calendar.isDate(date, inSameDayAs: now) { return "Today " + time.string(from: date) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Yesterday " + time.string(from: date)
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = calendar.timeZone
        day.dateFormat = "EEE, MMM d"
        return day.string(from: date) + " " + time.string(from: date)
    }

    /// The small word under your last message.
    public static func statusWord(_ status: BubbleStatus) -> String? {
        switch status {
        case .queued: return "Queued"
        case .sent, .waiting: return "Delivered"
        case .answered: return "Answered"
        case .received, .synced: return nil
        }
    }

    /// Asks from this device that went out (not queued) and have no answer yet.
    public static func pendingAsks(_ entries: [ChatEntry], device: String, now: Date = Date()) -> [ChatEntry] {
        let done = AskCoalescer.answered(entries)
        return entries.filter { e in
            e.message.kind == .ask && e.direction == .sent && e.message.origin == device && !e.sentTo.isEmpty
                && !done.contains(e.message.askKey) && !done.contains(e.id)
                && now.timeIntervalSince(e.message.createdAt) < typingWindow
        }
    }
}

/// What the bottom of the timeline shows while a question of ours is pending.
public enum TypingState: Equatable, Sendable {
    case none
    /// Pasa's bubble with three animated dots.
    case typing
    /// One small centered system line.
    case note(String)

    public static let asleepLine = "Pasa is asleep. Your question will be answered when the Mac wakes."
    public static let awayLine = "Pasa will answer when the AI Mac is in range."
    public static let notServingLine = "The AI Mac nearby is not in this room. Ask the room admin to add it."

    public static func of(pending: Int, isAIPeer: Bool, ai: AIAvailability) -> TypingState {
        guard pending > 0 else { return .none }
        if isAIPeer { return .typing }
        switch ai {
        case .awake: return .typing
        case .asleep: return .note(asleepLine)
        case .notServing: return .note(notServingLine)
        case .offline, .unknown: return .note(awayLine)
        }
    }
}
