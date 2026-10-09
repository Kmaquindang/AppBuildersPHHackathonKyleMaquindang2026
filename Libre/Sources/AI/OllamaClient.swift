// OllamaClient.swift
// Pasa: talks to Ollama on the same Mac (default http://127.0.0.1:11434), non-streaming /api/chat.
// No internet involved: Ollama serves the model from local disk.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mac AI peer: what the 60 s Ollama timer should do next. Pure, tested on Linux.
public enum WarmthPolicy {
    public enum Action: Equatable, Sendable {
        /// Ollama was not ready: run the full health check and warm up if it is there now.
        case check
        /// Model is loaded: re-send the warm-up so keep_alive never runs out while Pasa runs.
        case refresh
        case wait
    }

    /// How often a loaded model gets its keep_alive refreshed.
    public static let refreshEvery: TimeInterval = 600
    /// How often the timer runs.
    public static let tickEvery: TimeInterval = 60

    public static func next(ready: Bool, busy: Bool, lastWarm: Date?, now: Date = Date()) -> Action {
        if busy { return .wait }
        guard ready else { return .check }
        guard let lastWarm else { return .refresh }
        return now.timeIntervalSince(lastWarm) >= refreshEvery ? .refresh : .wait
    }
}

public struct OllamaClient: LLMClient {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!
    public static let defaultModel = "qwen3:8b"
    public static let defaultFallbackModel = "qwen3:4b"

    public var baseURL: URL
    public var model: String
    public var fallbackModel: String?
    public var timeout: TimeInterval
    public var temperature: Double

    public init(
        baseURL: URL = OllamaClient.defaultBaseURL,
        model: String = OllamaClient.defaultModel,
        fallbackModel: String? = OllamaClient.defaultFallbackModel,
        timeout: TimeInterval = 120,
        temperature: Double = 0.2
    ) {
        self.baseURL = baseURL
        self.model = model
        self.fallbackModel = fallbackModel
        self.timeout = timeout
        self.temperature = temperature
    }

    public var modelName: String { model }

    public func chat(_ messages: [ChatTurn], json: Bool) async throws -> LLMResult {
        do {
            return try await send(messages, json: json, model: model)
        } catch LLMError.modelMissing(let missing) {
            guard let fallbackModel, !fallbackModel.isEmpty, fallbackModel != model else {
                throw LLMError.modelMissing(missing)
            }
            return try await send(messages, json: json, model: fallbackModel)
        }
    }

    /// Lists installed models (GET /api/tags). Used by the Mac dashboard health check.
    public func installedModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let (data, response) = try await perform(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) from /api/tags")
        }
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        return tags.models.map { $0.name }
    }

    /// Loads the model into memory ahead of the first question (POST /api/generate with an empty
    /// prompt and keep_alive). The first load takes about 25 s on a MacBook Air M3; after that the
    /// model stays loaded for `keepAlive`. While Pasa runs as the AI peer it re-sends this every
    /// few minutes (see WarmthPolicy), so the model stays loaded as long as the app runs and is
    /// unloaded by Ollama about an hour after Pasa quits. Returns the model that was loaded.
    public static let keepAlive = "60m"

    @discardableResult
    public func warmUp() async throws -> String {
        let installed = (try? await installedModels()) ?? []
        var target = model
        if !installed.isEmpty, !installed.contains(model), !installed.contains(model + ":latest"),
           let fallbackModel, installed.contains(fallbackModel) {
            target = fallbackModel
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = max(timeout, 180)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(WarmRequest(model: target, prompt: "", stream: false, keep_alive: OllamaClient.keepAlive))
        let (data, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw LLMError.modelMissing(target) }
        guard status == 200 else {
            throw LLMError.badResponse(String((String(data: data, encoding: .utf8) ?? "HTTP \(status)").prefix(200)))
        }
        return target
    }

    // MARK: Internals

    /// Qwen3 and other thinking models answer faster with thinking off.
    /// Instruct-only variants (for example qwen3:4b-instruct) have no thinking switch, so "think" is not sent.
    static func usesThinking(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.contains("instruct") { return false }
        return m.hasPrefix("qwen3") || m.contains("deepseek-r1") || m.contains("gpt-oss")
    }

    static func prepare(_ messages: [ChatTurn], model: String) -> [ChatTurn] {
        guard model.lowercased().hasPrefix("qwen3") else { return messages }
        // Belt and braces for older Ollama builds that ignore "think": Qwen3 also honors /no_think.
        return messages.map { turn in
            guard turn.role == "user", !turn.content.hasPrefix("/no_think") else { return turn }
            return ChatTurn(role: turn.role, content: "/no_think\n" + turn.content)
        }
    }

    static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ messages: [ChatTurn], json: Bool, model: String) async throws -> LLMResult {
        let body = ChatRequest(
            model: model,
            messages: OllamaClient.prepare(messages, model: model),
            stream: false,
            think: OllamaClient.usesThinking(model) ? false : nil,
            format: json ? "json" : nil,
            options: ChatRequest.Options(temperature: temperature, num_ctx: PromptBudget.contextTokens),
            keep_alive: OllamaClient.keepAlive
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data)

        if status == 404 || (decoded?.error?.lowercased().contains("not found") ?? false) {
            throw LLMError.modelMissing(model)
        }
        guard status == 200, let decoded else {
            let detail = decoded?.error ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw LLMError.badResponse(String(detail.prefix(200)))
        }
        if let error = decoded.error { throw LLMError.badResponse(error) }

        return LLMResult(
            text: OllamaClient.stripThinking(decoded.message?.content ?? ""),
            model: decoded.model ?? model,
            evalCount: decoded.eval_count,
            evalDurationNs: decoded.eval_duration,
            totalDurationNs: decoded.total_duration,
            promptEvalCount: decoded.prompt_eval_count
        )
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw LLMError.timeout
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .badServerResponse, .resourceUnavailable:
                throw LLMError.notRunning
            default:
                throw LLMError.badResponse(error.localizedDescription)
            }
        }
    }

    // MARK: Wire types (snake_case to match the Ollama API)

    struct ChatRequest: Encodable {
        struct Options: Encodable {
            var temperature: Double
            var num_ctx: Int
        }
        var model: String
        var messages: [ChatTurn]
        var stream: Bool
        var think: Bool?
        var format: String?
        var options: Options
        var keep_alive: String
    }

    struct WarmRequest: Encodable {
        var model: String
        var prompt: String
        var stream: Bool
        var keep_alive: String
    }

    struct ChatResponse: Decodable {
        struct Message: Decodable {
            var role: String?
            var content: String?
        }
        var model: String?
        var message: Message?
        var done: Bool?
        var total_duration: Int64?
        var eval_count: Int?
        var eval_duration: Int64?
        var prompt_eval_count: Int?
        var error: String?
    }

    struct TagsResponse: Decodable {
        struct Model: Decodable {
            var name: String
            var digest: String?
        }
        var models: [Model]
    }

    /// Installed model name -> digest (sha256), for pinning the tested model.
    public func installedModelDigests() async throws -> [String: String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let (data, _) = try await perform(request)
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        var out: [String: String] = [:]
        for m in tags.models { if let d = m.digest { out[m.name] = d } }
        return out
    }

    /// Model tested for the hackathon on a MacBook Air M3 16 GB (Ollama 0.35.0, Oct 9, 2026).
    public static let testedModelDigest = "500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41"
    /// Non-thinking 4B build, used by default on Macs with less than 12 GB of memory.
    public static let lowMemoryModel = "qwen3:4b-instruct"
    public static let lowMemoryThreshold: UInt64 = 12 * 1024 * 1024 * 1024

    /// Default model for this Mac: qwen3:8b with 12 GB of memory or more, otherwise qwen3:4b-instruct.
    public static func recommendedModel(physicalMemory: UInt64) -> String {
        physicalMemory < lowMemoryThreshold ? lowMemoryModel : defaultModel
    }
}
