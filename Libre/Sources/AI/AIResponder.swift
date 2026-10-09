// AIResponder.swift
// Pasa: simple question -> answer seam for the AI peer.
// - EchoResponder: milestone 1 stub, no model.
// - OllamaResponder: plain local-model answers through Ollama (no team memory).
// The full executive assistant (intents, tasks, rules, notes) lives in ExecutiveAssistant.swift.

import Foundation

/// A reply ready to go back over the mesh.
public struct AIReply: Sendable {
    public var text: String
    /// True when `text` is a shortened first packet.
    public var compact: Bool
    public var model: String?
    public var latencyMs: Int
    public var tokensPerSecond: Double?
    /// Rule and note titles the model was shown for this answer.
    public var checked: [String]?
    /// Structured grounding (see AnswerStyle): rule chips, invented tags, and "no rule used".
    public var rulesUsed: [String]?
    public var unverifiedRules: [String]?
    public var noRule: Bool?
    /// Knowledge passages the answer used (chips with a capped excerpt).
    public var docRefs: [DocRef]? = nil

    public init(text: String, compact: Bool = false, model: String? = nil, latencyMs: Int = 0, tokensPerSecond: Double? = nil, checked: [String]? = nil,
                rulesUsed: [String]? = nil, unverifiedRules: [String]? = nil, noRule: Bool? = nil) {
        self.checked = checked
        self.rulesUsed = rulesUsed
        self.unverifiedRules = unverifiedRules
        self.noRule = noRule
        self.text = text
        self.compact = compact
        self.model = model
        self.latencyMs = latencyMs
        self.tokensPerSecond = tokensPerSecond
    }
}

/// Anything that can turn a question that arrived over the mesh into a short answer.
public protocol AIResponder: Sendable {
    /// Human readable name shown in the UI, for example "Echo stub" or "Ollama (qwen3:8b)".
    var name: String { get }
    func respond(to question: String, from asker: String) async throws -> AIReply
}

/// Milestone 1 stub: proves the ask -> answer round trip without any model.
public struct EchoResponder: AIResponder {
    public init() {}
    public var name: String { "Echo stub" }

    public func respond(to question: String, from asker: String) async throws -> AIReply {
        AIReply(text: "AI peer received: \(question)")
    }
}

/// Plain local-model answers, compacted for the mesh.
public struct OllamaResponder: AIResponder {
    public var client: OllamaClient

    public init(client: OllamaClient = OllamaClient()) {
        self.client = client
    }

    public var name: String { "Ollama (\(client.model))" }

    public func respond(to question: String, from asker: String) async throws -> AIReply {
        let started = Date()
        let result = try await client.chat([
            .system("You are Libre, a helpful assistant running offline on a laptop for people with no internet. Answer in plain text, at most 3 short sentences."),
            .user(question)
        ], json: false)
        let parts = Compactor.split(result.text)
        return AIReply(
            text: parts.first,
            compact: parts.rest != nil,
            model: result.model,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            tokensPerSecond: result.tokensPerSecond
        )
    }
}
