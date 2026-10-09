// TaskDetails.swift
// Pasa: what a task card shows (status with Overdue, relative age, owner checks, board order).
// Pure Swift. Overdue is computed on each device from the spoken due text and the task's
// creation time, never stored, so old builds and old saved tasks need no migration.

import Foundation

/// Status as shown on a card. Stored status stays `TaskStatus` (open / done) so older builds
/// still decode every task; Overdue is derived.
public enum TaskDisplayStatus: String, CaseIterable, Sendable {
    case overdue
    case open
    case done

    /// Text label (never color only).
    public var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .open: return "Open"
        case .done: return "Done"
        }
    }
}

/// Turns the free text due date ("Friday", "tomorrow 8 AM", "Oct 12") into a date, relative to
/// when the task was made. Anything it does not understand gives nil, and then the task is never
/// shown as Overdue (fail closed: no invented deadlines).
public enum TaskDue {
    static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "domingo": 1,
        "monday": 2, "mon": 2, "lunes": 2,
        "tuesday": 3, "tue": 3, "tues": 3, "martes": 3,
        "wednesday": 4, "wed": 4, "miyerkules": 4, "miyerkoles": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "huwebes": 5,
        "friday": 6, "fri": 6, "biyernes": 6, "byernes": 6,
        "saturday": 7, "sat": 7, "sabado": 7
    ]
    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12
    ]
    static let todayWords: Set<String> = ["today", "tonight", "ngayon", "karon", "mamaya", "eod"]
    static let tomorrowWords: Set<String> = ["tomorrow", "tmrw", "bukas", "ugma"]

    public static func resolve(_ raw: String?, from created: Date, calendar: Calendar = .current) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let lower = raw.lowercased()
        let tokens = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        let start = calendar.startOfDay(for: created)
        var day: Date?

        if let iso = isoDay(lower, calendar: calendar) {
            day = iso
        } else if let md = monthDay(tokens, created: start, calendar: calendar) {
            day = md
        } else if tokens.contains(where: { tomorrowWords.contains($0) }) {
            day = calendar.date(byAdding: .day, value: 1, to: start)
        } else if tokens.contains(where: { todayWords.contains($0) }) || lower.contains("end of day") {
            day = start
        } else if let wd = tokens.compactMap({ weekdays[$0] }).first {
            let current = calendar.component(.weekday, from: start)
            var ahead = (wd - current + 7) % 7
            if ahead == 0 && tokens.contains("next") { ahead = 7 }
            day = calendar.date(byAdding: .day, value: ahead, to: start)
        }
        guard let day else { return nil }
        if let (h, m) = clock(lower) {
            return calendar.date(bySettingHour: h, minute: m, second: 0, of: day)
        }
        // No time said: due by the end of that day.
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: day)
    }

    /// "2026-10-12"
    static func isoDay(_ text: String, calendar: Calendar) -> Date? {
        guard let r = text.range(of: #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, options: .regularExpression) else { return nil }
        let parts = text[r].split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// "Oct 12", "October 12", "12 Oct". Rolls to next year only when it is well in the past.
    static func monthDay(_ tokens: [String], created: Date, calendar: Calendar) -> Date? {
        for (i, t) in tokens.enumerated() {
            guard let month = months[t] else { continue }
            var dayNumber: Int?
            if i + 1 < tokens.count, let d = Int(tokens[i + 1].prefix(while: { $0.isNumber })), (1...31).contains(d) { dayNumber = d }
            else if i > 0, let d = Int(tokens[i - 1].prefix(while: { $0.isNumber })), (1...31).contains(d) { dayNumber = d }
            guard let d = dayNumber else { continue }
            let year = calendar.component(.year, from: created)
            guard var date = calendar.date(from: DateComponents(year: year, month: month, day: d)) else { return nil }
            if let cutoff = calendar.date(byAdding: .day, value: -60, to: created), date < cutoff,
               let next = calendar.date(byAdding: .year, value: 1, to: date) { date = next }
            return date
        }
        return nil
    }

    /// "8 AM", "5:30pm", "noon", "17:00". nil when no time was said.
    static func clock(_ text: String) -> (Int, Int)? {
        if text.contains("noon") || text.contains("tanghali") { return (12, 0) }
        if let r = text.range(of: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#, options: .regularExpression) {
            let s = String(text[r])
            let digits = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard var h = digits.first, (1...12).contains(h) else { return nil }
            let m = digits.count > 1 ? digits[1] : 0
            guard (0...59).contains(m) else { return nil }
            let pm = s.contains("p")
            if pm && h != 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
            return (h, m)
        }
        if let r = text.range(of: #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#, options: .regularExpression) {
            let digits = text[r].split(separator: ":").compactMap { Int($0) }
            if digits.count == 2 { return (digits[0], digits[1]) }
        }
        return nil
    }
}

/// "opened 2h ago". Short form for cards, spelled out form for VoiceOver.
public enum TaskAge {
    public static func short(from date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        if d < 7 { return "\(d)d ago" }
        return "\(d / 7)w ago"
    }

    public static func spoken(from date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s") ago" }
        if s < 60 { return "just now" }
        let m = Int(s / 60)
        if m < 60 { return unit(m, "minute") }
        let h = m / 60
        if h < 24 { return unit(h, "hour") }
        let d = h / 24
        if d < 7 { return unit(d, "day") }
        return unit(d / 7, "week")
    }

    public static func opened(_ task: TaskItem, now: Date) -> String { "opened " + short(from: task.createdAt, now: now) }
}

extension TaskItem {
    /// Resolved due date, when the spoken due text is understood.
    public func dueDate(calendar: Calendar = .current) -> Date? {
        TaskDue.resolve(due, from: createdAt, calendar: calendar)
    }

    public func displayStatus(now: Date = Date(), calendar: Calendar = .current) -> TaskDisplayStatus {
        if status == .done { return .done }
        if let d = dueDate(calendar: calendar), d < now { return .overdue }
        return .open
    }

    /// When it was finished (older tasks without `completedAt` use their last update).
    public var doneAt: Date? { status == .done ? (completedAt ?? updatedAt) : nil }

    /// Nobody in particular owns it, so anyone in the room may finish it.
    public var isUnassigned: Bool { (assignee ?? "").isEmpty && (assigneeDevice ?? "").isEmpty }

    /// True when `device` (with its chosen `names`) is the task's owner.
    public func isOwned(by device: String, names: [String] = [], roster: [String: String] = [:]) -> Bool {
        if let d = assigneeDevice, !d.isEmpty { return d == device }
        guard let a = assignee, !a.isEmpty else { return false }
        if a == device { return true }
        let key = NameMatcher.normalize(a)
        if names.contains(where: { !$0.isEmpty && NameMatcher.normalize($0) == key }) { return true }
        return roster.contains { NameMatcher.normalize($0.key) == key && $0.value == device }
    }

    /// Owner or admin may mark it done (anyone, when it has no owner). Done tasks: no.
    public func canComplete(by device: String, names: [String] = [], isAdmin: Bool, roster: [String: String] = [:]) -> Bool {
        guard status == .open else { return false }
        return isAdmin || isUnassigned || isOwned(by: device, names: names, roster: roster)
    }

    /// First 8 hex digits of the id, used by the Done button's "@pasa mark done: ... #1a2b3c4d".
    public var shortID: String { String(id.uuidString.lowercased().prefix(8)) }
}

/// Tasks tab order: Overdue (most overdue first), Open (soonest due first, then undated newest
/// first), Done (most recently finished first).
public struct TaskBoard: Equatable, Sendable {
    public var overdue: [TaskItem]
    public var open: [TaskItem]
    public var done: [TaskItem]

    public init(_ tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) {
        var overdue: [(TaskItem, Date)] = []
        var dated: [(TaskItem, Date)] = []
        var undated: [TaskItem] = []
        var done: [TaskItem] = []
        for t in tasks {
            if t.status == .done { done.append(t); continue }
            if let d = t.dueDate(calendar: calendar) {
                if d < now { overdue.append((t, d)) } else { dated.append((t, d)) }
            } else {
                undated.append(t)
            }
        }
        self.overdue = overdue.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.createdAt < $1.0.createdAt }.map(\.0)
        self.open = dated.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.createdAt < $1.0.createdAt }.map(\.0)
            + undated.sorted { $0.createdAt > $1.createdAt }
        self.done = done.sorted { ($0.doneAt ?? $0.updatedAt) > ($1.doneAt ?? $1.updatedAt) }
    }
}
