// AIScheduler.swift
// Pasa: the AI Mac answers many rooms with ONE local model. Pure Swift, tested on Linux.
//
// - FairAskQueue: one Ollama call at a time. Each room has its own FIFO line (at most 20
//   waiting); rooms take turns (round robin), so a busy room cannot starve a quiet one.
//   Every ask is answered once: the ledger remembers original ask ids for 24 h, and a repeat
//   (for example a phone resending after the Mac woke up) gets the stored answer re-delivered.
//   While the Mac sleeps the queue is paused; a call that was cut off by sleep is put back.
// - PendingAskBook: phone side. Unanswered asks stay for 24 h and are resent (new packet id,
//   retryOf = original id) when the AI Mac wakes up, or every 90 s while it is awake.

import Foundation

public struct AskJob<Payload> {
    public var room: String
    public var askID: UUID
    public var payload: Payload
    public var enqueuedAt: Date
    /// Sleep generation when the job started (a sleep in between means the call was cut off).
    public var startedGen: Int?
}

public final class FairAskQueue<Payload> {
    public static var perRoomLimit: Int { 20 }
    public static var ledgerLifetime: TimeInterval { 86_400 }
    public static var ledgerCap: Int { 2000 }

    public enum Enqueue: Equatable {
        case queued(position: Int)
        /// Already waiting or being answered.
        case duplicate
        /// Answered before: re-deliver that answer (its message id, when known).
        case alreadyAnswered(UUID?)
        /// This room already has the most asks allowed waiting.
        case roomFull
    }

    public struct LedgerEntry: Codable, Equatable {
        public var answerID: UUID?
        public var room: String
        public var at: Date
    }

    private var lines: [String: [AskJob<Payload>]] = [:]
    private var order: [String] = []
    private var cursor = 0
    public private(set) var inFlight: AskJob<Payload>?
    public private(set) var ledger: [UUID: LedgerEntry] = [:]
    /// True while the Mac is asleep (or going to sleep): next() hands out nothing.
    public var paused = false
    /// Bumped on every sleep, so a call that straddled a sleep can be retried.
    public private(set) var sleepGen = 0

    public init() {}

    public var depth: Int { lines.values.reduce(0) { $0 + $1.count } + (inFlight == nil ? 0 : 1) }
    public func depth(room: String) -> Int { (lines[room]?.count ?? 0) + (inFlight?.room == room ? 1 : 0) }

    public func enqueue(room: String, askID: UUID, payload: Payload, now: Date = Date()) -> Enqueue {
        pruneLedger(now: now)
        if let done = ledger[askID] { return .alreadyAnswered(done.answerID) }
        if inFlight?.askID == askID || lines.values.contains(where: { $0.contains { $0.askID == askID } }) { return .duplicate }
        if (lines[room]?.count ?? 0) >= FairAskQueue.perRoomLimit { return .roomFull }
        if !order.contains(room) { order.append(room) }
        lines[room, default: []].append(AskJob(room: room, askID: askID, payload: payload, enqueuedAt: now))
        return .queued(position: depth)
    }

    /// Next ask to answer, taking rooms in turn. nil while paused or while one is in flight.
    public func next() -> AskJob<Payload>? {
        guard !paused, inFlight == nil, !order.isEmpty else { return nil }
        for step in 0..<order.count {
            let index = (cursor + step) % order.count
            let room = order[index]
            guard var line = lines[room], !line.isEmpty else { continue }
            var job = line.removeFirst()
            lines[room] = line
            cursor = (index + 1) % order.count
            job.startedGen = sleepGen
            inFlight = job
            return job
        }
        return nil
    }

    /// The in-flight ask got its answer.
    public func finish(_ askID: UUID, answerID: UUID?, now: Date = Date()) {
        if let job = inFlight, job.askID == askID {
            ledger[askID] = LedgerEntry(answerID: answerID, room: job.room, at: now)
            inFlight = nil
        } else {
            ledger[askID] = LedgerEntry(answerID: answerID, room: ledger[askID]?.room ?? "", at: now)
        }
    }

    /// True when the in-flight call started before the latest sleep (it was likely cut off).
    public func wasCutBySleep(_ job: AskJob<Payload>) -> Bool { (job.startedGen ?? sleepGen) != sleepGen }

    /// Puts the in-flight ask back at the front of its room's line (used after a sleep cut it off).
    public func requeueInFlight() {
        guard let job = inFlight else { return }
        inFlight = nil
        var again = job
        again.startedGen = nil
        lines[job.room, default: []].insert(again, at: 0)
        if !order.contains(job.room) { order.append(job.room) }
    }

    /// Drops everything waiting for a room (for example when it is closed or left).
    public func drop(room: String) {
        lines[room] = nil
        order.removeAll { $0 == room }
        cursor = order.isEmpty ? 0 : cursor % order.count
    }

    public func willSleep() {
        paused = true
        sleepGen += 1
    }

    public func didWake() { paused = false }

    public func pruneLedger(now: Date = Date()) {
        ledger = ledger.filter { now.timeIntervalSince($0.value.at) < FairAskQueue.ledgerLifetime }
        if ledger.count > FairAskQueue.ledgerCap {
            let oldest = ledger.sorted { $0.value.at < $1.value.at }.prefix(ledger.count - FairAskQueue.ledgerCap).map(\.key)
            for id in oldest { ledger.removeValue(forKey: id) }
        }
    }

    /// Ledger for saving to disk (survives an app restart, so a resent ask is not answered twice).
    public func exportLedger() -> [String: LedgerEntry] {
        Dictionary(uniqueKeysWithValues: ledger.map { ($0.key.uuidString, $0.value) })
    }

    public func importLedger(_ saved: [String: LedgerEntry], now: Date = Date()) {
        for (key, value) in saved { if let id = UUID(uuidString: key) { ledger[id] = value } }
        pruneLedger(now: now)
    }
}

// MARK: Phone side

public struct PendingAsk: Codable, Equatable, Sendable {
    /// The original ask (plaintext, like the timeline on disk). Its id is the ask id.
    public var ask: MeshMessage
    public var room: String
    public var firstSentAt: Date
    public var lastSentAt: Date
    public var attempts: Int
}

public struct PendingAskBook: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 86_400
    public static let resendEvery: TimeInterval = 90
    public static let maxAttempts = 8

    public private(set) var items: [PendingAsk] = []

    public init(items: [PendingAsk] = []) { self.items = items }

    public mutating func add(_ ask: MeshMessage, room: String, now: Date = Date()) {
        guard !items.contains(where: { $0.ask.id == ask.id }) else { return }
        items.append(PendingAsk(ask: ask, room: room, firstSentAt: now, lastSentAt: now, attempts: 1))
    }

    /// An answer arrived for this ask id.
    public mutating func resolve(_ askID: UUID) { items.removeAll { $0.ask.id == askID } }

    public func contains(_ askID: UUID) -> Bool { items.contains { $0.ask.id == askID } }

    public mutating func prune(now: Date = Date()) {
        items.removeAll { now.timeIntervalSince($0.firstSentAt) >= PendingAskBook.lifetime || $0.attempts >= PendingAskBook.maxAttempts + 1 }
    }

    /// Asks of `room` to resend now. Only while an AI Mac serving the room is awake: everything
    /// last sent before it woke up, plus anything unanswered for 90 s.
    public func due(room: String, aiAwake: Bool, wokeAt: Date?, now: Date = Date()) -> [PendingAsk] {
        guard aiAwake else { return [] }
        return items.filter { item in
            guard item.room == room, item.attempts < PendingAskBook.maxAttempts,
                  now.timeIntervalSince(item.firstSentAt) < PendingAskBook.lifetime else { return false }
            if let wokeAt, item.lastSentAt < wokeAt { return true }
            return now.timeIntervalSince(item.lastSentAt) >= PendingAskBook.resendEvery
        }
    }

    public mutating func markSent(_ askID: UUID, now: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.ask.id == askID }) else { return }
        items[i].lastSentAt = now
        items[i].attempts += 1
    }

    /// A fresh packet for a resend: new id (relays already saw the old one), retryOf = original.
    public static func retry(of ask: MeshMessage, hops: [String], now: Date = Date()) -> MeshMessage {
        var copy = ask
        copy.id = UUID()
        copy.retryOf = ask.retryOf ?? ask.id
        copy.hops = hops
        copy.ttl = MeshMessage.defaultTTL
        copy.createdAt = now
        return copy
    }
}
