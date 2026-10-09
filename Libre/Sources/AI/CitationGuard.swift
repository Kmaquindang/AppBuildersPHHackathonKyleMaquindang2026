// CitationGuard.swift
// Pasa: checks every [Rule: ...], [Skill: ...] and [Note: ...] tag in a model answer against the
// team memory before the answer leaves the Mac. Pure Swift, tested on Linux.
// - A tag that names a saved rule or skill is rewritten to its exact current citation (fixes a
//   wrong or missing version, for example "v1" after the rule moved to v2).
// - A tag that names nothing saved is kept but marked "(unverified)", so nobody mistakes an
//   invented rule for a real one.

import Foundation

public enum CitationGuard {
    public static let unverifiedMark = "(unverified)"

    public struct Result: Equatable, Sendable {
        public var text: String
        /// Citations that matched saved memory (exact current form).
        public var verified: [String]
        /// Tags that matched nothing saved.
        public var unverified: [String]
    }

    private static let pattern = try! NSRegularExpression(pattern: #"\[(Rule|Skill|Note)\s*:\s*([^\]\n]{1,200})\](\s*\(unverified\))?"#, options: [.caseInsensitive])
    private static let versionSuffix = try! NSRegularExpression(pattern: #"\s+v\d+\s*$"#, options: [.caseInsensitive])

    public static func validate(_ text: String, rules: [RuleEntry], notes: [Note]) -> Result {
        let active = rules.filter { !$0.isRetired }
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Result(text: text, verified: [], unverified: []) }

        var output = ""
        var cursor = 0
        var verified: [String] = []
        var unverified: [String] = []
        for match in matches {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let kind = ns.substring(with: match.range(at: 1)).lowercased()
            let rawName = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let tag = "[" + ns.substring(with: match.range(at: 1)) + ": " + rawName + "]"

            var replacement: String?
            if kind == "note" {
                let key = NameMatcher.normalize(rawName)
                replacement = notes.first { NameMatcher.normalize($0.title) == key }?.citation
            } else {
                let nameNS = rawName as NSString
                let title = versionSuffix.stringByReplacingMatches(in: rawName, range: NSRange(location: 0, length: nameNS.length), withTemplate: "")
                let key = NameMatcher.normalize(title)
                // Rule and Skill tags both resolve against every saved rule or skill by title.
                replacement = active.first { NameMatcher.normalize($0.title) == key }?.citation
            }
            if let replacement {
                output += replacement
                verified.append(replacement)
            } else {
                output += tag + " " + unverifiedMark
                unverified.append(tag)
            }
        }
        output += ns.substring(from: cursor)
        return Result(text: output, verified: verified, unverified: unverified)
    }
}
