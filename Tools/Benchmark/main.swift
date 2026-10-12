// Tools/Benchmark/main.swift
// Pasa benchmark runner (macOS). Built and run by scripts/benchmark.sh.
// Talks only to local Ollama on 127.0.0.1:11434, runs the 20 fixed questions per installed model,
// and writes CSV + markdown to docs/benchmarks/. Models that are not installed are skipped, never pulled.
//
// Usage: pasa-benchmark <out-dir> <machine label> [model ...]

import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: pasa-benchmark <out-dir> <machine label> [model ...]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let machine = args[2]
let wanted = args.count > 3 ? Array(args[3...]) : [OllamaClient.defaultModel, OllamaClient.lowMemoryModel]
let base = OllamaClient.defaultBaseURL
guard OllamaClient.isLoopback(base) else { print("Refusing: Ollama URL is not loopback"); exit(2) }

let probe = OllamaClient(baseURL: base, model: wanted[0], fallbackModel: nil)
let installed: [String]
do { installed = try await probe.installedModels() } catch {
    print("Ollama is not answering on \(base.absoluteString): \(error.localizedDescription)")
    exit(1)
}
let digests = (try? await probe.installedModelDigests()) ?? [:]
let version = (try? await probe.serverVersion()) ?? "unknown"

var runs: [(String, [BenchmarkResult])] = []
var skipped: [String] = []
var memoryInUse: [String: String] = [:]
for model in wanted {
    guard installed.contains(model) else {
        skipped.append("\(model) (not installed; run: ollama pull \(model))")
        print("skip \(model): not installed")
        continue
    }
    // No fallback: a missing model must never be replaced by another one silently.
    let client = OllamaClient(baseURL: base, model: model, fallbackModel: nil, timeout: 300, temperature: 0.2)
    print("warm \(model)...")
    _ = try? await client.chat([ChatTurn(role: "user", content: "Reply with OK.")], json: false)
    print("run \(model): \(BenchmarkSuite.questions.count) questions")
    let results = await BenchmarkSuite.run(llm: client, model: model) { r in
        let tps = r.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "-"
        print(String(format: "  #%02d %@ %@ %d ms %@ tok/s", r.question.id, r.question.language, r.correct ? "PASS" : "FAIL", r.latencyMs, tps) + "  lang=\(r.replyLanguage ?? "unclear")\(r.languageOK ? "" : "(mismatch)")  \(r.reason)")
    }
    if let running = try? await client.runningModels(), let m = running.first(where: { $0.name == model }) {
        memoryInUse[model] = RunningModel.gigabytes(m.size)
    }
    runs.append((model, results))
}

let stamp = ISO8601DateFormatter()
stamp.timeZone = .current
stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
let now = Date()
let fileDay = DateFormatter()
fileDay.dateFormat = "yyyy-MM-dd-HHmm"
let tag = fileDay.string(from: now)

let header = BenchmarkReport.Header(date: stamp.string(from: now), machine: machine, ollamaVersion: version,
                                    digests: digests.filter { d in runs.contains { $0.0 == d.key } }.mapValues { String($0.prefix(12)) },
                                    memoryInUse: memoryInUse, skipped: skipped)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let md = BenchmarkReport.markdown(header: header, runs: runs)
let mdURL = outDir.appendingPathComponent("benchmark-\(tag).md")
try md.write(to: mdURL, atomically: true, encoding: .utf8)
for (model, results) in runs {
    let safe = model.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
    try BenchmarkReport.csv(results).write(to: outDir.appendingPathComponent("benchmark-\(tag)-\(safe).csv"), atomically: true, encoding: .utf8)
}
print("")
print(md)
print("wrote \(mdURL.path)")
