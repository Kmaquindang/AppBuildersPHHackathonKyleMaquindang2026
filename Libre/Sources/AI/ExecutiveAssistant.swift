// ExecutiveAssistant.swift
// Libre: the team's executive assistant. Runs on the Mac AI peer, all local.
//
// Flow for every "@libre ..." / Ask AI message:
// 1. Fast path for common phrases (no model call), otherwise one JSON-mode model call
//    classifies the intent and extracts fields.
// 2. The intent is applied to OrgMemory (the source of truth) with its permission rules.
// 3. When needed, a second model call writes the reply (grounded answers, catch-up, notes).
// 4. The reply is compacted for the mesh; the rest is kept for "@libre more".
// Task and rule changes are returned so the mesh layer can notify assignees and phones.

import Foundation

public struct AssistantOutcome: Sendable {
    public var intent: IntentKind
    public var reply: String
    public var compact: Bool
    /// Model that produced the reply, nil when no model call was needed.
    public var model: String?
    public var latencyMs: Int
    public var tokensPerSecond: Double?
    public var evalCount: Int?
    public var modelCalls: Int
    /// Tasks created or changed: send each to its assignee device.
    public var taskUpdates: [TaskItem]
    /// Rules created or changed: broadcast a summary so phones cache it.
    public var ruleUpdates: [RuleEntry]
    public var error: String?
}

@MainActor
public final class ExecutiveAssistant {
    public let memory: OrgMemory
    public var llm: any LLMClient
    /// This Mac's mesh name (always an admin).
    public var selfName: String
    /// Person -> device, for example "Ana" -> "iPhone 12".
    public var roster: [String: String]
    /// Devices currently or recently seen on the mesh.
    public var knownDevices: [String]
    public var chatContextLimit = 30

    private var pendingMore: [String: String] = [:]

    public init(memory: OrgMemory, llm: any LLMClient, selfName: String, roster: [String: String] = [:], knownDevices: [String] = []) {
        self.memory = memory
        self.llm = llm
        self.selfName = selfName
        self.roster = roster
        self.knownDevices = knownDevices
    }

    var people: [String] {
        var names = Array(roster.keys) + knownDevices + [selfName]
        names = names.filter { !$0.isEmpty }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Resolves a spoken assignee to (display name, device).
    public func resolveAssignee(_ raw: String?, asker: String) -> (name: String?, device: String?) {
        guard let raw = raw?.nilIfBlank else { return (nil, nil) }
        let lowered = raw.lowercased()
        if ["me", "i", "myself", "sender"].contains(lowered) { return (asker, asker) }
        if let rosterKey = NameMatcher.match(raw, in: Array(roster.keys)) {
            return (rosterKey, roster[rosterKey])
        }
        if let device = NameMatcher.match(raw, in: knownDevices + [selfName]) {
            return (device, device)
        }
        return (raw, nil)
    }

    // MARK: Entry point

    public func handle(_ rawText: String, from asker: String) async -> AssistantOutcome {
        let started = Date()
        var tracker = CallTracker()
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Plan
        var plan: AssistantPlan
        if let fast = IntentParser.fastPath(text) {
            plan = fast
        } else {
            do {
                let result = try await llm.chat([
                    .system(AssistantPrompts.classify(rules: memory.rules, people: people, openTasks: memory.openTasks)),
                    .user(AssistantPrompts.classifyUser(text: text, asker: asker))
                ], json: true)
                tracker.add(result)
                plan = IntentParser.decodePlan(from: result.text, original: text)
            } catch {
                return failure(error, intent: .answer, started: started, tracker: tracker)
            }
        }

        // 2 and 3. Act, then reply
        var reply = ""
        var taskUpdates: [TaskItem] = []
        var ruleUpdates: [RuleEntry] = []

        switch plan.kind {
        case .more:
            if let rest = pendingMore.removeValue(forKey: asker) {
                return finish(rest, intent: .more, started: started, tracker: tracker, asker: asker)
            }
            reply = "Nothing more to show."

        case .saveRule, .editRule:
            let title = plan.title ?? IntentParser.deriveTitle(from: plan.body ?? text)
            let change = memory.upsertRule(title: title, body: plan.body ?? text, kind: plan.ruleKind, by: asker)
            switch change {
            case .created(let rule):
                reply = "Saved \(rule.citation). Everyone on the mesh gets a copy."
                ruleUpdates.append(rule)
            case .updated(let rule):
                reply = "Updated to \(rule.citation). Older versions are kept in history."
                ruleUpdates.append(rule)
            case .unchanged(let rule):
                reply = "\(rule.citation) already says that."
            case .denied(let why):
                reply = why
            }

        case .lockRule, .unlockRule:
            let lock = plan.kind == .lockRule
            let change = memory.setLocked(title: plan.title ?? text, locked: lock, by: asker)
            switch change {
            case .updated(let rule):
                reply = "\(rule.citation) is now \(lock ? "locked" : "unlocked")."
                ruleUpdates.append(rule)
            case .unchanged(let rule), .created(let rule):
                reply = "\(rule.citation) was already \(lock ? "locked" : "unlocked")."
            case .denied(let why):
                reply = why
            }

        case .addTask:
            let title = IntentParser.deriveTitle(from: plan.taskTitle ?? text)
            let who = resolveAssignee(plan.assignee, asker: asker)
            let task = memory.addTask(title: title, assignee: who.name, assigneeDevice: who.device, due: plan.due, by: asker, source: "ask")
            taskUpdates.append(task)
            var line = "Task added: \(task.shortLine)."
            if let device = who.device, device != asker {
                line += " Sent to \(device)."
            } else if who.name != nil && who.device == nil {
                line += " I do not know \(who.name ?? "them")'s device yet; add them to the roster on the Mac."
            }
            reply = line

        case .listMyTasks:
            let mine = memory.tasks(forDevice: asker, roster: roster)
            reply = mine.isEmpty
                ? "You have no open tasks."
                : "Your tasks (\(mine.count)): " + numbered(mine.map { $0.shortLine })

        case .listTeamTasks:
            let open = memory.openTasks
            reply = open.isEmpty
                ? "The team has no open tasks."
                : "Team tasks (\(open.count)): " + numbered(open.map { $0.shortLine })

        case .markDone:
            let ref = plan.taskRef ?? plan.taskTitle ?? text
            if let task = memory.findOpenTask(matching: ref, preferFor: asker, roster: roster),
               let done = memory.markDone(task.id, by: asker) {
                reply = "Marked done: \(done.title)."
                taskUpdates.append(done)
            } else {
                reply = "I could not tell which task. Open tasks: " + numbered(memory.openTasks.prefix(5).map { $0.title })
            }

        case .summarize:
            let lines = memory.recentChat(limit: chatContextLimit)
            if lines.isEmpty {
                reply = "No team chat has reached me yet."
            } else {
                do {
                    let result = try await llm.chat([
                        .system(AssistantPrompts.summarizeSystem),
                        .user(AssistantPrompts.summarizeUser(lines: lines, asker: asker))
                    ], json: false)
                    tracker.add(result)
                    reply = result.text
                } catch {
                    return failure(error, intent: .summarize, started: started, tracker: tracker)
                }
            }

        case .takeNotes:
            let source = plan.body ?? text
            do {
                let result = try await llm.chat([
                    .system(AssistantPrompts.notesSystem(people: people)),
                    .user(source)
                ], json: true)
                tracker.add(result)
                guard let notes = IntentParser.decodeNotes(from: result.text) else {
                    reply = "I could not find decisions or action items in that."
                    break
                }
                var created: [TaskItem] = []
                for item in notes.actionItems.prefix(12) {
                    let who = resolveAssignee(item.assignee, asker: asker)
                    created.append(memory.addTask(title: IntentParser.deriveTitle(from: item.title), assignee: who.name, assigneeDevice: who.device, due: item.due, by: asker, source: "notes"))
                }
                let note = memory.addNote(title: notes.title, summary: notes.summary, decisions: notes.decisions, taskIDs: created.map { $0.id }, by: asker)
                taskUpdates.append(contentsOf: created)
                var parts = ["Notes saved \(note.citation)."]
                if !notes.decisions.isEmpty { parts.append("Decisions: " + notes.decisions.joined(separator: "; ") + ".") }
                if !created.isEmpty { parts.append("Tasks: " + created.map { $0.shortLine }.joined(separator: "; ") + ".") }
                reply = parts.joined(separator: " ")
            } catch {
                return failure(error, intent: .takeNotes, started: started, tracker: tracker)
            }

        case .answer:
            do {
                let result = try await llm.chat([
                    .system(AssistantPrompts.answerSystem),
                    .user(AssistantPrompts.answerUser(question: plan.question ?? text, asker: asker, rules: memory.rules, notes: memory.notes, openTasks: memory.openTasks))
                ], json: false)
                tracker.add(result)
                reply = result.text.isEmpty ? "I do not have an answer for that." : result.text
            } catch {
                return failure(error, intent: .answer, started: started, tracker: tracker)
            }
        }

        var outcome = finish(reply, intent: plan.kind, started: started, tracker: tracker, asker: asker)
        outcome.taskUpdates = taskUpdates
        outcome.ruleUpdates = ruleUpdates
        return outcome
    }

    // MARK: Helpers

    struct CallTracker {
        var calls = 0
        var model: String?
        var evalCount = 0
        var evalNs: Int64 = 0

        mutating func add(_ result: LLMResult) {
            calls += 1
            model = result.model
            if let c = result.evalCount, let d = result.evalDurationNs {
                evalCount += c
                evalNs += d
            }
        }

        var tokensPerSecond: Double? {
            guard evalNs > 0 else { return nil }
            return Double(evalCount) / (Double(evalNs) / 1_000_000_000)
        }
    }

    private func numbered(_ items: [String]) -> String {
        items.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: " ")
    }

    private func finish(_ text: String, intent: IntentKind, started: Date, tracker: CallTracker, asker: String) -> AssistantOutcome {
        let parts = Compactor.split(text)
        if let rest = parts.rest {
            pendingMore[asker] = rest
        } else {
            pendingMore.removeValue(forKey: asker)
        }
        return AssistantOutcome(
            intent: intent,
            reply: parts.first,
            compact: parts.rest != nil,
            model: tracker.model,
            latencyMs: Int((Date().timeIntervalSince(started) * 1000).rounded()),
            tokensPerSecond: tracker.tokensPerSecond,
            evalCount: tracker.calls > 0 ? tracker.evalCount : nil,
            modelCalls: tracker.calls,
            taskUpdates: [],
            ruleUpdates: [],
            error: nil
        )
    }

    private func failure(_ error: Error, intent: IntentKind, started: Date, tracker: CallTracker) -> AssistantOutcome {
        let message = (error as? LLMError)?.errorDescription ?? error.localizedDescription
        return AssistantOutcome(
            intent: intent,
            reply: message,
            compact: false,
            model: tracker.model,
            latencyMs: Int((Date().timeIntervalSince(started) * 1000).rounded()),
            tokensPerSecond: tracker.tokensPerSecond,
            evalCount: nil,
            modelCalls: tracker.calls,
            taskUpdates: [],
            ruleUpdates: [],
            error: message
        )
    }
}
