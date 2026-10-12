// PeerSync.swift
// Libre: phone-to-phone history sync without the AI Mac (issue #6, Oct 2026). Our own design.
//
// When two phones link, each asks the other for the active room's team chat from the last 6 hours
// that it does not have. The ask is the existing `.sync` request with two optional fields:
// `window` (start time) and `knownShort` (12-hex-character ids of the chat it already has, newest
// 400). The other phone answers with ordinary sync batches, so a phone that walks from one group to
// another carries the first group's chat along, even when no Mac is near. Builds without the
// fields never answer phone requests (only the AI Mac answers plain backfill requests), so mixing
// builds is safe.
// Only broadcast team chat travels this way: answers belong to their asker, and rules, tasks,
// Knowledge, photos and voice notes come from the AI Mac. Everything stays sealed with the room
// key, so only room members can read or store it. Batches ride the bulk Bluetooth lane.

import Foundation

public enum PeerSync {
    public static let window: TimeInterval = 6 * 3600
    public static let maxKnown = 400
    public static let maxMessages = 100
    public static let maxBytes = 36_000
    /// Ask the same peer again at most this often (on each new link).
    public static let askEvery: TimeInterval = 120
    /// Answer the same peer at most this often.
    public static let answerEvery: TimeInterval = 60
    /// Messages stamped further than this in the future are not sent (bad clocks).
    public static let futureSlack: TimeInterval = 300

    /// 12 hex characters of the id (48 bits): plenty for a few hundred messages, a third of a UUID.
    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    static func isTeamChat(_ m: MeshMessage) -> Bool { m.kind == .chat && m.destination == nil && m.silent != true }

    /// The request this phone sends a newly linked peer.
    public static func request(from entries: [ChatEntry], now: Date = Date(), clearedAt: Date? = nil) -> SyncRequest {
        let start = max(now.addingTimeInterval(-window), clearedAt ?? .distantPast)
        var seen = Set<UUID>()
        let mine = entries.map(\.message).filter { isTeamChat($0) && $0.createdAt >= start && seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
        var r = SyncRequest(newest: mine.last?.createdAt, knownIDs: [], clearedAt: clearedAt)
        r.window = start
        r.knownShort = mine.suffix(maxKnown).map { shortID($0.id) }
        return r
    }

    /// Team chat from `entries` the requester is missing, oldest first. Capped by count and by
    /// encoded size (the newest are kept). Empty for a request that is not a peer request.
    public static func select(from entries: [ChatEntry], request: SyncRequest, now: Date = Date(), clearedAt: Date? = nil) -> [MeshMessage] {
        guard let start = request.window else { return [] }
        let floor = max(start, request.clearedAt ?? .distantPast, clearedAt ?? .distantPast)
        let known = Set(request.knownShort ?? [])
        var seen = Set<UUID>()
        var picked = entries.map(\.message).filter { m in
            isTeamChat(m) && m.createdAt >= floor && m.createdAt <= now.addingTimeInterval(futureSlack)
                && !known.contains(shortID(m.id)) && seen.insert(m.id).inserted
        }
        picked.sort { $0.createdAt < $1.createdAt }
        if picked.count > maxMessages { picked.removeFirst(picked.count - maxMessages) }
        var bytes = 0
        var kept: [MeshMessage] = []
        for m in picked.reversed() {
            let size = (try? MeshCodec.encode(m).count) ?? 512
            if bytes + size > maxBytes { break }
            bytes += size
            kept.append(m)
        }
        return kept.reversed()
    }
}
