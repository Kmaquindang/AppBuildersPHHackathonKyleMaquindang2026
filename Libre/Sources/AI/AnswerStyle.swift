// AnswerStyle.swift
// Pasa: turns a grounded model answer into a short, chat-style reply plus structured rule chips.
// Pure Swift, tested on Linux.
//
// The model still writes citations as [Rule: Title vN] (the prompt asks for them at the end), and
// CitationGuard still checks every one against team memory. Then:
// - verified citations leave the text and travel as `rulesUsed` (the phone shows them as
//   tappable chips under the bubble);
// - invented citations leave the text too and travel as `unverifiedRules` (the phone shows a
//   warning chip "Not a saved rule"), so a made-up rule can never pass as a real one;
// - the old text markers ("No saved team rule covers this.", "General advice, not a team
//   rule:") are removed if a model still writes them;
// - `noRule` is true when the answer used no saved rule or note. The benchmark scores this
//   field, not text markers.

import Foundation

public struct StyledAnswer: Equatable, Sendable {
    /// What the bubble shows: no citation tags, no preambles.
    public var text: String
    /// Exact current citations of the saved rules and notes the answer relied on, in order.
    public var rulesUsed: [String]
    /// Tags that named nothing saved (shown as a warning chip, never as a rule).
    public var unverifiedRules: [String]
    /// No saved rule or note backs this answer.
    public var noRule: Bool
}

public enum AnswerStyle {
    /// Natural fallback when the model returned nothing for a team question.
    public static let noRuleFallback = "I don't have a team rule on that yet."
    public static let emptyFallback = "Sorry, I don't have an answer for that."

    static let legacyMarkers = [
        "No saved team rule covers this.", "No saved team rule covers this",
        "General advice, not a team rule:", "General advice, not a team rule."
    ]

    private static let tag = try! NSRegularExpression(
        pattern: #"\s*\(?\s*\[(?:Rule|Skill|Note)\s*:\s*[^\]\n]{1,200}\](?:\s*\(unverified\))?\s*\)?"#, options: [.caseInsensitive])

    /// Applies the citation guard, then styles the result.
    public static func style(_ raw: String, rules: [RuleEntry], notes: [Note]) -> StyledAnswer {
        let guarded = CitationGuard.validate(raw, rules: rules, notes: notes)
        return style(guarded: guarded)
    }

    public static func style(guarded: CitationGuard.Result) -> StyledAnswer {
        var text = stripTags(guarded.text)
        for marker in legacyMarkers {
            text = text.replacingOccurrences(of: marker, with: "", options: [.caseInsensitive])
        }
        text = tidy(text)
        var seen = Set<String>()
        let used = guarded.verified.filter { seen.insert($0).inserted }
        var seenU = Set<String>()
        let unverified = guarded.unverified.filter { seenU.insert($0).inserted }
        if text.isEmpty { text = used.isEmpty ? noRuleFallback : emptyFallback }
        return StyledAnswer(text: text, rulesUsed: used, unverifiedRules: unverified, noRule: used.isEmpty)
    }

    /// Removes citation tags. A tag that is the subject of its sentence ("[Rule: X v1] says ...")
    /// becomes the rule title in quotes, so the sentence still reads.
    static func stripTags(_ text: String) -> String {
        let ns = text as NSString
        let matches = tag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let after = ns.substring(from: cursor)
            let nextWord = after.trimmingCharacters(in: .whitespaces).prefix(1)
            let startsSentence = out.trimmingCharacters(in: .whitespaces).isEmpty
                || [".", "!", "?", ":"].contains(out.trimmingCharacters(in: .whitespaces).suffix(1))
            let prevWord = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map { $0.lowercased() } ?? ""
            let afterPreposition = prepositions.contains(prevWord)
            if afterPreposition || (nextWord.first.map { $0.isLetter && (startsSentence || !$0.isUppercase) } ?? false) {
                // Used as a noun: keep the title.
                let matched = ns.substring(with: m.range)
                out += " \u{201C}" + title(in: matched) + "\u{201D} "
            } else {
                out += " "
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Words after which a removed tag must keep its title ("per [Rule: X]" -> "per “X”").
    static let prepositions: Set<String> = ["per", "under", "by", "to", "see", "from", "in", "on", "with", "sa", "ayon", "base", "rule", "the"]

    /// "[Rule: No site visits after 5 PM v2]" -> "No site visits after 5 PM".
    public static func title(in citation: String) -> String {
        var t = citation
        if let open = t.firstIndex(of: "["), let close = t.firstIndex(of: "]"), open < close {
            t = String(t[t.index(after: open)..<close])
        }
        if let colon = t.firstIndex(of: ":") { t = String(t[t.index(after: colon)...]) }
        t = t.replacingOccurrences(of: #"\s+v\d+\s*$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "Rule", "Skill" or "Note" from a citation.
    public static func kind(in citation: String) -> String {
        let lower = citation.lowercased()
        if lower.hasPrefix("[note") { return "Note" }
        if lower.hasPrefix("[skill") { return "Skill" }
        return "Rule"
    }

    /// Collapses the spaces and punctuation the removed tags leave behind.
    static func tidy(_ text: String) -> String {
        var t = text
        let fixes: [(String, String)] = [
            (#"[ \t]+"#, " "),
            (#" +([.,;:!?])"#, "$1"),
            (#"([.,;:!?])(?:\s*[,;:])+"#, "$1"),
            (#"\(\s*\)"#, ""),
            (#"\.{2,}"#, "."),
            (#"^\s*[,;:.\-]+\s*"#, ""),
            (#"\s*[,;:\-]+\s*$"#, ""),
            (#"[ \t]*\n[ \t]*"#, "\n"),
            (#"\n{3,}"#, "\n\n")
        ]
        for (pattern, template) in fixes {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence that lost its start to a removed marker begins lowercase: capitalize it.
        if let first = t.first, first.isLowercase { t = first.uppercased() + t.dropFirst() }
        return t
    }
}

/// Cheap local routing: plain questions skip the intent model call and go straight to the
/// grounded answer call (one model call instead of two, about 1 s less on an M3).
public enum QuestionRouter {
    /// Words that mean the message may be a command (task, rule, notes), so it still goes
    /// through the intent model.
    static let commandWords: Set<String> = [
        "remind", "reminder", "task", "tasks", "todo", "todos", "assign", "assigned", "assignee",
        "rule", "rules", "skill", "skills", "policy", "save", "add", "delete", "remove", "retire",
        "lock", "unlock", "edit", "update", "change", "done", "finished", "complete", "completed",
        "mark", "notes", "note", "minutes", "transcript", "summary", "summarize", "recap", "remember",
        "paalala", "ipaalala", "tapos", "natapos", "gawain", "idagdag", "burahin", "tanggalin",
        "i-save", "isave", "palihug", "humana", "nahuman", "tangtangon", "dugangi"
    ]

    static let questionStarts: Set<String> = [
        "what", "whats", "who", "whos", "when", "where", "why", "how", "which", "can", "could", "may",
        "is", "are", "am", "do", "does", "did", "should", "would", "will", "was", "were", "has", "have",
        "pwede", "puwede", "ano", "anong", "sino", "kailan", "saan", "bakit", "paano", "ilan", "magkano",
        "kailangan", "unsa", "unsay", "kanus", "asa", "ngano", "unsaon", "pila", "kinsa", "tuloy", "bawal"
    ]

    /// Arithmetic like "10+69", "12 x 7", "(3+4)*2=?".
    static let arithmetic = try! NSRegularExpression(pattern: #"^[\d\s.,+\-*/x×÷^()=?%]+$"#, options: [.caseInsensitive])

    /// True when the message is a plain question with no command words.
    public static func isPlainQuestion(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300 else { return false }
        let ns = text as NSString
        if arithmetic.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil,
           text.contains(where: { $0.isNumber }) { return true }
        let words = NameMatcher.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        if words.contains(where: { commandWords.contains($0) }) { return false }
        if text.hasSuffix("?") { return true }
        // Last sentence starts with a question word ("It is raining. Can we keep pouring").
        let lastSentence = text.split(whereSeparator: { ".!\n".contains($0) }).last.map(String.init) ?? text
        let first = NameMatcher.normalize(lastSentence).split(separator: " ").first.map(String.init) ?? ""
        return questionStarts.contains(first)
    }

    /// Team-knowledge words: when none of these and no rule matched, the open task list is left
    /// out of the answer prompt (keeps "10+69" lean).
    static let teamWords: Set<String> = [
        "task", "tasks", "todo", "who", "assigned", "doing", "ordering", "order", "team", "deadline", "due",
        "sino", "gawain", "kinsa"
    ]

    public static func needsTasks(_ question: String, taskTitles: [String]) -> Bool {
        let q = Set(KnowledgeRetriever.terms(question))
        if q.isEmpty { return false }
        if !q.isDisjoint(with: teamWords) || NameMatcher.normalize(question).split(separator: " ").contains(where: { teamWords.contains(String($0)) }) { return true }
        let taskTerms = Set(taskTitles.flatMap { KnowledgeRetriever.terms($0) })
        return !q.isDisjoint(with: taskTerms)
    }
}
