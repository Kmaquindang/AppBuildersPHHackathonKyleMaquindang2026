// AIResponder.swift
// Libre: seam for the AI peer. Milestone 1 ships a stub echo so the mesh round trip can be
// tested end to end. Milestone 2 adds an Ollama-backed responder (local model on the Mac,
// http://localhost:11434/api/chat) that conforms to the same protocol.

import Foundation

/// Anything that can turn a question that arrived over the mesh into a short answer.
protocol AIResponder: Sendable {
    /// Human readable name shown in the UI, for example "Echo stub" or "Ollama (model)".
    var name: String { get }
    /// - Parameters:
    ///   - question: the body of the `ask` message.
    ///   - asker: display name of the device that asked.
    /// - Returns: the answer text to send back over the mesh. Keep it short; it travels hop by hop.
    func respond(to question: String, from asker: String) async throws -> String
}

/// Milestone 1 stub: proves the ask -> answer round trip without any model.
struct EchoResponder: AIResponder {
    var name: String { "Echo stub (milestone 1)" }

    func respond(to question: String, from asker: String) async throws -> String {
        "AI peer received: \(question)"
    }
}

// Milestone 2 sketch (not compiled yet, kept as a comment so milestone 1 has no network code):
//
// struct OllamaResponder: AIResponder {
//     var model: String
//     var endpoint = URL(string: "http://localhost:11434/api/chat")!
//     var name: String { "Ollama (\(model))" }
//     func respond(to question: String, from asker: String) async throws -> String {
//         // POST {"model": model, "stream": false, "messages": [system, user]}
//         // decode response.message.content, trim to a mesh-friendly length.
//     }
// }
