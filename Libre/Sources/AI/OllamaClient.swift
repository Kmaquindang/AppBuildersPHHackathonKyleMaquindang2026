// OllamaClient.swift
// Libre: talks to Ollama on the same Mac (default http://127.0.0.1:11434), non-streaming /api/chat.
// No internet involved: Ollama serves the model from local disk.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
            options: ChatRequest.Options(temperature: temperature, num_ctx: 8192),
            keep_alive: "30m"
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
            totalDurationNs: decoded.total_duration
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
        var error: String?
    }

    struct TagsResponse: Decodable {
        struct Model: Decodable { var name: String }
        var models: [Model]
    }
}
