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

    // 5. Language hint.
    check(LanguageHint.detect("Pwede ba akong pumunta sa site ng alas sais ng gabi?") == "Tagalog", "qa: Tagalog detected")
    check(LanguageHint.detect("Pwede ba ko moadto sa site alas sais sa gabii?") == "Cebuano (Bisaya)", "qa: Cebuano detected")
    check(LanguageHint.detect("Kinsa ang mo-order sa semento?") == "Cebuano (Bisaya)", "qa: Cebuano kinsa")
    for q in ["Can I visit the site at 6 PM?", "10+69", "What is the capital of Japan?", "and Sunday?", "Pwede ba?", "May I go now?", "Is the man at the gate?"] {
        check(LanguageHint.detect(q) == nil, "qa: no hint for \(q)")
    }
    for q in BenchmarkSuite.questions {
        let d = LanguageHint.detect(q.text)
        switch q.language {
        case "en": check(d == nil, "qa: benchmark #\(q.id) English gets no hint (\(d ?? "-"))")
        case "tl": check(d != "Cebuano (Bisaya)", "qa: benchmark #\(q.id) Tagalog never hinted Cebuano")
        case "ceb": check(d != "Tagalog", "qa: benchmark #\(q.id) Cebuano never hinted Tagalog")
        default: break
        }
    }
    do {
        let llm = FakeLLM([.success("Hindi, hanggang 5 PM lang. [Rule: No site visits after 5 PM v1]")])
        let a = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Mac")
        _ = await a.handle("Pwede ba akong pumunta sa site ng alas sais ng gabi?", from: "PHONE_A")
        let prompt = llm.received.last?.last?.content ?? ""
        check(prompt.contains("the question is in Tagalog. Reply in Tagalog."), "qa: answer prompt carries the Tagalog hint")
        let llm2 = FakeLLM([.success("79.")])
        let b = ExecutiveAssistant(memory: mem, llm: llm2, selfName: "Mac")
        _ = await b.handle("10+69", from: "PHONE_A")
        check(!(llm2.received.last?.last?.content ?? "").contains("the question is in"), "qa: no hint for English")
    }
}
