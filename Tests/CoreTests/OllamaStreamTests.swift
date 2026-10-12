// OllamaStreamTests.swift: streamed /api/chat on a fake HTTP line transport, and the assistant's
// partial-text hook (issue #2). No network.
import Foundation

final class FakeLines: OllamaLineTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String: (Int, [String])]
    private var _models: [String] = []
    private var _bodies: [[String: Any]] = []

    init(_ replies: [String: (Int, [String])]) { self.replies = replies }

    var models: [String] { lock.lock(); defer { lock.unlock() }; return _models }
    var lastBody: [String: Any] { lock.lock(); defer { lock.unlock() }; return _bodies.last ?? [:] }

    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let model = body["model"] as? String ?? ""
        lock.lock(); _models.append(model); _bodies.append(body); lock.unlock()
        let (status, lines) = replies[model] ?? (404, [#"{"error":"model 'x' not found"}"#])
        return (status, AsyncThrowingStream { c in
            for line in lines { c.yield(line) }
            c.finish()
        })
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Scripted model that streams its reply in pieces of `size` characters.
final class FakeStreamingLLM: StreamingLLMClient, @unchecked Sendable {
    let reply: String
    let size: Int
    init(_ reply: String, size: Int = 7) { self.reply = reply; self.size = size }
    var modelName: String { "fake:1b" }
    func chat(_ messages: [ChatTurn], json: Bool) async throws -> LLMResult {
        LLMResult(text: reply, model: "fake:1b", evalCount: 50, evalDurationNs: 1_000_000_000)
    }
    func chatStream(_ messages: [ChatTurn], maxTokens: Int?, onDelta: @escaping @Sendable (String) -> Void) async throws -> LLMResult {
        var rest = Substring(reply)
        while !rest.isEmpty { onDelta(String(rest.prefix(size))); rest = rest.dropFirst(size) }
        return try await chat(messages, json: false)
    }
}

private func line(_ content: String) -> String {
    let escaped = String(decoding: (try? JSONEncoder().encode(content)) ?? Data(), as: UTF8.self)
    return #"{"model":"qwen3:8b","message":{"role":"assistant","content":"# + escaped + #"},"done":false}"#
}
private let doneLine = #"{"model":"qwen3:8b","message":{"role":"assistant","content":""},"done":true,"eval_count":12,"eval_duration":600000000,"total_duration":900000000,"prompt_eval_count":300}"#

@MainActor
func runOllamaStreamTests() async {
    // Pieces arrive in order; the result is the whole reply with timings.
    do {
        let fake = FakeLines(["qwen3:8b": (200, [line("Visits"), line(" end"), "", line(" at 8 PM."), doneLine])])
        var client = OllamaClient(model: "qwen3:8b")
        client.lines = fake
        let got = Collected()
        let result = try await client.chatStream([ChatTurn(role: "user", content: "visits?")], maxTokens: 200) { got.add($0) }
        check(got.all == ["Visits", " end", " at 8 PM."], "ollama stream: pieces in order, blank line skipped")
        check(result.text == "Visits end at 8 PM." && result.evalCount == 12 && result.promptEvalCount == 300, "ollama stream: whole reply and timings")
        check(fake.lastBody["stream"] as? Bool == true && fake.lastBody["think"] as? Bool == false, "ollama stream: asks for stream, thinking off")
    } catch {
        check(false, "ollama stream: normal reply threw \(error)")
    }

    // An empty think block is removed from the result.
    do {
        var client = OllamaClient(model: "qwen3:8b")
        client.lines = FakeLines(["qwen3:8b": (200, [line("<think>\n\n</think>\n\n"), line("Hi Ana."), doneLine])])
        let result = try await client.chatStream([ChatTurn(role: "user", content: "hi")], maxTokens: nil) { _ in }
        check(result.text == "Hi Ana.", "ollama stream: thinking stripped from the result")
    } catch {
        check(false, "ollama stream: think reply threw \(error)")
    }

    // An error line, or a stream that stops before done, fails: never a partial answer.
    var client = OllamaClient(model: "qwen3:8b")
    client.lines = FakeLines(["qwen3:8b": (200, [line("Visits"), #"{"error":"out of memory"}"#])])
    do {
        _ = try await client.chatStream([], maxTokens: nil) { _ in }
        check(false, "ollama stream: error line throws")
    } catch LLMError.badResponse(let why) {
        check(why.contains("out of memory"), "ollama stream: error line throws")
    } catch {
        check(false, "ollama stream: error line throws")
    }
    client.lines = FakeLines(["qwen3:8b": (200, [line("Visits end")])])
    do {
        _ = try await client.chatStream([], maxTokens: nil) { _ in }
        check(false, "ollama stream: cut-off stream throws")
    } catch {
        check(error as? LLMError != nil, "ollama stream: cut-off stream throws")
    }

    // Missing model: falls back like chat().
    do {
        let fake = FakeLines(["qwen3:4b": (200, [line("Fallback here."), doneLine])])
        var c = OllamaClient(model: "qwen3:8b", fallbackModel: "qwen3:4b")
        c.lines = fake
        let result = try await c.chatStream([], maxTokens: nil) { _ in }
        check(fake.models == ["qwen3:8b", "qwen3:4b"] && result.text == "Fallback here.", "ollama stream: missing model falls back")
    } catch {
        check(false, "ollama stream: fallback threw \(error)")
    }

    // Assistant: a grounded answer streams raw text to onPartial; the outcome is still the
    // whole checked answer (citation moved to a chip).
    let mem = OrgMemory(admins: ["Mac"])
    _ = mem.upsertRule(title: "Saturday site hours", body: "Site is open 8 AM to 12 noon on Saturday.", by: "Mac")
    let llm = FakeStreamingLLM("Saturday is 8 AM to 12 noon, and the gate closes at 12:30. [Rule: Saturday site hours v1]")
    let a = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Mac")
    a.serve(room: "R1", memory: mem, clearedAt: nil)
    let partial = Collected()
    let out = await a.handle("what are the site hours on Saturday?", from: "PHONE_K", onPartial: { partial.add($0) })
    check(partial.all.joined() == llm.reply && partial.all.count > 1, "assistant stream: raw text handed out in pieces")
    check(out.reply == "Saturday is 8 AM to 12 noon, and the gate closes at 12:30." && out.rulesUsed.contains { $0.contains("Saturday site hours") }, "assistant stream: outcome is the checked whole answer")
    var streamer = AnswerStreamer()
    var sent = ""
    for (i, piece) in partial.all.enumerated() {
        if let p = streamer.add(piece, now: Date(timeIntervalSince1970: Double(i))) { sent += p.text }
    }
    check(!sent.isEmpty && !sent.contains("[") && out.reply.hasPrefix(sent), "assistant stream: streamed text is a clean prefix of the answer")

    // No onPartial: the plain chat path is used.
    let quiet = ExecutiveAssistant(memory: mem, llm: FakeLLM([.success("Saturday is 8 AM to 12 noon.")]), selfName: "Mac")
    quiet.serve(room: "R1", memory: mem, clearedAt: nil)
    let plain = await quiet.handle("what are the site hours on Saturday?", from: "PHONE_K")
    check(plain.reply.hasPrefix("Saturday is 8 AM"), "assistant stream: plain path unchanged without onPartial")
}
