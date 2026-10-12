// RuleGlosser.swift
// Libre: cross-language rule retrieval (issue #8, Oct 2026). Our own design.
//
// Keyword search cannot match "smoking" to "manigarilyo". So when a rule is saved, the AI Mac asks
// its local model once for a short English and Tagalog wording of the rule, and keeps it next to
// the rule (OrgMemory.ruleGlosses). Retrieval counts those words like title words. This works for
// any rule and any language the model knows; there is no word list for particular questions. The
// gloss is only for finding rules: the model still answers from the rule's own text, and the
// citation guard still checks the rule's real title.

import Foundation

public enum RuleGlosser {
    public static let system = """
    You help a search index. Given one team rule, reply with JSON only: {"en": "...", "tl": "..."}.
    "en": the rule's title and main point in plain English. "tl": the same in Tagalog.
    At most 20 words each. Keep names, numbers, times and places. Do not add facts that are not in the rule.
    """
    public static let maxTokens = 160

    struct Reply: Decodable { var en: String?; var tl: String? }

    /// One rule's gloss ("English | Tagalog"), or nil when the model failed or replied badly.
    public static func gloss(_ rule: RuleEntry, llm: any LLMClient) async -> String? {
        let turns = [ChatTurn(role: "system", content: system),
                     ChatTurn(role: "user", content: "Title: \(rule.title)\nRule: \(String(rule.body.prefix(600)))")]
        guard let result = try? await llm.chat(turns, json: true, maxTokens: maxTokens),
              let data = result.text.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        let parts = [reply.en, reply.tl].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: " | ").prefix(400))
    }

    /// Glosses up to `limit` rules that have none for their current version. Returns how many were
    /// added. Main actor, so the memory is only changed where the app reads it.
    @MainActor @discardableResult
    public static func glossMissing(in memory: OrgMemory, llm: any LLMClient, limit: Int = 50) async -> Int {
        var added = 0
        for rule in memory.rulesNeedingGloss.prefix(limit) {
            if let text = await gloss(rule, llm: llm) {
                memory.setGloss(text, for: rule)
                added += 1
            }
        }
        return added
    }
}
