// OrgMemory.swift
// Pasa: the team memory store with permission rules and versioning. Pure Swift.
// On the Mac it is the source of truth; on phones it is a read-only cache fed by mesh updates.
//
// Rules policy:
// - Anyone can add a new rule or skill.
// - Only an admin device can edit an existing rule (new version, old one kept in history)
//   or lock / unlock it. A locked rule cannot be edited by anyone until an admin unlocks it.
// - When copies meet (mesh cache), the newest version wins; ties go to the latest update time.

import Foundation

public enum RuleChange: Equatable, Sendable {
    case created(RuleEntry)
    case updated(RuleEntry)
    case unchanged(RuleEntry)
    case denied(String)

    public var entry: RuleEntry? {
        switch self {
        case .created(let e), .updated(let e), .unchanged(let e): return e
        case .denied: return nil
        }
    }
}

public final class OrgMemory {
    public private(set) var snapshot: OrgSnapshot
    /// Device names allowed to edit, lock and unlock existing rules.
    public var admins: Set<String>
    public let fileURL: URL?
    public var maxChatLog = 200
    public private(set) var lastSaveError: String?

    public init(fileURL: URL? = nil, admins: Set<String> = []) {
        self.fileURL = fileURL
        self.admins = admins
        self.snapshot = OrgSnapshot()
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode(OrgSnapshot.self, from: data) {
                snapshot = loaded
            }
        }
    }

    public func isAdmin(_ device: String) -> Bool {
        admins.contains(device)
    }

    // MARK: Persistence

    @discardableResult
    public func save() -> Bool {
        guard let fileURL else { return true }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = error.localizedDescription
            return false
        }
    }

    // MARK: Rules

    public var rules: [RuleEntry] { snapshot.rules }

    public func rule(titled title: String) -> RuleEntry? {
        let key = NameMatcher.normalize(title)
        if let exact = snapshot.rules.first(where: { NameMatcher.normalize($0.title) == key }) { return exact }
        guard let name = NameMatcher.match(title, in: snapshot.rules.map { $0.title }) else { return nil }
        return snapshot.rules.first { $0.title == name }
    }

    /// Adds a new rule, or edits an existing one with the same title (admin only, not locked).
    public func upsertRule(title rawTitle: String, body rawBody: String, kind: RuleKind = .rule, by device: String, now: Date = Date()) -> RuleChange {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return .denied("A rule needs a title and a body.") }

        let key = NameMatcher.normalize(title)
        if let index = snapshot.rules.firstIndex(where: { NameMatcher.normalize($0.title) == key }) {
            var rule = snapshot.rules[index]
            guard isAdmin(device) else {
                return .denied("Only an admin device can change \(rule.citation). Ask an admin, or save it under a new title.")
            }
            guard !rule.locked else {
                return .denied("\(rule.citation) is locked. An admin must unlock it first.")
            }
            if rule.body == body && rule.kind == kind { return .unchanged(rule) }
            rule.history.append(RuleVersion(version: rule.version, title: rule.title, body: rule.body, editedBy: rule.updatedBy, editedAt: rule.updatedAt))
            rule.version += 1
            rule.body = body
            rule.kind = kind
            rule.updatedBy = device
            rule.updatedAt = now
            snapshot.rules[index] = rule
            save()
            return .updated(rule)
        }

        let rule = RuleEntry(kind: kind, title: title, body: body, addedBy: device, createdAt: now)
        snapshot.rules.append(rule)
        save()
        return .created(rule)
    }

    public func setLocked(title: String, locked: Bool, by device: String, now: Date = Date()) -> RuleChange {
        guard let found = rule(titled: title), let index = snapshot.rules.firstIndex(where: { $0.id == found.id }) else {
            return .denied("No rule called \"\(title)\".")
        }
        guard isAdmin(device) else {
            return .denied("Only an admin device can \(locked ? "lock" : "unlock") \(found.citation).")
        }
        var rule = snapshot.rules[index]
        if rule.locked == locked { return .unchanged(rule) }
        rule.locked = locked
        rule.updatedBy = device
        rule.updatedAt = now
        snapshot.rules[index] = rule
        save()
        return .updated(rule)
    }

    /// Cache merge: newest version wins, ties go to the later update. Keeps known history.
    @discardableResult
    public func mergeRule(_ incoming: RuleEntry) -> Bool {
        guard let index = snapshot.rules.firstIndex(where: { $0.id == incoming.id }) else {
            snapshot.rules.append(incoming)
            save()
            return true
        }
        let current = snapshot.rules[index]
        let newer = incoming.version > current.version
            || (incoming.version == current.version && incoming.updatedAt > current.updatedAt)
        guard newer else { return false }
        var merged = incoming
        var byVersion: [Int: RuleVersion] = [:]
        for v in current.history + incoming.history { byVersion[v.version] = v }
        if current.version < incoming.version {
            byVersion[current.version] = RuleVersion(version: current.version, title: current.title, body: current.body, editedBy: current.updatedBy, editedAt: current.updatedAt)
        }
        merged.history = byVersion.values.filter { $0.version < incoming.version }.sorted { $0.version < $1.version }
        snapshot.rules[index] = merged
        save()
        return true
    }

    // MARK: Tasks

    public var tasks: [TaskItem] { snapshot.tasks }
    public var openTasks: [TaskItem] { snapshot.tasks.filter { $0.status == .open } }

    @discardableResult
    public func addTask(title: String, assignee: String?, assigneeDevice: String?, due: String?, by device: String, source: String? = nil, now: Date = Date()) -> TaskItem {
        let task = TaskItem(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            assignee: assignee?.nilIfBlank,
            assigneeDevice: assigneeDevice?.nilIfBlank,
            due: due?.nilIfBlank,
            createdBy: device,
            createdAt: now,
            source: source
        )
        snapshot.tasks.append(task)
        save()
        return task
    }

    /// Open tasks for a device: assigned to that device, or to a person the roster maps to it.
    public func tasks(forDevice device: String, roster: [String: String] = [:], includeDone: Bool = false) -> [TaskItem] {
        let people = Set(roster.filter { $0.value == device }.map { NameMatcher.normalize($0.key) })
        return snapshot.tasks.filter { task in
            guard includeDone || task.status == .open else { return false }
            if task.assigneeDevice == device { return true }
            if let a = task.assignee, people.contains(NameMatcher.normalize(a)) || a == device { return true }
            return false
        }
    }

    /// Finds an open task from loose words ("cement", "the cement order"). Prefers the device's own tasks.
    public func findOpenTask(matching ref: String, preferFor device: String? = nil, roster: [String: String] = [:]) -> TaskItem? {
        let query = NameMatcher.normalize(ref)
        guard !query.isEmpty else { return nil }
        if let id = UUID(uuidString: ref.trimmingCharacters(in: .whitespaces)), let t = snapshot.tasks.first(where: { $0.id == id && $0.status == .open }) {
            return t
        }
        let stop: Set<String> = ["the", "a", "an", "to", "my", "task", "is", "done", "for", "of", "and", "finished", "complete", "completed"]
        let words = Set(query.split(separator: " ").map(String.init)).subtracting(stop)
        func score(_ t: TaskItem) -> Int {
            let titleWords = Set(NameMatcher.normalize(t.title).split(separator: " ").map(String.init))
            var s = words.intersection(titleWords).count * 2
            if NameMatcher.normalize(t.title).contains(query) { s += 3 }
            return s
        }
        let mine = device.map { Set(tasks(forDevice: $0, roster: roster).map { $0.id }) } ?? []
        let ranked = openTasks
            .map { ($0, score($0) + (mine.contains($0.id) ? 1 : 0)) }
            .filter { $0.1 >= 2 }
            .sorted { $0.1 > $1.1 }
        guard let top = ranked.first else { return nil }
        if ranked.count > 1 && ranked[1].1 == top.1 { return nil }
        return top.0
    }

    @discardableResult
    public func markDone(_ id: UUID, by device: String, now: Date = Date()) -> TaskItem? {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return nil }
        snapshot.tasks[index].status = .done
        snapshot.tasks[index].completedBy = device
        snapshot.tasks[index].updatedAt = now
        save()
        return snapshot.tasks[index]
    }

    @discardableResult
    public func reopen(_ id: UUID, by device: String, now: Date = Date()) -> TaskItem? {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return nil }
        snapshot.tasks[index].status = .open
        snapshot.tasks[index].completedBy = nil
        snapshot.tasks[index].updatedAt = now
        save()
        return snapshot.tasks[index]
    }

    /// Cache merge for tasks: later updatedAt wins.
    @discardableResult
    public func mergeTask(_ incoming: TaskItem) -> Bool {
        if let index = snapshot.tasks.firstIndex(where: { $0.id == incoming.id }) {
            guard incoming.updatedAt > snapshot.tasks[index].updatedAt else { return false }
            snapshot.tasks[index] = incoming
        } else {
            snapshot.tasks.append(incoming)
        }
        save()
        return true
    }

    // MARK: Notes

    public var notes: [Note] { snapshot.notes }

    @discardableResult
    public func addNote(title: String, summary: String, decisions: [String], taskIDs: [UUID], by device: String, now: Date = Date()) -> Note {
        let note = Note(title: title, summary: summary, decisions: decisions, taskIDs: taskIDs, createdBy: device, createdAt: now)
        snapshot.notes.append(note)
        save()
        return note
    }

    // MARK: Chat log (what the Mac has seen over the mesh)

    public func recordChat(from: String, text: String, at: Date = Date()) {
        snapshot.chatLog.append(ChatLogLine(from: from, text: text, at: at))
        if snapshot.chatLog.count > maxChatLog {
            snapshot.chatLog.removeFirst(snapshot.chatLog.count - maxChatLog)
        }
        save()
    }

    public func recentChat(limit: Int) -> [ChatLogLine] {
        Array(snapshot.chatLog.suffix(limit))
    }

    /// Wipes everything (used by tests and the Mac "Reset memory" button).
    public func reset() {
        snapshot = OrgSnapshot()
        save()
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
