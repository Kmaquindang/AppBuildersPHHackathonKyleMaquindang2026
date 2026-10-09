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

    /// Devices whose chosen name is in `names` (case-insensitive). Used so an admin listed by
    /// name ("Kyle") also covers the device Kyle uses.
    public static func devices(named names: [String], directory: [String: String]) -> Set<String> {
        let keys = Set(names.map { NameMatcher.normalize($0) }.filter { !$0.isEmpty })
        return Set(directory.filter { keys.contains(NameMatcher.normalize($0.value)) }.map { $0.key })
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
