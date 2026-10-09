// VoiceAsk.swift
// Pasa: a voice note whose transcript starts by calling Pasa becomes an ask for the AI peer.
// Speech recognition writes "@pasa" in many ways: "At Pasa, remind Ana...", "Pasa, remind Ana...",
// "Hey Pasa remind Ana...", "@Pasa remind Ana...". A plain sentence that merely starts with the
// Tagalog word "pasa" ("Pasa lang...") is not a call: it needs a comma or colon after it.

import Foundation

public enum VoiceAsk {
    /// Spoken openers that always count as calling Pasa (a word boundary must follow).
    static let openers = ["@pasa", "@ pasa", "at pasa", "hey pasa", "hi pasa", "ok pasa", "okay pasa", "@libre", "at libre"]
    /// Bare "pasa" counts only when punctuation follows it.
    static let bareCalls = ["pasa,", "pasa:", "pasa!"]

    /// The question after the call, or nil when the transcript does not call Pasa.
    public static func extract(_ transcript: String) -> String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        var cut: Int?
        for opener in openers where lower.hasPrefix(opener) {
            let rest = lower.dropFirst(opener.count)
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            cut = opener.count
            break
        }
        if cut == nil {
            for call in bareCalls where lower.hasPrefix(call) {
                cut = call.count
                break
            }
        }
        guard let cut else { return nil }
        var tail = Substring(text.dropFirst(cut))
        while let c = tail.first, c == "," || c == ":" || c == "." || c == "!" || c == "?" || c == "-" || c.isWhitespace {
            tail = tail.dropFirst()
        }
        let question = String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }
}
