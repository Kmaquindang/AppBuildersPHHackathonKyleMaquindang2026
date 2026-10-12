// LLMClient.swift
// Pasa: minimal chat interface to a local language model. Pure Foundation.

import Foundation

public struct ChatTurn: Codable, Hashable, Sendable {
    public var role: String     // "system", "user" or "assistant"
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatTurn { ChatTurn(role: "system", content: text) }
    public static func user(_ text: String) -> ChatTurn { ChatTurn(role: "user", content: text) }
}

public struct LLMResult: Sendable {
    public var text: String
    public var model: String
    /// Tokens generated (Ollama eval_count).
    public var evalCount: Int?
    /// Generation time in nanoseconds (Ollama eval_duration).
    public var evalDurationNs: Int64?
    /// Whole request time in nanoseconds (Ollama total_duration).
    public var totalDurationNs: Int64?
    /// Prompt tokens the model actually read (Ollama prompt_eval_count).
    public var promptEvalCount: Int?

    public init(text: String, model: String, evalCount: Int? = nil, evalDurationNs: Int64? = nil, totalDurationNs: Int64? = nil, promptEvalCount: Int? = nil) {
        self.promptEvalCount = promptEvalCount
        self.text = text
        self.model = model
        self.evalCount = evalCount
        self.evalDurationNs = evalDurationNs
        self.totalDurationNs = totalDurationNs
    }

    public var tokensPerSecond: Double? {
        guard let evalCount, let evalDurationNs, evalDurationNs > 0 else { return nil }
        return Double(evalCount) / (Double(evalDurationNs) / 1_000_000_000)
    }
}

public enum LLMError: Error, Equatable, LocalizedError, Sendable {
    case notRunning
    case timeout
    case modelMissing(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Start Ollama on the Mac (open the Ollama app or run `ollama serve`), then ask again."
        case .timeout:
            return "Ollama took too long. The model may still be loading; ask again in a moment."
        case .modelMissing(let model):
            return "Model \(model) is not installed. On the Mac run: ollama pull \(model)"
        case .badResponse(let detail):
            return "Ollama returned an error: \(detail)"
        }
    }
}

public protocol LLMClient: Sendable {
    var modelName: String { get }
    /// - Parameter json: ask the model for a single JSON object (Ollama format "json").
    func chat(_ messages: [ChatTurn], json: Bool) async throws -> LLMResult
    /// Same, with a cap on generated tokens (Ollama num_predict). nil means no cap.
    func chat(_ messages: [ChatTurn], json: Bool, maxTokens: Int?) async throws -> LLMResult
}

/// A client that hands out text while the model writes (Ollama's streamed /api/chat). Used for
/// streamed @libre answers (issue #2). The result is the same whole reply `chat` would return.
public protocol StreamingLLMClient: LLMClient {
    func chatStream(_ messages: [ChatTurn], maxTokens: Int?, onDelta: @escaping @Sendable (String) -> Void) async throws -> LLMResult
}

public extension LLMClient {
    /// Clients without a token cap (test fakes) ignore it.
    func chat(_ messages: [ChatTurn], json: Bool, maxTokens: Int?) async throws -> LLMResult {
        try await chat(messages, json: json)
    }
}

/// Generation caps per call (tokens). Short caps keep a chat reply fast and phone-sized; they
/// are well above what the prompts ask for, so a normal reply is never cut.
public enum TokenCaps {
    /// Intent JSON (a rule body can be a few sentences).
    public static let classify = 200
    /// Chat answer: at most 2 or 3 short sentences plus citations.
    public static let answer = 180
    /// Catch-up: 3 short lines.
    public static let summarize = 220
}
