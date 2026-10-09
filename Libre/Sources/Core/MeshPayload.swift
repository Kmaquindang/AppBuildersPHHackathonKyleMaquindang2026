// MeshPayload.swift
// Task and rule updates travel as JSON inside MeshMessage.body (kind .task / .rule).

import Foundation

public enum MeshPayload {
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    public static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeTask(_ body: String) -> TaskItem? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? decoder().decode(TaskItem.self, from: data)
    }

    public static func decodeRule(_ body: String) -> RuleEntry? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? decoder().decode(RuleEntry.self, from: data)
    }

    /// Human readable line for the timeline.
    public static func displayText(for message: MeshMessage) -> String {
        switch message.kind {
        case .task:
            guard let task = decodeTask(message.body) else { return message.body }
            return task.status == .done ? "Task done: \(task.shortLine)" : "Task: \(task.shortLine)"
        case .rule:
            guard let rule = decodeRule(message.body) else { return message.body }
            if rule.isRetired { return "\(rule.kind.label) deleted: \(rule.title) (by \(rule.retiredBy ?? rule.updatedBy))" }
            return "\(rule.citation)\(rule.locked ? " (locked)" : "") \(rule.body)"
        case .sync:
            return "Sync"
        case .media:
            return MediaManifest.decode(message.body)?.displayLine ?? "Media"
        case .transcript:
            return TranscriptPayload.decode(message.body)?.displayLine ?? message.body
        case .chunk, .mediaNack, .roomControl, .beacon, .aiStatus:
            return ""
        default:
            return message.body
        }
    }
}
