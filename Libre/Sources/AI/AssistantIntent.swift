// AssistantIntent.swift
// Libre: what the user wants from "@libre ..." and how we read it.
// Deterministic fast paths handle the common phrases with no model call. Everything else is
// classified by the local model in JSON mode and decoded leniently here.

import Foundation

public enum IntentKind: String, CaseIterable, Sendable {
    case saveRule = "save_rule"
    case editRule = "edit_rule"
    case lockRule = "lock_rule"
    case unlockRule = "unlock_rule"
    case addTask = "add_task"
    case listMyTasks = "list_my_tasks"
    case listTeamTasks = "list_team_tasks"
    case markDone = "mark_done"
    case summarize = "summarize"
    case takeNotes = "take_notes"
    case answer = "answer"
    case more = "more"
}

public struct AssistantPlan: Equatable, Sendable {
    public var kind: IntentKind
    public var title: String?
    public var body: String?
    public var ruleKind: RuleKind = .rule
    public var taskTitle: String?
    public var assignee: String?
    public var due: String?
    public var taskRef: String?
    public var question: String?
    /// True when the plan came from a fast path (no model call).
    public var fromFastPath = false

    public init(kind: IntentKind, title: String? = nil, body: String? = nil, ruleKind: RuleKind = .rule,
                taskTitle: String? = nil, assignee: String? = nil, due: String? = nil,
                taskRef: String? = nil, question: String? = nil, fromFastPath: Bool = false) {
        self.kind = kind
        self.title = title
        self.body = body
        self.ruleKind = ruleKind
        self.taskTitle = taskTitle
        self.assignee = assignee
        self.due = due
        self.taskRef = taskRef
        self.question = question
        self.fromFastPath = fromFastPath
    }
}

public struct NoteActionItem: Equatable, Sendable {
    public var title: String
    public var assignee: String?
    public var due: String?
}

public struct NotesExtraction: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var decisions: [String]
    public var actionItems: [NoteActionItem]
}

public enum IntentParser {
    /// Messages longer than this are treated as a transcript to take notes from.
    public static let notesLengthThreshold = 600

    // MARK: Fast paths

    public static func fastPath(_ raw: String) -> AssistantPlan? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let norm = NameMatcher.normalize(text)
        guard !norm.isEmpty else { return nil }

        if ["more", "more please", "continue", "go on", "the rest"].contains(norm) {
            return AssistantPlan(kind: .more, fromFastPath: true)
        }
        if norm.contains("what did i miss") || norm.contains("what i missed") || norm.contains("catch me up") || norm == "summary" || norm == "summarize" {
            return AssistantPlan(kind: .summarize, fromFastPath: true)
        }
        if ["my tasks", "my task", "my to dos", "my todos", "my todo", "what are my tasks", "list my tasks", "show my tasks"].contains(norm) {
            return AssistantPlan(kind: .listMyTasks, fromFastPath: true)
        }
        if ["team tasks", "all tasks", "our tasks", "our to dos", "our todos", "what are our to dos", "what are our tasks", "list tasks", "tasks"].contains(norm) {
            return AssistantPlan(kind: .listTeamTasks, fromFastPath: true)
        }

        let lower = text.lowercased()
        let ruleCommands: [(prefix: String, kind: IntentKind, ruleKind: RuleKind)] = [
            ("save rule", .saveRule, .rule), ("add rule", .saveRule, .rule), ("new rule", .saveRule, .rule),
            ("save skill", .saveRule, .skill), ("add skill", .saveRule, .skill), ("new skill", .saveRule, .skill),
            ("update rule", .editRule, .rule), ("edit rule", .editRule, .rule), ("change rule", .editRule, .rule),
            ("update skill", .editRule, .skill), ("edit skill", .editRule, .skill)
        ]
        for command in ruleCommands where lower.hasPrefix(command.prefix) {
            let rest = remainder(of: text, after: command.prefix)
            guard !rest.isEmpty else { return nil }
            let (title, body) = splitTitleBody(rest)
            return AssistantPlan(kind: command.kind, title: title, body: body, ruleKind: command.ruleKind, fromFastPath: true)
        }
        for (prefix, kind) in [("unlock rule", IntentKind.unlockRule), ("lock rule", .lockRule), ("unlock skill", .unlockRule), ("lock skill", .lockRule)] where lower.hasPrefix(prefix) {
            let rest = remainder(of: text, after: prefix)
            guard !rest.isEmpty else { return nil }
            return AssistantPlan(kind: kind, title: rest, fromFastPath: true)
        }
        for prefix in ["take notes", "notes", "minutes", "transcript"] where lower.hasPrefix(prefix) {
            let rest = remainder(of: text, after: prefix)
            if rest.count >= 20 { return AssistantPlan(kind: .takeNotes, body: rest, fromFastPath: true) }
        }
        if text.count > notesLengthThreshold {
            return AssistantPlan(kind: .takeNotes, body: text, fromFastPath: true)
        }
        return nil
    }

    static func remainder(of text: String, after prefix: String) -> String {
        var rest = String(text.dropFirst(prefix.count))
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = rest.first, [":", "-", ",", "."].contains(first) {
            rest.removeFirst()
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest
    }

    /// "Site hours: no visits after 5 PM" -> ("Site hours", "no visits after 5 PM").
    /// Without a colon, a short body doubles as its own title.
    static func splitTitleBody(_ text: String) -> (String, String) {
        if let colon = text.firstIndex(of: ":") {
            let title = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !body.isEmpty, title.count <= 60 { return (title, body) }
        }
        return (deriveTitle(from: text), text)
    }

    public static func deriveTitle(from body: String) -> String {
        var t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 60 {
            t = t.split(separator: " ").prefix(8).joined(separator: " ")
        }
        while let last = t.last, [".", "!", ","].contains(last) { t.removeLast() }
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst()
    }

    // MARK: Model output

    /// Pulls the first {...} object out of model text (handles code fences and chatter).
    public static func extractJSONObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    static func string(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            var result: String?
            switch value {
            case let s as String: result = s
            case let i as Int: result = String(i)
            case let d as Double: result = String(d)
            case let n as NSNumber: result = n.stringValue
            case let a as [Any]: result = a.compactMap { $0 as? String }.joined(separator: ", ")
            default: result = nil
            }
            if let r = result?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty, r.lowercased() != "null", r.lowercased() != "none" {
                return r
            }
        }
        return nil
    }

    public static func normalizeKind(_ raw: String) -> IntentKind? {
        let key = raw.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if let exact = IntentKind(rawValue: key) { return exact }
        let aliases: [String: IntentKind] = [
            "rule": .saveRule, "save_skill": .saveRule, "add_rule": .saveRule, "skill": .saveRule,
            "update_rule": .editRule, "lock": .lockRule, "unlock": .unlockRule,
            "task": .addTask, "create_task": .addTask, "remind": .addTask, "reminder": .addTask, "todo": .addTask,
            "my_tasks": .listMyTasks, "list_tasks": .listTeamTasks, "team_tasks": .listTeamTasks,
            "done": .markDone, "complete_task": .markDone, "complete": .markDone,
            "summary": .summarize, "catch_up": .summarize, "what_did_i_miss": .summarize,
            "notes": .takeNotes, "note": .takeNotes, "question": .answer, "qa": .answer, "chat": .answer
        ]
        return aliases[key]
    }

    /// Lenient decode of the classifier's JSON. Falls back to `answer` when the intent is unknown.
    public static func decodePlan(from modelText: String, original: String) -> AssistantPlan {
        guard let dict = extractJSONObject(modelText) else {
            return AssistantPlan(kind: .answer, question: original)
        }
        let kind = string(dict, "intent", "type", "action").flatMap(normalizeKind) ?? .answer
        var plan = AssistantPlan(kind: kind)
        plan.title = string(dict, "title", "rule_title", "name")
        plan.body = string(dict, "body", "rule_body", "content", "text")
        if let k = string(dict, "kind", "rule_kind")?.lowercased(), k.contains("skill") { plan.ruleKind = .skill }
        plan.taskTitle = string(dict, "task_title", "task", "todo")
        plan.assignee = string(dict, "assignee", "assigned_to", "person", "who")
        plan.due = string(dict, "due", "due_date", "when", "deadline")
        plan.taskRef = string(dict, "task_ref", "task_title", "task", "title")
        plan.question = string(dict, "question", "query") ?? original

        switch kind {
        case .saveRule, .editRule:
            if plan.body == nil { plan.body = plan.title ?? original }
            if plan.title == nil { plan.title = deriveTitle(from: plan.body ?? original) }
        case .addTask:
            if plan.taskTitle == nil { plan.taskTitle = plan.title ?? original }
        case .takeNotes:
            if plan.body == nil || (plan.body?.count ?? 0) < original.count / 2 { plan.body = original }
        default:
            break
        }
        return plan
    }

    public static func decodeNotes(from modelText: String) -> NotesExtraction? {
        guard let dict = extractJSONObject(modelText) else { return nil }
        let summary = string(dict, "summary") ?? ""
        let title = string(dict, "title") ?? deriveTitle(from: summary.isEmpty ? "Meeting notes" : summary)
        let decisions = (dict["decisions"] as? [Any])?.compactMap { item -> String? in
            if let s = item as? String { return s.nilIfBlank }
            if let d = item as? [String: Any] { return string(d, "decision", "text", "title") }
            return nil
        } ?? []
        let rawItems = (dict["action_items"] as? [Any]) ?? (dict["tasks"] as? [Any]) ?? []
        let items: [NoteActionItem] = rawItems.compactMap { item in
            if let s = item as? String, let t = s.nilIfBlank { return NoteActionItem(title: t, assignee: nil, due: nil) }
            guard let d = item as? [String: Any], let t = string(d, "title", "task", "text") else { return nil }
            return NoteActionItem(title: t, assignee: string(d, "assignee", "owner", "who"), due: string(d, "due", "when"))
        }
        if summary.isEmpty && decisions.isEmpty && items.isEmpty { return nil }
        return NotesExtraction(title: title, summary: summary, decisions: decisions, actionItems: items)
    }
}
