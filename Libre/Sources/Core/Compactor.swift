// Compactor.swift
// Keeps AI replies small enough for the mesh: a short first packet plus the rest on request.

import Foundation

public enum Compactor {
    public static let firstPacketLimit = 300
    public static let moreHint = " (say \"@libre more\" for the rest)"

    /// Splits `text` into a first packet of at most `limit` characters (hint included) and the remainder.
    public static func split(_ text: String, limit: Int = firstPacketLimit) -> (first: String, rest: String?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= limit { return (clean, nil) }

        let budget = max(40, limit - moreHint.count)
        let head = String(clean.prefix(budget))
        var cut = head.endIndex
        // Prefer a sentence or line end in the back half of the budget, then a space.
        let enders: [Character] = [".", "!", "?", "\n"]
        if let idx = head.lastIndex(where: { enders.contains($0) }), head.distance(from: head.startIndex, to: idx) >= budget / 2 {
            cut = head.index(after: idx)
        } else if let idx = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: idx) >= budget / 2 {
            cut = idx
        }
        let first = String(head[head.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let restStart = clean.index(clean.startIndex, offsetBy: first.count)
        let rest = String(clean[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (first + moreHint, rest.isEmpty ? nil : rest)
    }
}
