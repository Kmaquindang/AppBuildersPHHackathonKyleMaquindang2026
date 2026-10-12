// RelayScheduler.swift
// Libre: when to relay, and when not to bother (Oct 12, 2026). Pure Swift, tested on Linux.
// Our own design.
//
// RelayEngine decides IF a packet travels on. Over Bluetooth every extra copy costs real airtime,
// so this decides WHEN and whether it is still needed:
// - Random jitter before relaying: broadcasts wait 10 to 120 ms (30 to 250 ms in a dense room,
//   5 or more links), directed packets (asks, answers to one device) 0 to 30 ms. Neighbors that
//   heard the same packet pick different delays, so most of the time one of them goes first.
// - Cancel when a duplicate is heard: each copy heard from a neighbor removes that neighbor from
//   the targets (it already has it). When no target is left, the relay is cancelled. In a dense
//   room a broadcast is also cancelled after 2 copies are heard from others (enough of the room
//   already has it). Directed packets are never cancelled that way, only when every target has it.
// - Adaptive hop budget: in a dense room (6 or more links) a relayed broadcast keeps at most 4
//   more hops, so it does not echo around a crowd. Sparse chains keep the full budget.

import Foundation

public enum RelayPolicy {
    public static let denseLinks = 5
    public static let crowdLinks = 6
    public static let crowdBroadcastTTL = 4
    public static let denseCancelCopies = 2

    /// Hop budget a relay forwards with, given the already decremented `ttl` and how many links
    /// this device has.
    public static func forwardTTL(_ ttl: Int, links: Int, broadcast: Bool) -> Int {
        guard broadcast, links >= crowdLinks else { return ttl }
        return min(ttl, crowdBroadcastTTL)
    }

    /// Jitter range in milliseconds.
    public static func jitterRange(broadcast: Bool, links: Int) -> ClosedRange<Int> {
        if !broadcast { return 0...30 }
        return links >= denseLinks ? 30...250 : 10...120
    }
}

public struct RelayScheduler<Item: Sendable>: Sendable {
    public struct Pending: Sendable {
        public var id: UUID
        public var item: Item
        public var due: Date
        public var broadcast: Bool
        public var links: Int
        /// Neighbors still missing it (the ones it will be sent to).
        public var targets: Set<String>
        /// Neighbors we heard a copy from while waiting (add them to `excluding` when sending).
        public var heardFrom: Set<String> = []
        public var copiesHeard = 0
    }

    public private(set) var pending: [UUID: Pending] = [:]
    public private(set) var cancelledCount = 0

    public init() {}

    /// Schedules a relay. Returns the delay chosen. `random` picks within the jitter range.
    @discardableResult
    public mutating func schedule(_ id: UUID, item: Item, targets: Set<String>, broadcast: Bool, links: Int, now: Date = Date(),
                                  random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> TimeInterval {
        let ms = random(RelayPolicy.jitterRange(broadcast: broadcast, links: links))
        let delay = TimeInterval(ms) / 1000
        pending[id] = Pending(id: id, item: item, due: now.addingTimeInterval(delay), broadcast: broadcast, links: links, targets: targets)
        return delay
    }

    /// A duplicate of `id` arrived from `neighbor`. Returns true when that cancelled the relay.
    @discardableResult
    public mutating func heardDuplicate(_ id: UUID, from neighbor: String) -> Bool {
        guard var p = pending[id] else { return false }
        p.targets.remove(neighbor)
        p.heardFrom.insert(neighbor)
        p.copiesHeard += 1
        let everyoneHasIt = p.targets.isEmpty
        let crowdHasIt = p.broadcast && p.links >= RelayPolicy.denseLinks && p.copiesHeard >= RelayPolicy.denseCancelCopies
        if everyoneHasIt || crowdHasIt {
            pending.removeValue(forKey: id)
            cancelledCount += 1
            return true
        }
        pending[id] = p
        return false
    }

    /// Relays whose time has come, oldest first. They are removed.
    public mutating func due(now: Date = Date()) -> [Pending] {
        let ready = pending.values.filter { $0.due <= now }.sorted { $0.due < $1.due }
        for p in ready { pending.removeValue(forKey: p.id) }
        return ready
    }

    /// Earliest due time, for the caller's timer.
    public var nextDue: Date? { pending.values.map(\.due).min() }
}
