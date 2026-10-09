// AssistantTests.swift: ExecutiveAssistant end to end with a scripted fake model.

import Foundation

final class FakeLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<String, LLMError>]
    private var _received: [[ChatTurn]] = []

    init(_ script: [Result<String, LLMError>]) { self.script = script }

    var modelName: String { "fake:1b" }

    var received: [[ChatTurn]] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    var remaining: Int {
        lock.lock(); defer { lock.unlock() }
        return script.count
    }

    private func pop(_ messages: [ChatTurn]) -> Result<String, LLMError> {
        lock.lock(); defer { lock.unlock() }
        _received.append(messages)
        return script.isEmpty ? .failure(.badResponse("script empty")) : script.removeFirst()
    }

    func chat(_ messages: [ChatTurn], json: Bool) async throws -> LLMResult {
        switch pop(messages) {
        case .success(let text):
            return LLMResult(text: text, model: "fake:1b", evalCount: 50, evalDurationNs: 1_000_000_000)
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
func runAssistantTests() async {
    func makeAssistant(_ script: [Result<String, LLMError>], memory: OrgMemory? = nil) -> (ExecutiveAssistant, FakeLLM) {
        let fake = FakeLLM(script)
        let mem = memory ?? OrgMemory(admins: ["MacBook Air", "iPhone 14 Pro Max"])
        let assistant = ExecutiveAssistant(memory: mem, llm: fake, selfName: "MacBook Air",
                                           roster: ["Ana": "iPhone 12"], knownDevices: ["iPhone 12", "iPhone 14 Pro Max"])
        return (assistant, fake)
    }

    // Add task: one JSON call, assignee resolved through the roster.
    do {
        let (a, fake) = makeAssistant([.success(#"{"intent":"add_task","task_title":"order cement","assignee":"Ana","due":"Friday"}"#)])
        let out = await a.handle("remind Ana to order cement Friday", from: "iPhone 14 Pro Max")
        check(out.intent == .addTask && out.taskUpdates.count == 1, "task created")
        check(out.taskUpdates.first?.assigneeDevice == "iPhone 12" && out.taskUpdates.first?.title == "Order cement", "task routed to Ana's device")
        check(out.reply.contains("Order cement") && out.reply.contains("Sent to iPhone 12"), "task reply")
        check(out.model == "fake:1b" && out.modelCalls == 1 && out.tokensPerSecond == 50, "model stats recorded")
        check(fake.received.first?.first?.content.contains("Ana") == true, "classifier prompt lists roster names")

        // My tasks for iPhone 12, no model call.
        let mine = await a.handle("my tasks", from: "iPhone 12")
        check(mine.reply.contains("Order cement") && mine.modelCalls == 0 && mine.model == nil, "my tasks via fast path")

        // Mark done via the model.
        let (b, _) = makeAssistant([.success(#"{"intent":"mark_done","task_ref":"cement"}"#)], memory: a.memory)
        let done = await b.handle("cement is ordered", from: "iPhone 12")
        check(done.taskUpdates.first?.status == .done && done.reply.hasPrefix("Marked done"), "mark done")
        check(a.memory.openTasks.isEmpty, "no open tasks left")
    }

    // Rules: fast path save (no model), non-admin edit denied, admin edit versioned.
    do {
        let (a, fake) = makeAssistant([])
        let saved = await a.handle("save rule: No site visits after 5 PM", from: "iPhone 12")
        check(saved.modelCalls == 0 && saved.ruleUpdates.count == 1 && saved.rulesUsed == ["[Rule: No site visits after 5 PM v1]"] && !saved.reply.contains("[Rule"), "rule saved without a model call (chip, no tag)")
        check(fake.received.isEmpty, "no model used for save rule")
        let denied = await a.handle("update rule No site visits after 5 PM: after 6 PM is fine", from: "iPhone 12")
        check(denied.ruleUpdates.isEmpty && denied.reply.contains("Only an admin"), "non-admin edit denied")
        let edited = await a.handle("update rule No site visits after 5 PM: No site visits after 6 PM", from: "iPhone 14 Pro Max")
        check(edited.ruleUpdates.first?.version == 2 && edited.rulesUsed.first?.contains("v2") == true, "admin edit makes v2")
        let locked = await a.handle("lock rule No site visits after 5 PM", from: "MacBook Air")
        check(locked.ruleUpdates.first?.locked == true, "Mac locks rule")
    }

    // Grounded answer with citation.
    do {
        let mem = OrgMemory(admins: ["MacBook Air"])
        _ = mem.upsertRule(title: "No site visits after 5 PM", body: "No site visits after 5 PM.", by: "MacBook Air")
        let (a, fake) = makeAssistant([
            .success("No. Site visits end at 5 PM [Rule: No site visits after 5 PM v1].")
        ], memory: mem)
        let out = await a.handle("can I visit the site at 6 PM?", from: "iPhone 12")
        check(out.intent == .answer && out.rulesUsed == ["[Rule: No site visits after 5 PM v1]"] && out.reply == "No. Site visits end at 5 PM.", "answer cites rule as a chip: \(out.reply)")
        check(out.modelCalls == 1 && out.compact == false, "plain question: one call, not compact")
        let composePrompt = fake.received.last?.last?.content ?? ""
        check(composePrompt.contains("[Rule: No site visits after 5 PM v1]") && composePrompt.contains("can I visit the site at 6 PM?"), "compose prompt is grounded in rules")
    }

    // Long answer is compacted; "more" returns the rest with no model call.
    do {
        let long = String(repeating: "Pour concrete early while it is cool and keep it wet for a week. ", count: 12)
        let (a, fake) = makeAssistant([.success(long)])
        let first = await a.handle("how do I cure concrete in hot weather?", from: "iPhone 12")
        check(first.compact && first.reply.count <= Compactor.firstPacketLimit, "first packet compact")
        let more = await a.handle("more", from: "iPhone 12")
        check(more.intent == .more && more.modelCalls == 0 && !more.reply.isEmpty, "more returns rest")
        check(fake.remaining == 0, "script consumed")
        var ended = !more.compact
        for _ in 0..<5 where !ended {
            let next = await a.handle("more", from: "iPhone 12")
            ended = next.reply == "Nothing more to show." || next.compact == false
        }
        check(ended, "more eventually ends")
    }

    // Summarize from the chat log.
    do {
        let (a, fake) = makeAssistant([.success("- Ana: cement arrives Friday\n- Ben: generator fixed")])
        a.memory.recordChat(from: "iPhone 12", text: "cement arrives Friday")
        a.memory.recordChat(from: "iPhone 14 Pro Max", text: "generator fixed")
        let out = await a.handle("what did I miss?", from: "MacBook Air")
        check(out.intent == .summarize && out.reply.contains("generator"), "summary reply")
        check(fake.received.first?.last?.content.contains("cement arrives Friday") == true, "summary prompt includes chat log")
        let (empty, _) = makeAssistant([])
        let none = await empty.handle("what did I miss", from: "iPhone 12")
        check(none.reply.contains("No team chat") && none.modelCalls == 0, "empty chat log needs no model")
    }

    // Notes from a transcript create tasks and a note.
    do {
        let transcript = "notes: Monday huddle. We agreed to pour on Tuesday. Ana will order cement by Friday. Someone should call the supplier."
        let (a, _) = makeAssistant([.success(#"{"title":"Monday huddle","summary":"Pour moved to Tuesday.","decisions":["Pour on Tuesday"],"action_items":[{"title":"order cement","assignee":"Ana","due":"Friday"},{"title":"call the supplier","assignee":"","due":""}]}"#)])
        let out = await a.handle(transcript, from: "iPhone 14 Pro Max")
        check(out.intent == .takeNotes && out.taskUpdates.count == 2, "notes create two tasks")
        check(a.memory.notes.first?.title == "Monday huddle" && a.memory.notes.first?.taskIDs.count == 2, "note saved with task links")
        check(out.taskUpdates.first?.assigneeDevice == "iPhone 12", "note task routed to Ana")
        check(out.rulesUsed == ["[Note: Monday huddle]"] && out.reply.contains("Pour on Tuesday"), "notes reply")
    }

    // Ollama not running: clear message, no crash.
    do {
        let (a, _) = makeAssistant([.failure(.notRunning)])
        let out = await a.handle("is the pour still on?", from: "iPhone 12")
        check(out.error != nil && out.reply.hasPrefix("Start Ollama on the Mac"), "not running message")
        let (b, _) = makeAssistant([.failure(.modelMissing("qwen3:8b"))])
        let missing = await b.handle("hello there", from: "iPhone 12")
        check(missing.reply.contains("ollama pull qwen3:8b"), "missing model message")
    }

    // Assignee "me" and unknown people.
    do {
        let (a, _) = makeAssistant([
            .success(#"{"intent":"add_task","task_title":"check rebar","assignee":"me"}"#),
            .success(#"{"intent":"add_task","task_title":"bring ladder","assignee":"Carlo"}"#)
        ])
        let me = await a.handle("remind me to check rebar", from: "iPhone 14 Pro Max")
        check(me.taskUpdates.first?.assigneeDevice == "iPhone 14 Pro Max", "me means the sender")
        let unknown = await a.handle("Carlo brings the ladder", from: "iPhone 14 Pro Max")
        check(unknown.taskUpdates.first?.assigneeDevice == nil && unknown.reply.contains("roster"), "unknown person kept, hint to add roster")
    }
}
