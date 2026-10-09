// NameMatcher.swift
// Matches a spoken name ("ana", "the 12", "iphone 14") to a known person or device name.
// Pure Swift. Returns nil when nothing matches or when the match is ambiguous.

import Foundation

public enum NameMatcher {
    public static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Best unique candidate for `raw`, or nil.
    public static func match(_ raw: String, in candidates: [String]) -> String? {
        let query = normalize(raw.replacingOccurrences(of: "@", with: ""))
        guard !query.isEmpty else { return nil }
        let unique = Array(Set(candidates.filter { !normalize($0).isEmpty }))

        // 1. Exact (normalized).
        let exact = unique.filter { normalize($0) == query }
        if exact.count == 1 { return exact[0] }

        // 2. Prefix either way ("ana" vs "ana reyes", "iphone 14 pro max" vs "iphone 14").
        let prefix = unique.filter {
            let c = normalize($0)
            return c.hasPrefix(query + " ") || query.hasPrefix(c + " ")
        }
        if prefix.count == 1 { return prefix[0] }

        // 3. Distinctive shared word (length >= 2, not shared by several candidates).
        let queryWords = Set(query.split(separator: " ").map(String.init))
        var scores: [String: Int] = [:]
        for candidate in unique {
            let words = Set(normalize(candidate).split(separator: " ").map(String.init))
            for word in queryWords.intersection(words) where word.count >= 2 {
                let holders = unique.filter { Set(normalize($0).split(separator: " ").map(String.init)).contains(word) }.count
                if holders == 1 { scores[candidate, default: 0] += 1 }
            }
        }
        let best = scores.max { $0.value < $1.value }
        if let best, scores.values.filter({ $0 == best.value }).count == 1 {
            return best.key
        }
        return nil
    }
}
