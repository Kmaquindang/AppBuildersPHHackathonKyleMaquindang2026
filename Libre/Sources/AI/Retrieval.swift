// Retrieval.swift
// Pasa: keeps prompts small and grounded for a small local model. Pure Swift, tested on Linux.
// - KnowledgeRetriever picks only the rules and notes relevant to the question (BM25-style
//   keyword scoring, title words count double). Admin-locked rules are always included.
// - PromptBudget estimates tokens (about 4 characters per token), trims chat to a budget and
//   flags prompts above 80% of the model context window.

import Foundation

public enum PromptBudget {
    /// Context window Pasa asks Ollama for (options.num_ctx).
    public static let contextTokens = 8192
    public static let warnFraction = 0.8
    /// Budget for team knowledge in an answer prompt, and for chat in a catch-up prompt.
    public static let knowledgeTokens = 2500
    public static let chatTokens = 3000

    /// Rough token estimate: about 4 characters per token for English and Tagalog text.
    public static func tokens(_ text: String) -> Int { (text.count + 3) / 4 }

    public static func tokens(_ turns: [ChatTurn]) -> Int {
        turns.reduce(0) { $0 + tokens($1.content) + 4 }
    }

    public static func isNearLimit(_ tokens: Int, context: Int = contextTokens) -> Bool {
        Double(tokens) > Double(context) * warnFraction
    }

    /// Newest chat lines that fit in the budget, oldest first.
    public static func trimChat(_ lines: [ChatLogLine], budgetTokens: Int = chatTokens) -> [ChatLogLine] {
        var kept: [ChatLogLine] = []
        var used = 0
        for line in lines.reversed() {
            let cost = tokens(line.from) + tokens(String(line.text.prefix(300))) + 4
            if used + cost > budgetTokens { break }
            used += cost
            kept.append(line)
        }
        return kept.reversed()
    }
}

public enum KnowledgeRetriever {
    public struct Selection: Equatable, Sendable {
        /// Rules to put in the prompt: locked rules first, then the most relevant.
        public var rules: [RuleEntry]
        public var notes: [Note]
        /// Rules or notes whose words actually match the question (locked rules only count if they match).
        public var relevantCount: Int
        /// Titles of every rule and note the model was shown ("checked").
        public var checkedTitles: [String]
        /// Shown rules or notes that match strongly: a title word, or at least two different question
        /// words. A lone body word ("foreman") is a weak match (benchmark #19, Oct 9, 2026).
        public var strongCount: Int = 0
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "am", "be", "to", "of", "and", "or", "in", "on", "at", "for", "with",
        "can", "i", "we", "you", "it", "do", "does", "did", "what", "when", "where", "who", "how", "why",
        "my", "our", "your", "this", "that", "there", "after", "before", "about", "should", "would", "could",
        "please", "pasa", "libre", "rule", "rules", "any", "if", "me", "us", "allowed", "ok", "okay", "pm", "am",
        "ang", "ng", "sa", "ba", "na", "po", "ko", "mo", "ka", "ako", "kami", "tayo", "si", "ni", "kay", "mga",
        "ano", "pwede", "puwede", "ba", "lang", "naman", "ug", "nga", "ang", "unsa", "pila"
    ]

    /// Normalized content words with a light plural strip ("visits" -> "visit").
    public static func terms(_ text: String) -> [String] {
        NameMatcher.normalize(text).split(separator: " ").map { word -> String in
            var w = String(word)
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            return w
        }.filter { !$0.isEmpty && $0.count > 1 && !stopwords.contains($0) && !$0.allSatisfy(\.isNumber) }   // bare numbers ("6") match too much
    }

    /// BM25-style score of one document for the query terms.
    static func score(query: [String], title: [String], body: [String], df: [String: Int], docs: Int) -> Double {
        let words = title + title + body   // title words count double
        guard !words.isEmpty else { return 0 }
        var tf: [String: Int] = [:]
        for w in words { tf[w, default: 0] += 1 }
        let k1 = 1.2
        var total = 0.0
        for term in Set(query) {
            guard let f = tf[term] else { continue }
            let n = Double(df[term] ?? 0)
            let idf = log(1 + (Double(docs) - n + 0.5) / (n + 0.5))
            total += idf * (Double(f) * (k1 + 1)) / (Double(f) + k1)
        }
        return total
    }

    /// - Parameter glosses: rule id -> the local model's short English and Tagalog wording of the
    ///   rule (RuleGlosser, issue #8), so a question in one language finds a rule written in
    ///   another. Its words count like body words: a lone shared word stays a weak match (a gloss
    ///   counted like a title made "foreman" strong and broke benchmark #19 in two runs, Oct 12).
    public static func select(question: String, rules allRules: [RuleEntry], notes: [Note],
                              maxRules: Int = 8, maxNotes: Int = 3,
                              budgetTokens: Int = PromptBudget.knowledgeTokens,
                              glosses: [UUID: String] = [:]) -> Selection {
        let rules = allRules.filter { !$0.isRetired }
        let query = terms(question)
        let ruleDocs = rules.map { (terms($0.title), terms($0.body) + terms(glosses[$0.id] ?? "")) }
        let noteDocs = notes.map { (terms($0.title), terms($0.summary + " " + $0.decisions.joined(separator: " "))) }
        var df: [String: Int] = [:]
        for doc in ruleDocs + noteDocs { for t in Set(doc.0 + doc.1) { df[t, default: 0] += 1 } }
        let n = max(1, ruleDocs.count + noteDocs.count)

        let ruleScores = rules.indices.map { score(query: query, title: ruleDocs[$0].0, body: ruleDocs[$0].1, df: df, docs: n) }
        let noteScores = notes.indices.map { score(query: query, title: noteDocs[$0].0, body: noteDocs[$0].1, df: df, docs: n) }

        var picked: [RuleEntry] = []
        var used = 0
        func cost(_ r: RuleEntry) -> Int { PromptBudget.tokens(r.citation) + PromptBudget.tokens(String(r.body.prefix(400))) + 6 }
        // Locked (admin) rules always go in: they are binding.
        for r in rules where r.locked {
            picked.append(r)
            used += cost(r)
        }
        let ranked = rules.indices.filter { !rules[$0].locked && ruleScores[$0] > 0 }.sorted { ruleScores[$0] > ruleScores[$1] }
        for i in ranked where picked.count < maxRules + rules.filter({ $0.locked }).count {
            let c = cost(rules[i])
            if used + c > budgetTokens { break }
            picked.append(rules[i])
            used += c
        }
        let pickedNotes = notes.indices.filter { noteScores[$0] > 0 }.sorted { noteScores[$0] > noteScores[$1] }.prefix(maxNotes).map { notes[$0] }

        let relevantRules = rules.indices.filter { ruleScores[$0] > 0 && picked.contains(rules[$0]) }.count
        let q = Set(query)
        func strong(_ doc: ([String], [String])) -> Bool {
            !q.isDisjoint(with: doc.0) || q.intersection(doc.0 + doc.1).count >= 2
        }
        let strongRules = rules.indices.filter { ruleScores[$0] > 0 && picked.contains(rules[$0]) && strong(ruleDocs[$0]) }.count
        let strongNotes = notes.indices.filter { noteScores[$0] > 0 && pickedNotes.contains(notes[$0]) && strong(noteDocs[$0]) }.count
        return Selection(rules: picked, notes: pickedNotes, relevantCount: relevantRules + pickedNotes.count,
                         checkedTitles: picked.map { $0.title } + pickedNotes.map { $0.title },
                         strongCount: strongRules + strongNotes)
    }
}
