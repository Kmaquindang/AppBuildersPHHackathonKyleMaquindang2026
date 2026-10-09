// ConversationTests.swift: conversation threading, compaction and recall on the AI Mac (fake model).

import Foundation

@MainActor
func runConversationTests() async {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Manila")!
    let t0 = Date(timeIntervalSince1970: 1_791_549_180)   // Fri Oct 9 2026, 8:33 PM Manila
    var clock = t0

    // 1. Follow-up: the second prompt carries the first question and answer verbatim.
    let mem = OrgMemory(admins: ["Mac"])
    _ = mem.upsertRule(title: "Saturday site hours", body: "Site is open 8 AM to 12 noon on Saturday.", by: "Mac")
    let fake = FakeLLM([.success("Saturday is 8 AM to 12 noon. [Rule: Saturday site hours v1]"), .success("Sunday the site is closed.")])
    let a = ExecutiveAssistant(memory: mem, llm: fake, selfName: "Mac")
    a.directory = ["PHONE_K": "Kyle"]
    a.calendar = cal
    a.now = { clock }
    a.serve(room: "R1", memory: mem, clearedAt: nil)
    let firstID = UUID()
    let first = await a.handle("what are the site hours on Saturday?", from: "PHONE_K", askID: firstID)
    check(first.intent == .answer && mem.threadTurns.count == 1 && mem.threadTurns[0].id == firstID, "thread: first exchange saved with the ask id")
    clock = t0 + 30
    _ = await a.handle("and Sunday?", from: "PHONE_K")
    let followUp = fake.received.last?.last?.content ?? ""
    check(followUp.contains("<conversation>") && followUp.contains("Kyle: what are the site hours on Saturday?")
          && followUp.contains("Pasa: Saturday is 8 AM to 12 noon."), "thread: follow-up prompt carries the prior turn")
    check(followUp.contains("Question from PHONE_K: and Sunday?") && followUp.contains("[Rule: Saturday site hours v1]"), "thread: rules still retrieved fresh beside the thread")
    check(AssistantPrompts.answerSystem.contains("and Sunday?") && AssistantPrompts.answerSystem.contains("team knowledge wins"), "thread: system prompt explains follow-ups, knowledge wins")
    check(mem.threadTurns.count == 2 && a.contextStats["R1"]?.verbatimTurns == 1, "thread: stats count verbatim turns")

    // Verbatim window: newest 12, plus the asker's own last turns.
    var many: [ThreadTurn] = []
    for i in 0..<20 { many.append(ThreadTurn(id: UUID(), asker: i == 2 ? "PHONE_A" : "PHONE_K", askerName: "x", question: "q\(i)", answer: "a\(i)", at: t0 + Double(i))) }
    let window = ConversationMemory.verbatim(many, asker: "PHONE_A")
    check(window.count == 13 && window.first?.question == "q2" && window.last?.question == "q19", "thread: 12 newest plus the asker's own older turn")

    // 2. Compaction at 75% of num_ctx: one model call, summary stored, rules and tasks untouched.
    let mem2 = OrgMemory(admins: ["Mac"])
    _ = mem2.upsertRule(title: "No site visits after 5 PM", body: "Site visits end at 5 PM.", by: "Mac")
    _ = mem2.addTask(title: "Order cement", assignee: "Ana", assigneeDevice: "PHONE_A", due: nil, by: "Mac", source: "ask")
    let long = String(repeating: "concrete pour schedule detail ", count: 12)
    for i in 0..<10 {
        mem2.recordTurn(ThreadTurn(id: UUID(), asker: "PHONE_K", askerName: "Kyle", question: "pour question \(i) \(long)", answer: "pour answer \(i) \(long)", at: t0 + Double(i)))
    }
    let rulesBefore = mem2.snapshot.rules
    let tasksBefore = mem2.snapshot.tasks
    let fake2 = FakeLLM([.success("- Kyle asked about the pour schedule many times. [Rule: No site visits after 5 PM v1]\n# Heading"), .success("Yes.")])
    let b = ExecutiveAssistant(memory: mem2, llm: fake2, selfName: "Mac")
    b.calendar = cal
    b.now = { t0 + 100 }
    b.contextTokens = 2000   // small window so 10 long turns cross 75%
    b.serve(room: "R2", memory: mem2, clearedAt: nil)
    let out = await b.handle("is the pour still on?", from: "PHONE_K")
    let summary = mem2.roomSummary
    check(fake2.received.count == 2 && (fake2.received.first?.first?.content ?? "").contains("running summary"), "compaction: one summary call before the answer")
    check(out.modelCalls == 2, "compaction: the summary call is counted")
    check(summary?.turnCount == 6 && summary?.text == "- Kyle asked about the pour schedule many times.", "compaction: oldest 6 turns folded, tags and headings stripped (\(summary?.text ?? "nil"))")
    check(summary?.lastTurn == mem2.threadTurns[5].id && summary?.firstTurn == mem2.threadTurns[0].id && summary?.updatedAt == t0 + 100, "compaction: covered range and time stored")
    let answerPrompt = fake2.received.last?.last?.content ?? ""
    check(answerPrompt.contains("Room so far (summary): - Kyle asked about the pour schedule") && !answerPrompt.contains("pour question 0 "), "compaction: answer prompt uses the summary, not the folded turns")
    check(answerPrompt.contains("pour question 9") && answerPrompt.contains("Order cement") == false, "compaction: newest turns in the prompt (task list only for task questions)")
    check(mem2.snapshot.rules == rulesBefore && mem2.snapshot.tasks == tasksBefore, "compaction: rules and tasks unchanged")
    check(mem2.threadTurns.count == 11, "compaction: no turn deleted (10 old + the new one)")
    check(b.contextStats["R2"]?.lastCompaction == t0 + 100 && (b.contextStats["R2"]?.summaryTokens ?? 0) > 0, "compaction: stats show time and summary size")
    check(ConversationMemory.needsCompaction(promptTokens: 6200) && !ConversationMemory.needsCompaction(promptTokens: 6000), "compaction: threshold is 75% of 8192")
    check(ConversationMemory.uncovered(mem2.threadTurns, summary: summary).count == 5, "compaction: 5 turns left uncovered")

    // Below threshold: no summary call.
    let fake3 = FakeLLM([.success("Yes.")])
    let c = ExecutiveAssistant(memory: OrgMemory(), llm: fake3, selfName: "Mac")
    _ = await c.handle("is it ok?", from: "PHONE_K")
    check(fake3.received.count == 1, "compaction: not triggered under the threshold")

    // 3. Recall of older lines (keywords and dates), never deleted chat.
    let mem3 = OrgMemory()
    mem3.maxChatLog = 3
    mem3.recordChat(from: "Ana", text: "The scaffolding inspector comes Thursday at 9", at: t0 - 86_400)
    mem3.recordChat(from: "Ben", text: "Lunch is adobo", at: t0 - 80_000)
    for i in 0..<4 { mem3.recordChat(from: "Kyle", text: "ok \(i)", at: t0 - 1000 + Double(i)) }
    check(mem3.snapshot.chatLog.count == 3 && mem3.archivedChat().count == 3, "recall: trimmed chat goes to the archive, not lost")
    let fake4 = FakeLLM([.success("Thursday at 9.")])
    let d = ExecutiveAssistant(memory: mem3, llm: fake4, selfName: "Mac")
    d.calendar = cal
    d.now = { t0 }
    _ = await d.handle("when does the scaffolding inspector come?", from: "PHONE_K")
    let recallPrompt = fake4.received.last?.last?.content ?? ""
    check(recallPrompt.contains("Older lines that match the question:") && recallPrompt.contains("Ana: The scaffolding inspector comes Thursday at 9"), "recall: archived line comes back into the prompt")
    check(!recallPrompt.contains("Lunch is adobo"), "recall: unrelated lines stay out")
    let byDay = ConversationMemory.recall(question: "what did Ben say yesterday?", chat: mem3.archivedChat(), olderTurns: [], now: t0, calendar: cal)
    check(byDay.contains { $0.contains("Lunch is adobo") }, "recall: 'yesterday' finds that day's lines")
    let cleared = ConversationMemory.recall(question: "scaffolding inspector", chat: mem3.archivedChat(), olderTurns: [], now: t0, calendar: cal, clearedAt: t0 - 2000)
    check(cleared.isEmpty, "recall: respects the clear watermark")
    let budgeted = ConversationMemory.recall(question: "pour", chat: (0..<50).map { ChatLogLine(from: "K", text: "pour \($0) " + long, at: t0 + Double($0)) }, olderTurns: [], now: t0, calendar: cal)
    check(budgeted.count <= ConversationMemory.maxRecalled && budgeted.reduce(0) { $0 + PromptBudget.tokens($1) } <= ConversationMemory.recallTokens, "recall: within the line and token budget")
    check(ConversationMemory.cleanSummary("[Rule: X v1] - a\n\n# h\n- b") == "- a\n- b", "summary cleanup")

    // Old memory files (no thread fields) still decode.
    let oldJSON = #"{"schemaVersion":1,"rules":[],"tasks":[],"notes":[],"chatLog":[]}"#
    check((try? OrgMemory.decodeBackup(Data(oldJSON.utf8))) != nil, "thread: older memory files still load")
}

func runFollowUpQueryTests() {
    let prev = ThreadTurn(id: UUID(), asker: "K", askerName: "Kyle", question: "site hours on Saturday?", answer: "8 to 12", at: Date())
    check(ConversationMemory.retrievalQuery("and Sunday?", previous: prev).contains("Saturday"), "follow-up: 'and Sunday?' borrows the last question")
    check(ConversationMemory.retrievalQuery("how should I handle rebar?", previous: prev) == "how should I handle rebar?", "follow-up: a new question stays as is")
}
