// RuleGlossTests.swift: cross-language rule retrieval through glosses (issue #8). Fake model only.
import Foundation

@MainActor
func runRuleGlossTests() async {
    let mem = OrgMemory(admins: ["Mac"])
    _ = mem.upsertRule(title: "Bawal manigarilyo sa bodega", body: "Bawal manigarilyo sa loob at malapit sa bodega ng semento at pintura.", by: "Mac")
    _ = mem.upsertRule(title: "Cement orders before Thursday", body: "Cement orders go to the supplier before Thursday noon.", by: "Mac")
    let smoking = mem.rules.first { $0.title.hasPrefix("Bawal") }!
    let question = "Is smoking allowed near the cement and paint storage?"

    // Without a gloss the English question cannot reach the Tagalog rule (the old miss).
    let before = KnowledgeRetriever.select(question: question, rules: mem.rules, notes: [], glosses: mem.glossMap)
    check(before.rules.first?.title == "Cement orders before Thursday", "rule gloss: without a gloss the Tagalog rule ranks below a cement rule")

    // The local model glosses rules once (fake model here); the rule now ranks first.
    let fake = FakeLLM([.success(#"{"en": "No smoking in or near the cement and paint storage room", "tl": "Bawal manigarilyo sa loob at malapit sa bodega ng semento at pintura"}"#),
                        .success(#"{"en": "Order cement before Thursday noon", "tl": "Mag-order ng semento bago mag-Huwebes ng tanghali"}"#)])
    let added = await RuleGlosser.glossMissing(in: mem, llm: fake)
    check(added == 2 && mem.rulesNeedingGloss.isEmpty, "rule gloss: every rule glossed once")
    check(mem.gloss(for: smoking)?.hasPrefix("No smoking in or near") == true && mem.gloss(for: smoking)?.contains(" | Bawal") == true,
          "rule gloss: English and Tagalog kept together")
    check(fake.received.first?.first?.content.contains("JSON only") == true && fake.received.first?.last?.content.contains("Title: ") == true,
          "rule gloss: prompt asks for JSON and gives the rule")
    let after = KnowledgeRetriever.select(question: question, rules: mem.rules, notes: [], glosses: mem.glossMap)
    check(after.rules.first?.title == "Bawal manigarilyo sa bodega" && after.strongCount >= 1, "rule gloss: the English question now finds the Tagalog rule first")
    let tagalog = KnowledgeRetriever.select(question: "Kailan mag-order ng semento?", rules: mem.rules, notes: [], glosses: mem.glossMap)
    check(tagalog.rules.first?.title == "Cement orders before Thursday", "rule gloss: works the other way too (Tagalog question, English rule)")
    let unrelated = KnowledgeRetriever.select(question: "What is the Wi-Fi password?", rules: mem.rules, notes: [], glosses: mem.glossMap)
    check(unrelated.strongCount == 0, "rule gloss: an unrelated question still matches nothing strongly")

    // Benchmark #19 (Oct 12 regression): a gloss that shares one word with the question
    // ("foreman") must stay a weak match, or the model cites a rule for a question no rule covers.
    let site = OrgMemory(admins: ["Mac"])
    _ = site.upsertRule(title: "No site visits after 5 PM", body: "After 5 PM nobody enters the site without the foreman.", by: "Mac")
    site.setGloss("No site visits after 5 PM without the foreman | Bawal pumasok sa site pagkalipas ng 5 PM nang walang foreman", for: site.rules[0])
    let color = KnowledgeRetriever.select(question: "Ano ang paboritong kulay ng foreman?", rules: site.rules, notes: [], glosses: site.glossMap)
    check(color.strongCount == 0, "rule gloss: one shared gloss word stays weak (benchmark #19)")

    // An edit makes a new version: its gloss is redone and the old one dropped.
    _ = mem.upsertRule(title: "Cement orders before Thursday", body: "Cement orders go to the supplier before Wednesday noon.", by: "Mac")
    check(mem.rulesNeedingGloss.map(\.title) == ["Cement orders before Thursday"], "rule gloss: an edited rule needs a new gloss")

    // Bad replies leave the rule unglossed (tried again later); the limit holds.
    let broken = FakeLLM([.success("not json"), .failure(.timeout)])
    check(await RuleGlosser.glossMissing(in: mem, llm: broken, limit: 1) == 0 && broken.remaining == 1, "rule gloss: bad reply skipped, limit respected")

    // Memory files from before this change still load.
    let old = #"{"schemaVersion":1,"rules":[],"tasks":[],"notes":[],"chatLog":[]}"#
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    check((try? d.decode(OrgSnapshot.self, from: Data(old.utf8)))?.ruleGlosses == nil, "rule gloss: older memory files decode")
}
