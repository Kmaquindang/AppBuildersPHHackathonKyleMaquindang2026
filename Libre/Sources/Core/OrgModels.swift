// OrgModels.swift
// Pasa: the team's shared memory (tasks, notes, rules and skills). Pure Swift, Codable.
// The Mac AI peer holds the source of truth; phones keep a read-only cache received over the mesh.

import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case open
    case done
}

public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// Person or device the task is for, as the team said it ("Ana").
    public var assignee: String?
    /// Mesh device that should receive the task ("iPhone 12"), when known.
    public var assigneeDevice: String?
    /// Free text due date as spoken ("Friday", "tomorrow 8 AM").
    public var due: String?
    public var status: TaskStatus
    public var createdBy: String
    public var createdAt: Date
    public var updatedAt: Date
    public var completedBy: String?
    /// Where it came from, for example "ask" or "notes".
    public var source: String?

    public init(
        id: UUID = UUID(),
        title: String,
        assignee: String? = nil,
        assigneeDevice: String? = nil,
        due: String? = nil,
        status: TaskStatus = .open,
        createdBy: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        completedBy: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.assigneeDevice = assigneeDevice
        self.due = due
        self.status = status
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedBy = completedBy
        self.source = source
    }

    /// "Order cement (Ana, due Friday)"
    public var shortLine: String {
        var extras: [String] = []
        if let assignee, !assignee.isEmpty { extras.append(assignee) }
        if let due, !due.isEmpty { extras.append("due \(due)") }
        let tail = extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))"
        return title + tail
    }
}

public enum RuleKind: String, Codable, CaseIterable, Hashable, Sendable {
    case rule
    case skill

    public var label: String { self == .rule ? "Rule" : "Skill" }
}

public struct RuleVersion: Codable, Hashable, Sendable {
    public var version: Int
    public var title: String
    public var body: String
    public var editedBy: String
    public var editedAt: Date

    public init(version: Int, title: String, body: String, editedBy: String, editedAt: Date) {
        self.version = version
        self.title = title
        self.body = body
        self.editedBy = editedBy
        self.editedAt = editedAt
    }
}

public struct RuleEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: RuleKind
    public var title: String
    public var body: String
    /// Device that first added it.
    public var addedBy: String
    public var createdAt: Date
    public var version: Int
    public var updatedBy: String
    public var updatedAt: Date
    public var locked: Bool
    /// Older versions, oldest first. The current version lives in title/body/version.
    public var history: [RuleVersion]
    /// Tombstone fields. A deleted rule is kept as a retired entry (version + 1) so the deletion
    /// travels over the mesh and stale phone caches drop it. Optional so older JSON still decodes.
    public var retired: Bool?
    public var retiredBy: String?
    public var retiredAt: Date?

    public init(
        id: UUID = UUID(),
        kind: RuleKind = .rule,
        title: String,
        body: String,
        addedBy: String,
        createdAt: Date = Date(),
        version: Int = 1,
        updatedBy: String? = nil,
        updatedAt: Date? = nil,
        locked: Bool = false,
        history: [RuleVersion] = [],
        retired: Bool? = nil,
        retiredBy: String? = nil,
        retiredAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.addedBy = addedBy
        self.createdAt = createdAt
        self.version = version
        self.updatedBy = updatedBy ?? addedBy
        self.updatedAt = updatedAt ?? createdAt
        self.locked = locked
        self.history = history
        self.retired = retired
        self.retiredBy = retiredBy
        self.retiredAt = retiredAt
    }

    /// True for a deleted rule (tombstone). Retired rules are hidden and never sent to the model.
    public var isRetired: Bool { retired == true }

    /// Citation tag used in answers, for example "[Rule: No site visits after 5 PM v2]".
    public var citation: String { "[\(kind.label): \(title) v\(version)]" }

    /// Copy without history, small enough to broadcast over the mesh.
    public var meshSummary: RuleEntry {
        var copy = self
        copy.history = []
        return copy
    }
}

public struct Note: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var summary: String
    public var decisions: [String]
    public var taskIDs: [UUID]
    public var createdBy: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        decisions: [String] = [],
        taskIDs: [UUID] = [],
        createdBy: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.taskIDs = taskIDs
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    public var citation: String { "[Note: \(title)]" }
}

public struct ChatLogLine: Codable, Hashable, Sendable {
    public var from: String
    public var text: String
    public var at: Date
    /// Device id of the sender, when known (optional so older files still decode).
    public var device: String?

    public init(from: String, text: String, at: Date, device: String? = nil) {
        self.from = from
        self.text = text
        self.at = at
        self.device = device
    }
}

/// Everything the team remembers. Saved as one JSON file.
public struct OrgSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var rules: [RuleEntry] = []
    public var tasks: [TaskItem] = []
    public var notes: [Note] = []
    public var chatLog: [ChatLogLine] = []
    /// When the Mac's team memory was last reset. Phones learn it on the next link and drop
    /// cached rules and tasks the Mac no longer has.
    public var resetAt: Date? = nil
    /// AI Mac only: every @pasa question and Pasa's answer in this room, oldest first (optional so
    /// older files still decode). Never trimmed; the newest ones go into prompts verbatim.
    public var thread: [ThreadTurn]? = nil
    /// AI Mac only: rolling "room so far" summary of the oldest thread turns.
    public var roomSummary: RoomSummary? = nil

    public init() {}

    /// Rules and skills still in force (tombstones of deleted rules left out).
    public var activeRules: [RuleEntry] { rules.filter { !$0.isRetired } }
}

/// One @pasa exchange: the question, who asked, and Pasa's answer.
public struct ThreadTurn: Codable, Hashable, Sendable, Identifiable {
    /// The ask's id (askKey), so a summary can name the range it covers.
    public var id: UUID
    public var asker: String
    public var askerName: String
    public var question: String
    public var answer: String
    public var at: Date

    public init(id: UUID, asker: String, askerName: String, question: String, answer: String, at: Date) {
        self.id = id
        self.asker = asker
        self.askerName = askerName
        self.question = question
        self.answer = answer
        self.at = at
    }
}

/// "Room so far": a short model-written summary of the oldest thread turns. It never holds rules,
/// tasks or decisions (those stay structured and are retrieved fresh for every answer).
public struct RoomSummary: Codable, Hashable, Sendable {
    public var text: String
    public var updatedAt: Date
    /// First and last thread turn (ask ids) the summary covers, and how many.
    public var firstTurn: UUID
    public var lastTurn: UUID
    public var turnCount: Int
    public var coveredFrom: Date
    public var coveredTo: Date

    public init(text: String, updatedAt: Date, firstTurn: UUID, lastTurn: UUID, turnCount: Int, coveredFrom: Date, coveredTo: Date) {
        self.text = text
        self.updatedAt = updatedAt
        self.firstTurn = firstTurn
        self.lastTurn = lastTurn
        self.turnCount = turnCount
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
    }
}
