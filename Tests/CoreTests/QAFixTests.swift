// QAFixTests.swift: bugs found by the feature-freeze QA run on the real model (Oct 9, 2026, 9:30 PM PHT).

import Foundation

@MainActor
func runQAFixTests() async {
    let mem = OrgMemory(admins: ["Mac"])
    _ = mem.upsertRule(title: "No site visits after 5 PM", body: "Site visits end at 5 PM.", by: "Mac")
    _ = mem.upsertRule(title: "Hard hats inside the fence", body: "Everyone wears a hard hat inside the fence.", by: "Mac")

    // 1. A plain answer must not carry the prompt's example rule as a chip ("79." + "No site visits after 5 PM").
    do {
        let llm = FakeLLM([.success("79. [Rule: No site visits after 5 PM v2]")])
        let a = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Mac")
        let out = await a.handle("10+69", from: "PHONE_A")
        check(out.reply == "79." && out.rulesUsed.isEmpty && out.unverifiedRules.isEmpty && out.noRule == true,
              "qa: copied example citation on a math answer is dropped: \(out.reply) \(out.rulesUsed)")
    }
    // 2. Placeholder echoes and invented tags with nothing shown: no warning chip.
    do {
        let llm = FakeLLM([.success("The capital of Japan is Tokyo. [Rule: General knowledge v1]"),
                           .success("I can't get live info while offline. [Note: no saved rule or note matched this question]")])
        let a = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Mac")
        let cap = await a.handle("What is the capital of Japan?", from: "PHONE_A")
        check(cap.reply == "The capital of Japan is Tokyo." && cap.unverifiedRules.isEmpty && cap.rulesUsed.isEmpty, "qa: invented tag on a general answer is not a chip")
        let w = await a.handle("What is the weather in Tagbilaran today?", from: "PHONE_A")
        check(w.unverifiedRules.isEmpty && w.rulesUsed.isEmpty && w.noRule == true && !w.reply.contains("["), "qa: placeholder echo is not a chip: \(w.reply)")
    }
    // 3. A rule the model was shown still becomes a chip; an invented one next to it stays a warning.
    do {
        let llm = FakeLLM([.success("No, visits end at 5 PM. [Rule: No site visits after 5 PM v1] [Rule: Night shift allowed v1]")])
        let a = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Mac")
        let out = await a.handle("Can I visit the site at 6 PM?", from: "PHONE_A")
        check(out.rulesUsed == ["[Rule: No site visits after 5 PM v1]"] && out.unverifiedRules == ["[Rule: Night shift allowed v1]"] && out.noRule == false,
              "qa: shown rule kept, invented one stays a warning: \(out.rulesUsed) \(out.unverifiedRules)")
    }
    // 4. A saved rule that was not shown (not relevant to the question) is dropped.
    do {
        let styled = AnswerStyle.restrict(AnswerStyle.style("Wear one. [Rule: Hard hats inside the fence v1] [Rule: No site visits after 5 PM v1]", rules: mem.rules, notes: []),
                                          shown: ["Hard hats inside the fence"])
        check(styled.rulesUsed == ["[Rule: Hard hats inside the fence v1]"] && !styled.noRule, "qa: restrict keeps only shown titles")
        let empty = AnswerStyle.restrict(AnswerStyle.style("[Rule: No site visits after 5 PM v1]", rules: mem.rules, notes: []), shown: [])
        check(empty.text == AnswerStyle.noRuleFallback && empty.noRule, "qa: tag-only reply with nothing shown reads as no rule: \(empty.text)")
    }

    // 6. Arithmetic is never a follow-up: "10+69" after a rule question borrows nothing.
    do {
        let prev = ThreadTurn(id: UUID(), asker: "PHONE_A", askerName: "Kyle", question: "What time do site visits end?", answer: "5 PM.", at: Date())
        check(ConversationMemory.retrievalQuery("10+69", previous: prev) == "10+69", "qa: arithmetic does not borrow the previous question")
        check(ConversationMemory.retrievalQuery("and Sunday?", previous: prev).contains("site visits"), "qa: real follow-up still borrows")
        let llm = FakeLLM([.success("Site visits end at 5 PM. [Rule: No site visits after 5 PM v1]"), .success("79. [Rule: No site visits after 5 PM v1]")])
        let a = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Mac")
        let first = await a.handle("What time do site visits end?", from: "PHONE_A")
        let math = await a.handle("10+69", from: "PHONE_A")
        check(first.rulesUsed.count == 1 && math.reply == "79." && math.rulesUsed.isEmpty && math.noRule == true, "qa: math after a rule question has no chip: \(math.rulesUsed)")
    }
}

/// Mac crash follow-up (Oct 9, 9:25 PM PHT report): the Mac never restarts a quiet mesh.
func runMacStaleRestartTests() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var mac = DiscoveryRestartPolicy(allowsStaleRestart: false)
    _ = mac.begin(now: t0)
    let later = t0.addingTimeInterval(3_600)
    check(!mac.isStale(linked: 0, discovered: 0, lastFound: .distantPast, now: later), "qa: Mac policy never reports a stale mesh, even after an hour alone")
    check(mac.request(.wake, now: later) == .stop(settle: DiscoveryRestartPolicy.settleDelay), "qa: Mac still restarts once after wake")
    var phone = DiscoveryRestartPolicy()
    _ = phone.begin(now: t0)
    check(phone.isStale(linked: 0, discovered: 0, lastFound: .distantPast, now: t0.addingTimeInterval(121)), "qa: phone policy still restarts a stale mesh")
    check(!phone.isStale(linked: 1, discovered: 0, lastFound: .distantPast, now: t0.addingTimeInterval(121)), "qa: never stale with a link")
}
