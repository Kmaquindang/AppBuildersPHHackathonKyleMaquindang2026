// MeshPolicy.swift
// Pasa: small pure-Swift decisions the mesh service makes, kept here so they are unit tested on
// Linux: which rule and task updates show as timeline cards, how a phone applies the Mac's
// memory manifest, who counts as an admin, which asks are still waiting for the AI, and the
// forced-relay badge text. Added Oct 9, 2026 (scenario review, top 8).

import Foundation

/// What the Mac holds, sent to a phone when it links (inside a `.sync` message). The Mac is the
/// source of truth: the phone drops cached rules and tasks whose ids are not listed, and adopts
/// the Mac's timeline watermark so a team-wide clear sticks.
public struct MemoryManifest: Codable, Equatable, Sendable {
    /// Every rule id on the Mac, tombstones included.
    public var ruleIDs: [UUID]
    /// Task ids on the Mac (newest few hundred).
    public var taskIDs: [UUID]
    /// When the Mac last reset team memory.
    public var resetAt: Date?
    /// When the Mac last cleared the team timeline. Phones drop older timeline entries.
    public var clearedAt: Date?
    /// Knowledge titles this phone may see (filtered by its role on the Mac). nil from older Macs.
    public var library: [LibraryListing]? = nil

    public init(ruleIDs: [UUID], taskIDs: [UUID], resetAt: Date?, clearedAt: Date?, library: [LibraryListing]? = nil) {
        self.ruleIDs = ruleIDs
        self.taskIDs = taskIDs
        self.resetAt = resetAt
        self.clearedAt = clearedAt
        self.library = library
    }
}

public enum CacheSync {
    /// Phone side: merge a `.rule` or `.task` message into the cached memory.
    /// - changed: the cache actually changed (new item, newer version, or a deletion).
    /// - show: add a card to the timeline. Only when the cache changed and the message is not a
    ///   silent sync-on-link update. Repeats (the same rule version sent again after a
    ///   reconnect) never add a card.
    public static func applyCard(_ message: MeshMessage, to memory: OrgMemory) -> (changed: Bool, show: Bool) {
        var changed = false
        switch message.kind {
        case .rule:
            if let rule = MeshPayload.decodeRule(message.body) { changed = memory.mergeRule(rule) }
        case .task:
            if let task = MeshPayload.decodeTask(message.body) { changed = memory.mergeTask(task) }
        default:
            return (false, false)
        }
        return (changed, changed && message.silent != true)
    }

    /// Phone side: apply the Mac's manifest. Returns true when cached rules or tasks were dropped.
    @discardableResult
    public static func applyManifest(_ manifest: MemoryManifest, to memory: OrgMemory) -> Bool {
        memory.prune(keepingRuleIDs: Set(manifest.ruleIDs), taskIDs: Set(manifest.taskIDs))
    }

    /// The later of two optional watermarks.
    public static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }
}

public enum AdminPolicy {
    /// Admin devices: the device ids ticked in the Mac's Settings plus the Mac itself.
    /// Display names are never used: anyone can pick any name in Settings.
    public static func devices(adminIDs: [String], selfID: String) -> Set<String> {
        Set(adminIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).union([selfID])
    }

    /// One-time migration from the old "admins by device id or name" text field: keep only
    /// entries that are a known device id. Names (and the old placeholder "iPhone 14 Pro Max",
    /// which never matched a real device) are dropped; the Mac operator ticks admins again.
    public static func migrate(legacy: [String], knownDevices: Set<String>) -> [String] {
        var seen = Set<String>()
        return legacy.filter { knownDevices.contains($0) && seen.insert($0).inserted }
    }

    /// Devices the Mac can offer as admin choices: everything it has seen, minus itself.
    public static func candidates(seen: [String], directory: [String: String], admins: [String], selfID: String) -> [String] {
        Array(Set(seen).union(directory.keys).union(admins)).filter { $0 != selfID && !$0.isEmpty }.sorted()
    }
}

public enum AskWatch {
    /// An ask with no answer after this long shows "Waiting for the AI Mac" on the asker.
    public static let waitingAfter: TimeInterval = 20
    /// Asks older than this are forgotten (the answer, if it ever comes, still shows).
    public static let forgetAfter: TimeInterval = 86_400

    public static func waiting(_ sentAsks: [UUID: Date], now: Date = Date(), after: TimeInterval = waitingAfter) -> Set<UUID> {
        Set(sentAsks.filter { now.timeIntervalSince($0.value) >= after }.map { $0.key })
    }

    public static func pruned(_ sentAsks: [UUID: Date], now: Date = Date()) -> [UUID: Date] {
        sentAsks.filter { now.timeIntervalSince($0.value) < forgetAfter }
    }
}

public enum ForcedRelayStatus {
    /// Badge text when a block is active, nil otherwise. `labels` are display names or ids.
    public static func badge(blocked labels: [String]) -> String? {
        let names = labels.filter { !$0.isEmpty }.sorted()
        guard !names.isEmpty else { return nil }
        return "Forced relay mode: no direct link to \(names.joined(separator: ", "))"
    }
}
