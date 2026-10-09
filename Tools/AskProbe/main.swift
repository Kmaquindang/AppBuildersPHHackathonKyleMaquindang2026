// Tools/AskProbe/main.swift
// Pasa latency probe (macOS). Built and run by scripts/ask-probe.sh.
// Sends a few fixed asks through the app's real ExecutiveAssistant (same prompts, retrieval and
// guard) against LOCAL Ollama only, and prints each model call: prompt tokens, generated tokens,
// load, prompt and generation time. Synthetic team memory (BenchmarkSuite.memory) only.
//
// Usage: pasa-ask-probe [runs] [question ...]

import Foundation

/// Wraps the real client and records every call.
final class Recorder: LLMClient, @unchecked Sendable {
    let inner: OllamaClient
    var calls: [(json: Bool, result: LLMResult, wallMs: Int)] = []
    init(_ inner: OllamaClient) { self.inner = inner }
    var modelName: String { inner.modelName }
    func chat(_ messages: [ChatTurn], json: Bool) async throws -> LLMResult {
        let t = Date()
        let r = try await inner.chat(messages, json: json)
        calls.append((json, r, Int(Date().timeIntervalSince(t) * 1000)))
        return r
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let runs = Int(args.first ?? "") ?? 3
let custom = Array(args.dropFirst(Int(args.first ?? "") == nil ? 0 : 1))
let questions = custom.isEmpty ? ["10+69", "Can I visit the site at 6 PM?", "What is the capital of Japan?"] : custom

let client = OllamaClient(model: OllamaClient.defaultModel, fallbackModel: nil, timeout: 300, temperature: 0.2)
_ = try? await client.warmUp()

for q in questions {
    var walls: [Int] = []
    for i in 1...runs {
        let rec = Recorder(client)
        let mem = OrgMemory()
        mem.replace(with: BenchmarkSuite.memory())
        mem.admins = ["Site Office"]
        let assistant = await ExecutiveAssistant(memory: mem, llm: rec, selfName: "Site Office", knownDevices: ["DEVICE_A", "DEVICE_B"])
        let t = Date()
        let out = await assistant.handle(q, from: "DEVICE_A")
        let wall = Int(Date().timeIntervalSince(t) * 1000)
        walls.append(wall)
        print("[\(q)] run \(i): \(wall) ms, intent \(out.intent.rawValue), calls \(rec.calls.count)")
        for (n, c) in rec.calls.enumerated() {
            let r = c.result
            let gen = r.evalDurationNs.map { Int($0 / 1_000_000) } ?? -1
            let total = r.totalDurationNs.map { Int($0 / 1_000_000) } ?? -1
            print("   call \(n + 1) \(c.json ? "json" : "text"): wall \(c.wallMs) ms, total \(total) ms, prompt \(r.promptEvalCount ?? -1) tok, gen \(r.evalCount ?? -1) tok in \(gen) ms")
        }
        print("   reply: \((out.fullReply ?? out.reply).replacingOccurrences(of: "\n", with: " "))")
        print("   rulesUsed: \(out.rulesUsed) unverified: \(out.unverifiedRules) noRule: \(out.noRule.map(String.init) ?? "-")")
    }
    let sorted = walls.sorted()
    print("[\(q)] median \(sorted[sorted.count / 2]) ms over \(runs) runs\n")
}
