// People.swift
// Pasa: people's chosen display names ("Kyle", "Ana") mapped to mesh device ids ("iPhone 7597").
// The device id stays the mesh address (stable, saved on first launch). The name is what the UI
// shows and what "@pasa remind Ana ..." resolves against. Pure Swift, tested on Linux.

import Foundation

public enum PeopleDirectory {
    public static let maxNameLength = 40

    public enum Resolution: Equatable, Sendable {
        /// Exactly one device uses this name.
        case device(name: String, device: String)
        /// Several devices use this name: ask which one.
        case ambiguous(name: String, devices: [String])
        case none
    }

    /// Trims and shortens a typed display name. Empty means "not set".
    public static func clean(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.count > maxNameLength { name.removeLast() }
        return name
    }

    /// Case-insensitive exact match of a spoken name against chosen display names.
    /// `directory` maps device id -> display name.
    public static func resolve(_ raw: String, directory: [String: String]) -> Resolution {
        let key = NameMatcher.normalize(raw.replacingOccurrences(of: "@", with: ""))
        guard !key.isEmpty else { return .none }
        let hits = directory.filter { NameMatcher.normalize($0.value) == key }
        guard let first = hits.first else { return .none }
        if hits.count == 1 { return .device(name: first.value, device: first.key) }
        return .ambiguous(name: first.value, devices: hits.keys.sorted())
    }

    /// Label for a device in the UI: its chosen name when known, otherwise the device id.
    public static func label(for device: String, directory: [String: String]) -> String {
        if let name = directory[device], !name.isEmpty { return name }
        return device
    }
}

/// Light Markdown cleanup for AI replies before SwiftUI renders them with
/// AttributedString(markdown:, .inlineOnlyPreservingWhitespace). Inline-only parsing keeps line
/// breaks but does not draw list markers, so bullets are turned into "•" here, headings lose
/// their "#", and an unmatched ** or ` is left as plain text by the renderer's fallback.
public enum MarkdownLite {
    public static func prepare(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return lines.map { line -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(indent.count)
            for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
                let pad = indent.count >= 2 ? "    " : ""
                return pad + "• " + rest.dropFirst(marker.count)
            }
            if rest.hasPrefix("#") {
                let stripped = rest.drop { $0 == "#" }
                if stripped.hasPrefix(" ") { return "**" + stripped.dropFirst() + "**" }
            }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Plain text with Markdown markers removed, for previews and the fallback path.
    public static func plain(_ raw: String) -> String {
        var text = prepare(raw)
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        return text
    }
}

/// Default name for an AI Mac whose owner never typed one (round 2): "Kyle's Mac" from the first
/// word of the macOS full user name, else the computer name cleaned up ("kyles-macbook-air" ->
/// "Kyles MacBook Air", "Kyle's MaC" -> "Kyle's Mac"). An explicitly set name always wins; the
/// caller only uses this when the saved name is empty.
public enum MacName {
    public static func suggested(fullUserName: String?, hostName: String?) -> String {
        let first = (fullUserName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if !first.isEmpty, first.rangeOfCharacter(from: .letters) != nil {
            return PeopleDirectory.clean(first + "'s Mac")
        }
        let host = cleanHost(hostName ?? "")
        return host.isEmpty ? "Mac" : host
    }

    public static func cleanHost(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".local") { text = String(text.dropLast(6)) }
        text = text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let fixed: [String: String] = ["mac": "Mac", "macbook": "MacBook", "imac": "iMac", "mini": "mini",
                                       "air": "Air", "pro": "Pro", "studio": "Studio"]
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { raw -> String in
            let word = String(raw)
            if let known = fixed[word.lowercased()] { return known }
            if word == word.lowercased(), let head = word.first { return head.uppercased() + word.dropFirst() }
            return word
        }
        return PeopleDirectory.clean(words.joined(separator: " "))
    }
}
