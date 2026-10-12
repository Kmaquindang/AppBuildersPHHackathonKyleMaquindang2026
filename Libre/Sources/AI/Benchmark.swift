// Benchmark.swift
// Pasa: a reproducible benchmark of the AI Mac's real answer pipeline (the same ExecutiveAssistant,
// retrieval, prompts and citation guard as the app) against local Ollama models only.
// Pure Swift, the scorer and report writers are tested on Linux with a fake model.
//
// - Fixed synthetic team memory (10 rules: English, Tagalog, Cebuano) and 20 fixed questions
//   (11 English, 6 Tagalog, 3 Cebuano; 16 expect a rule citation, 4 expect "no rule"). Synthetic data only.
// - Each question runs on a fresh copy of the memory, so a misread question cannot change the
//   next one.
// - Scoring is exact, never an LLM judge, and reads the STRUCTURED answer fields (the reply text
//   carries no citation tags since the chat-style answers of Oct 9 night):
//   * "cites" questions pass when `rulesUsed` (verified by CitationGuard) includes the expected
//     rule and `unverifiedRules` is empty.
//   * "no rule" questions pass when `noRule` is true, nothing was cited (verified or not), and
//     the reply admits it does not know (a short list of English, Tagalog and Cebuano phrases,
//     so an invented answer like a made-up Wi-Fi password fails).
// - Measured per question: wall time (ms), generation speed (tok/s from Ollama eval_count /
//   eval_duration), prompt tokens (Ollama prompt_eval_count), generated tokens, model calls.

import Foundation

public enum BenchmarkExpectation: Equatable, Sendable {
    case cites(String)
    case noRule

    public var label: String {
        switch self {
        case .cites(let t): return "cites: \(t)"
        case .noRule: return "no rule"
        }
    }
}

public struct BenchmarkQuestion: Equatable, Sendable {
    public var id: Int
    public var language: String
    public var text: String
    public var expect: BenchmarkExpectation
}

public struct BenchmarkResult: Equatable, Sendable {
    public var question: BenchmarkQuestion
    public var model: String
    public var correct: Bool
    public var reason: String
    public var intent: String
    public var latencyMs: Int
    public var tokensPerSecond: Double?
    public var promptTokens: Int?
    public var evalTokens: Int?
    public var modelCalls: Int
    public var reply: String
    public var rulesUsed: [String] = []
    /// Reply language (ReplyLanguage.detect), scored separately from grounding (issue #11).
    public var replyLanguage: String? = nil
    public var languageOK: Bool { replyLanguage == question.language }
}

public enum BenchmarkSuite {
    public static let version = "pasa-bench-v1"

    /// Synthetic team memory (no real people or sites).
    public static func memory(now: Date = Date(timeIntervalSince1970: 1_791_100_000)) -> OrgSnapshot {
        var s = OrgSnapshot()
        let rules: [(String, String)] = [
            ("No site visits after 5 PM", "Site visits end at 5 PM. After 5 PM nobody enters the site without the foreman."),
            ("Hard hats inside the fence", "Everyone wears a hard hat inside the site fence, including visitors."),
            ("Cement orders before Thursday", "Cement orders go to the supplier before Thursday noon for Saturday delivery."),
            ("Petty cash limit", "Petty cash purchases above 2,000 pesos need the foreman's OK first."),
            ("Rain stops concrete pouring", "Stop pouring concrete when it rains and cover fresh concrete with tarpaulin."),
            ("Bawal manigarilyo sa bodega", "Bawal manigarilyo sa loob at malapit sa bodega ng semento at pintura."),
            ("Oras ng tanghalian", "Ang tanghalian ay mula 12:00 hanggang 1:00 PM. Walang trabaho sa scaffolding habang tanghalian."),
            ("Ayaw pagdala og bata sa site", "Ayaw pagdala og bata sa construction site bisan weekend."),
            ("Generator fuel log", "Write every generator refuel in the fuel log with the time and the liters."),
            ("Visitor sign-in", "All visitors sign the logbook at the gate and wear a visitor vest.")
        ]
        for (i, r) in rules.enumerated() {
            s.rules.append(RuleEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i + 1))!,
                                     title: r.0, body: r.1, addedBy: "Site Office", createdAt: now))
        }
        s.tasks = [
            TaskItem(title: "Order cement", assignee: "PERSON_A", assigneeDevice: "DEVICE_A", due: "Thursday", createdBy: "Site Office", createdAt: now),
            TaskItem(title: "Fix the gate lock", assignee: "PERSON_B", assigneeDevice: "DEVICE_B", createdBy: "Site Office", createdAt: now)
        ]
        return s
    }

    public static let questions: [BenchmarkQuestion] = {
        let q: [(String, String, BenchmarkExpectation)] = [
            ("en", "Can I visit the site at 6 PM?", .cites("No site visits after 5 PM")),
            ("en", "Do I need a hard hat to walk inside the fence?", .cites("Hard hats inside the fence")),
            ("en", "When is the deadline to order cement for a Saturday delivery?", .cites("Cement orders before Thursday")),
            ("en", "Can I buy a 3,000 peso drill with petty cash right away?", .cites("Petty cash limit")),
            ("en", "It is raining. Can we keep pouring concrete?", .cites("Rain stops concrete pouring")),
            ("en", "We just refueled the generator. What do I need to do?", .cites("Generator fuel log")),
            ("en", "A visitor from the supplier arrived. What should they do at the gate?", .cites("Visitor sign-in")),
            ("en", "Is smoking allowed near the cement and paint storage?", .cites("Bawal manigarilyo sa bodega")),
            ("tl", "Pwede ba akong pumunta sa site ng alas-sais ng gabi?", .cites("No site visits after 5 PM")),
            ("tl", "Pwede bang manigarilyo malapit sa bodega?", .cites("Bawal manigarilyo sa bodega")),
            ("tl", "Anong oras ang tanghalian?", .cites("Oras ng tanghalian")),
            ("tl", "Kailangan ba ng hard hat sa loob ng fence ng site?", .cites("Hard hats inside the fence")),
            ("tl", "Umuulan, tuloy pa ba ang pagbuhos ng concrete?", .cites("Rain stops concrete pouring")),
            ("ceb", "Pwede ba nako dad-on akong bata sa site karong weekend?", .cites("Ayaw pagdala og bata sa site")),
            ("ceb", "Unsa orasa ang tanghalian?", .cites("Oras ng tanghalian")),
            ("ceb", "Pwede ba ko mosulod sa site alas sais sa gabii?", .cites("No site visits after 5 PM")),
            ("en", "What is the Wi-Fi password of the site office?", .noRule),
            ("en", "Who won the basketball game last night?", .noRule),
            ("tl", "Ano ang paboritong kulay ng foreman?", .noRule),
            ("en", "What time does the hardware store in town close?", .noRule)
        ]
        return q.enumerated().map { BenchmarkQuestion(id: $0.offset + 1, language: $0.element.0, text: $0.element.1, expect: $0.element.2) }
    }()

    /// Phrases that admit "I don't know / no team rule" (English, Tagalog, Cebuano).
    public static let admitsPhrases = [
        "don't have", "do not have", "don't know", "do not know", "not sure", "no team rule", "no saved", "no rule",
        "no info", "no information", "isn't saved", "is not saved", "not saved", "haven't", "can't tell", "cannot tell",
        "can't say", "cannot say", "unable", "no record", "not in", "no details", "i don't", "i do not", "no data",
        "wala akong", "walang", "wala pa", "hindi ko alam", "hindi ko", "wala koy", "wala ko", "dili ko", "walay"
    ]

    public static func admitsUnknown(_ reply: String) -> Bool {
        let lower = reply.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return admitsPhrases.contains { lower.contains($0) }
    }

    /// Exact scoring of one structured answer against the expectation.
    public static func score(rulesUsed: [String], unverified: [String], noRule: Bool?, reply: String, intent: String,
                             expect: BenchmarkExpectation, rules: [RuleEntry]) -> (Bool, String) {
        if !unverified.isEmpty { return (false, "unverified citation \(unverified.joined(separator: " "))") }
        switch expect {
        case .cites(let title):
            let want = rules.first { $0.title == title }?.citation ?? "[Rule: \(title)"
            if rulesUsed.contains(want) { return (true, "cited \(want)") }
            if intent != IntentKind.answer.rawValue { return (false, "routed to \(intent), not answer") }
            return (false, rulesUsed.isEmpty ? "no citation" : "cited \(rulesUsed.joined(separator: " ")) instead")
        case .noRule:
            if intent != IntentKind.answer.rawValue { return (false, "routed to \(intent)") }
            if !rulesUsed.isEmpty { return (false, "cited \(rulesUsed.joined(separator: " ")) for a question no rule covers") }
            guard noRule == true else { return (false, "noRule flag not set") }
            if admitsUnknown(reply) { return (true, "noRule, said it does not know") }
            return (false, "noRule, but the reply did not say it does not know")
        }
    }

    /// Runs every question through a fresh ExecutiveAssistant on a fresh memory copy.
    @MainActor
    public static func run(llm: any LLMClient, model: String, progress: ((BenchmarkResult) -> Void)? = nil) async -> [BenchmarkResult] {
        // As in the app: rules get their gloss (RuleGlosser) once, when saved, before anyone asks.
        let prepared = OrgMemory()
        prepared.replace(with: memory())
        await RuleGlosser.glossMissing(in: prepared, llm: llm)
        var results: [BenchmarkResult] = []
        for q in questions {
            let r = await runOne(q, llm: llm, model: model, snapshot: prepared.snapshot)
            results.append(r)
            progress?(r)
        }
        return results
    }

    /// One question (also the Mac setup's one-question self-test).
    @MainActor
    public static func runOne(_ q: BenchmarkQuestion, llm: any LLMClient, model: String, snapshot prepared: OrgSnapshot? = nil) async -> BenchmarkResult {
        let snapshot = prepared ?? memory()
        let mem = OrgMemory()
        mem.replace(with: snapshot)
        mem.admins = ["Site Office"]
        let assistant = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Site Office", knownDevices: ["DEVICE_A", "DEVICE_B"])
        assistant.directory = ["DEVICE_A": "PERSON_A", "DEVICE_B": "PERSON_B"]
        let started = Date()
        let out = await assistant.handle(q.text, from: "DEVICE_A")
        let wall = Int((Date().timeIntervalSince(started) * 1000).rounded())
        let full = out.fullReply ?? out.reply
        var (ok, why) = score(rulesUsed: out.rulesUsed, unverified: out.unverifiedRules, noRule: out.noRule, reply: full,
                              intent: out.intent.rawValue, expect: q.expect, rules: snapshot.activeRules)
        if let error = out.error { ok = false; why = "error: \(error)" }
        var result = BenchmarkResult(question: q, model: out.model ?? model, correct: ok, reason: why, intent: out.intent.rawValue,
                                     latencyMs: wall, tokensPerSecond: out.tokensPerSecond, promptTokens: out.promptEvalCount,
                                     evalTokens: out.evalTokens, modelCalls: out.modelCalls, reply: full, rulesUsed: out.rulesUsed)
        result.replyLanguage = ReplyLanguage.detect(full)
        return result
    }
}

public struct BenchmarkSummary: Equatable, Sendable {
    public var model: String
    public var correct: Int
    public var total: Int
    public var medianLatencyMs: Int
    public var meanTokensPerSecond: Double?
    public var meanPromptTokens: Int?
    public var byLanguage: [(String, Int, Int)]

    public static func == (a: BenchmarkSummary, b: BenchmarkSummary) -> Bool {
        a.model == b.model && a.correct == b.correct && a.total == b.total && a.medianLatencyMs == b.medianLatencyMs
    }

    public init(model: String, results: [BenchmarkResult]) {
        self.model = model
        total = results.count
        correct = results.filter(\.correct).count
        let lat = results.map(\.latencyMs).sorted()
        medianLatencyMs = lat.isEmpty ? 0 : (lat.count % 2 == 1 ? lat[lat.count / 2] : (lat[lat.count / 2 - 1] + lat[lat.count / 2]) / 2)
        let tps = results.compactMap(\.tokensPerSecond).filter { $0.isFinite && $0 > 0 }
        meanTokensPerSecond = tps.isEmpty ? nil : tps.reduce(0, +) / Double(tps.count)
        let pt = results.compactMap(\.promptTokens)
        meanPromptTokens = pt.isEmpty ? nil : pt.reduce(0, +) / pt.count
        byLanguage = ["en", "tl", "ceb"].map { lang in
            let r = results.filter { $0.question.language == lang }
            return (lang, r.filter(\.correct).count, r.count)
        }
    }
}

public enum BenchmarkReport {
    static func csvField(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    public static func csv(_ results: [BenchmarkResult]) -> String {
        var lines = ["id,language,model,expect,correct,reason,intent,latency_ms,tok_per_s,prompt_tokens,eval_tokens,model_calls,question,reply,rules_used,reply_language,language_ok"]
        for r in results {
            var fields: [String] = [String(r.question.id), r.question.language, csvField(r.model), csvField(r.question.expect.label), r.correct ? "1" : "0",
                                    csvField(r.reason), r.intent, String(r.latencyMs), r.tokensPerSecond.map { String(format: "%.2f", $0) } ?? ""]
            fields += [r.promptTokens.map(String.init) ?? "", r.evalTokens.map(String.init) ?? "", String(r.modelCalls),
                       csvField(r.question.text), csvField(r.reply), csvField(r.rulesUsed.joined(separator: " "))]
            fields += [r.replyLanguage ?? "unclear", r.languageOK ? "1" : "0"]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public struct Header: Sendable {
        public var date: String
        public var machine: String
        public var ollamaVersion: String
        public var digests: [String: String]
        public var memoryInUse: [String: String]
        public var skipped: [String]

        public init(date: String, machine: String, ollamaVersion: String, digests: [String: String], memoryInUse: [String: String] = [:], skipped: [String] = []) {
            self.date = date
            self.machine = machine
            self.ollamaVersion = ollamaVersion
            self.digests = digests
            self.memoryInUse = memoryInUse
            self.skipped = skipped
        }
    }

    public static func markdown(header: Header, runs: [(String, [BenchmarkResult])]) -> String {
        var out = ["# Libre benchmark (\(BenchmarkSuite.version))", "",
                   "- Date: \(header.date)", "- Machine: \(header.machine)", "- Ollama: \(header.ollamaVersion)",
                   "- Questions: \(BenchmarkSuite.questions.count) fixed (11 English, 6 Tagalog, 3 Cebuano; 16 with a matching rule, 4 with none), synthetic team memory of 10 rules",
                   "- Pipeline: the app's ExecutiveAssistant (plain questions skip the intent call; grounded answer call with keyword retrieval, citation guard and chat styling), local Ollama on 127.0.0.1 only",
                   "- Scoring: exact checks on the structured answer (expected rule in rulesUsed and nothing unverified, or noRule with no citation and a reply that admits it does not know). No LLM judge.", ""]
        for (model, _) in runs {
            out.append("- Model `\(model)` digest `\(header.digests[model] ?? "unknown")`" + (header.memoryInUse[model].map { ", in memory after the run: \($0)" } ?? ""))
        }
        for s in header.skipped { out.append("- Skipped: \(s)") }
        out += ["", "| Model | Grounded correct | English | Tagalog | Cebuano | Median latency (ms) | Mean tok/s | Mean prompt tokens |", "|---|---|---|---|---|---|---|---|"]
        for (model, results) in runs {
            let s = BenchmarkSummary(model: model, results: results)
            func lang(_ l: String) -> String { s.byLanguage.first { $0.0 == l }.map { "\($0.1)/\($0.2)" } ?? "-" }
            out.append("| \(model) | \(s.correct)/\(s.total) | \(lang("en")) | \(lang("tl")) | \(lang("ceb")) | \(s.medianLatencyMs) | \(s.meanTokensPerSecond.map { String(format: "%.1f", $0) } ?? "-") | \(s.meanPromptTokens.map(String.init) ?? "-") |")
        }
        // Reply language, scored separately (issue #11): the grounding scores above do not change.
        out += ["", "Reply language (scored separately; a reply passes when ReplyLanguage detects the question's language):", "",
                "| Model | Reply in the asker's language | English | Tagalog | Cebuano |", "|---|---|---|---|---|"]
        for (model, results) in runs {
            func lang(_ l: String) -> String {
                let r = results.filter { $0.question.language == l }
                return "\(r.filter(\.languageOK).count)/\(r.count)"
            }
            out.append("| \(model) | \(results.filter(\.languageOK).count)/\(results.count) | \(lang("en")) | \(lang("tl")) | \(lang("ceb")) |")
        }
        for (model, results) in runs {
            out += ["", "## \(model): per question", "", "| # | Lang | Question | Expected | Result | Why | ms | tok/s | prompt tok | Reply language |", "|---|---|---|---|---|---|---|---|---|---|"]
            for r in results {
                let q = r.question.text.replacingOccurrences(of: "|", with: "/")
                out.append("| \(r.question.id) | \(r.question.language) | \(q) | \(r.question.expect.label) | \(r.correct ? "pass" : "FAIL") | \(r.reason.replacingOccurrences(of: "|", with: "/")) | \(r.latencyMs) | \(r.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "-") | \(r.promptTokens.map(String.init) ?? "-") | \(r.replyLanguage ?? "unclear")\(r.languageOK ? "" : " (mismatch)") |")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
