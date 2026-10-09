// OrgModels.swift
// Libre: the team's shared memory (tasks, notes, rules and skills). Pure Swift, Codable.
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
        history: [RuleVersion] = []
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
    }

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

    public init(from: String, text: String, at: Date) {
        self.from = from
        self.text = text
        self.at = at
    }
}

/// Everything the team remembers. Saved as one JSON file.
public struct OrgSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var rules: [RuleEntry] = []
    public var tasks: [TaskItem] = []
    public var notes: [Note] = []
    public var chatLog: [ChatLogLine] = []

    public init() {}
}
