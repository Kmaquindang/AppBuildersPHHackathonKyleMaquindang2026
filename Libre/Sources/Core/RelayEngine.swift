// RelayEngine.swift
// Pasa: our own multi-hop relay layer that sits on top of any transport.
// Pure Swift (Foundation only), no Apple frameworks, so it is unit tested on Linux.
//
// Rules (controlled flooding with a hop budget):
// 1. Drop a message whose id was already seen (dedup cache with expiry and a size cap).
// 2. Append this device to the hop path.
// 3. Deliver locally if it is a broadcast, addressed to this device, or to a role this device holds.
// 4. If ttl > 1 and the message still needs to travel, forward a copy with ttl - 1
//    to every connected peer except the ones already on the path (which includes the sender).
// 5. If no peer is available to forward to, the caller parks it in the outbox (store and forward).

import Foundation

/// What the transport layer should do with an incoming message.
public struct RelayDecision: Sendable {
    /// True when the message id was already seen. Nothing else should happen.
    public var isDuplicate: Bool
    /// Copy to show or handle on this device (hop path includes this device). nil when not for us.
    public var deliver: MeshMessage?
    /// Copy to send on to other peers (ttl already decremented). nil when it should stop here.
    public var forward: MeshMessage?
    /// Peers that must not receive the forwarded copy (everyone already on the path).
    public var forwardExcluding: Set<String>

    public static let duplicate = RelayDecision(isDuplicate: true, deliver: nil, forward: nil, forwardExcluding: [])
}

/// A message waiting for a peer to connect. Codable so the outbox survives an app restart.
public struct OutboxItem: Codable, Equatable, Sendable {
    public var message: MeshMessage
    public var excluding: Set<String>
    public var queuedAt: Date
    /// Another room's packet this device only relays. Capped and short-lived.
    public var foreign: Bool?
}

public final class RelayEngine {
    public private(set) var selfName: String
    public var roles: Set<String>
    /// Tag of this device's active room. A sealed packet of another room is never "for" one of
    /// our roles, so an "@ai" ask from room B passes through room A's AI Mac to room B's.
    public var roomID: String?
    /// Multi-room AI Mac: more rooms whose "@ai" asks this device answers.
    public var extraRoomIDs: Set<String> = []
    /// Chosen display name stamped on every outgoing message (nil until the person picks one).
    public var senderName: String?

    public let seenLifetime: TimeInterval
    public let maxSeen: Int
    public let outboxLifetime: TimeInterval
    public let maxOutbox: Int
    /// Other rooms' packets: at most this many queued, for at most this long.
    public let maxForeign = 50
    public let foreignLifetime: TimeInterval = 3600

    private var seen: [UUID: Date] = [:]
    public private(set) var outbox: [OutboxItem] = []

    public init(
        selfName: String,
        roles: Set<String> = [],
        seenLifetime: TimeInterval = 300,
        maxSeen: Int = 1000,
        outboxLifetime: TimeInterval = 86_400,   // a day: queued messages survive restarts and wait for a link
        maxOutbox: Int = 200
    ) {
        self.selfName = selfName
        self.roles = roles
        self.seenLifetime = seenLifetime
        self.maxSeen = maxSeen
        self.outboxLifetime = outboxLifetime
        self.maxOutbox = maxOutbox
    }

    /// Number of ids currently remembered (for tests and diagnostics).
    public var seenCount: Int { seen.count }

    public func rename(to newName: String) {
        selfName = newName
    }

    // MARK: Addressing

    public func isAddressedToMe(_ message: MeshMessage) -> Bool {
        guard let destination = message.destination else { return true }
        switch destination {
        case .peer(let name): return name == selfName
        case .role(let role):
            if message.kind == .sealed, let roomID, message.room != roomID, !extraRoomIDs.contains(message.room ?? "") { return false }
            return roles.contains(role)
        }
    }

    // MARK: Outgoing

    /// Builds a new message that originates on this device and remembers its id,
    /// so echoes of our own message coming back through the mesh are dropped.
    public func makeOutgoing(
        kind: MessageKind,
        body: String,
        destination: MeshDestination? = nil,
        ttl: Int = MeshMessage.defaultTTL,
        replyTo: UUID? = nil,
        replyPath: [String]? = nil,
        now: Date = Date()
    ) -> MeshMessage {
        let message = MeshMessage(
            origin: selfName,
            destination: destination,
            kind: kind,
            body: body,
            ttl: ttl,
            hops: [selfName],
            createdAt: now,
            replyTo: replyTo,
            replyPath: replyPath,
            senderName: senderName,
            v: MeshMessage.protocolVersion
        )
        markSeen(message.id, now: now)
        return message
    }

    public func markSeen(_ id: UUID, now: Date = Date()) {
        prune(now: now)
        seen[id] = now
        if seen.count > maxSeen {
            let overflow = seen.count - maxSeen
            let oldest = seen.sorted { $0.value < $1.value }.prefix(overflow).map { $0.key }
            for key in oldest { seen.removeValue(forKey: key) }
        }
    }

    public func hasSeen(_ id: UUID, now: Date = Date()) -> Bool {
        prune(now: now)
        return seen[id] != nil
    }

    // MARK: Incoming

    /// Core relay decision. `sender` is the display name of the directly connected peer it came from.
    public func handleIncoming(_ message: MeshMessage, from sender: String, now: Date = Date()) -> RelayDecision {
        if hasSeen(message.id, now: now) { return .duplicate }
        markSeen(message.id, now: now)

        // Our own message looped back (should be covered by dedup, kept as a guard).
        if message.origin == selfName { return .duplicate }

        var here = message
        if here.hops.last != sender && sender != selfName && !here.hops.contains(sender) {
            // The sender did not stamp itself (should not happen with our code). Keep the path honest.
            here.hops.append(sender)
        }
        here.hops.append(selfName)

        let forMe = isAddressedToMe(message)
        let deliver: MeshMessage? = forMe ? here : nil

        // Unicast and role messages stop at the first device that handles them.
        // Broadcasts keep spreading until the hop budget runs out.
        let needsToTravel = message.isBroadcast || !forMe
        var forward: MeshMessage? = nil
        if needsToTravel && message.ttl > 1 {
            var copy = here
            copy.ttl = message.ttl - 1
            forward = copy
        }

        return RelayDecision(
            isDuplicate: false,
            deliver: deliver,
            forward: forward,
            forwardExcluding: Set(here.hops)
        )
    }

    // MARK: Store and forward

    public func enqueue(_ message: MeshMessage, excluding: Set<String> = [], foreign: Bool = false, now: Date = Date()) {
        pruneOutbox(now: now)
        if outbox.contains(where: { $0.message.id == message.id }) { return }
        outbox.append(OutboxItem(message: message, excluding: excluding, queuedAt: now, foreign: foreign ? true : nil))
        let foreignIndexes = outbox.indices.filter { outbox[$0].foreign == true }
        if foreignIndexes.count > maxForeign {
            let drop = Set(foreignIndexes.prefix(foreignIndexes.count - maxForeign))
            outbox = outbox.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
        }
        if outbox.count > maxOutbox {
            outbox.removeFirst(outbox.count - maxOutbox)
        }
    }

    /// Puts saved outbox items back after a restart, keeping their original queue time.
    public func restoreOutbox(_ items: [OutboxItem], now: Date = Date()) {
        for item in items where !outbox.contains(where: { $0.message.id == item.message.id }) {
            outbox.append(item)
            markSeen(item.message.id, now: now)
        }
        pruneOutbox(now: now)
        if outbox.count > maxOutbox { outbox.removeFirst(outbox.count - maxOutbox) }
    }

    /// Returns every unexpired queued item and empties the outbox.
    public func drainOutbox(now: Date = Date()) -> [OutboxItem] {
        pruneOutbox(now: now)
        let items = outbox
        outbox.removeAll()
        return items
    }

    // MARK: Housekeeping

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-seenLifetime)
        seen = seen.filter { $0.value >= cutoff }
    }

    public func pruneOutbox(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-outboxLifetime)
        let foreignCutoff = now.addingTimeInterval(-foreignLifetime)
        outbox.removeAll { $0.queuedAt < cutoff || ($0.foreign == true && $0.queuedAt < foreignCutoff) }
    }
}
