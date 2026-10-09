// NoAIHostTests.swift: the "No AI computer nearby" line (Kyle, Oct 9 2026, 10:42 PM PHT).
// Shown only from the AI status heartbeat; promises an answer only while the ask is saved.

import Foundation

private func myAsk(_ text: String, at: Date, sentTo: [String] = []) -> ChatEntry {
    var m = MeshMessage(origin: "PHONE_A", destination: .role(MeshDestination.aiRole), kind: .ask, body: text)
    m.createdAt = at
    return ChatEntry(id: m.id, message: m, direction: .sent, receivedAt: at, sentTo: sentTo)
}

func runNoAIHostTests() {
    let t0 = Date(timeIntervalSince1970: 1_791_600_000)
    // Heartbeat: a connected Mac that is slow stays awake (status every 10 s, offline after 35 s).
    let mac = DeviceIdentity.generate()
    let tracker = AIStatusTracker()
    let status = AIStatus(device: "MAC", state: .awake, model: "qwen3:8b", queue: 3, rooms: ["r1"], at: t0)
    _ = tracker.ingest(AIStatusTracker.make(status, identity: mac)!, now: t0)
    let slowAsk = myAsk("@pasa long question", at: t0, sentTo: ["MAC"])
    var beat = status; beat.at = t0.addingTimeInterval(30)
    _ = tracker.ingest(AIStatusTracker.make(beat, identity: mac)!, now: t0.addingTimeInterval(30))
    let slow = tracker.availability(room: "r1", now: t0.addingTimeInterval(60))
    let pendingSlow = ChatLayout.pendingAsks([slowAsk], device: "PHONE_A", now: t0.addingTimeInterval(60)).count
    check(slow == .awake && TypingState.of(pending: pendingSlow, isAIPeer: false, ai: slow, waiting: 1, queued: true) == .typing,
          "no AI: Mac slow for 60 s but heartbeat fresh shows typing, not the no-AI line")
    let gone = tracker.availability(room: "r1", now: t0.addingTimeInterval(66))
    check(gone == .offline, "no AI: 36 s without a heartbeat is offline")
    check(TypingState.of(pending: 1, isAIPeer: false, ai: gone, waiting: 1, queued: true) == .note(NoAIHost.queuedLine), "no AI: queued line when the ask is saved")
    check(TypingState.of(pending: 1, isAIPeer: false, ai: .unknown, waiting: 1, queued: false) == .note(NoAIHost.askAgainLine), "no AI: 'ask again' when it is not saved")
    check(TypingState.of(pending: 1, isAIPeer: false, ai: .asleep, waiting: 1) == .note(TypingState.asleepLine), "no AI: asleep keeps its own line")
    check(TypingState.of(pending: 1, isAIPeer: false, ai: .notServing, waiting: 1) == .note(TypingState.notServingLine), "no AI: not in this room keeps its own line")
    check(TypingState.of(pending: 0, isAIPeer: true, ai: .unknown, waiting: 3) == .none, "no AI: the Mac itself never shows it")
    check(TypingState.of(pending: 0, isAIPeer: false, ai: .offline, waiting: 0) == .none, "no AI: nothing waiting, no line")

    // An ask sent with nobody nearby (no recipients yet) still counts as waiting.
    let lonely = myAsk("@pasa when is the quiz?", at: t0)
    check(ChatLayout.pendingAsks([lonely], device: "PHONE_A", now: t0.addingTimeInterval(5)).isEmpty, "no AI: outboxed ask is not 'typing'")
    check(ChatLayout.unansweredAsks([lonely], device: "PHONE_A", now: t0.addingTimeInterval(5)).count == 1, "no AI: outboxed ask is waiting")
    check(ChatLayout.unansweredAsks([lonely], device: "PHONE_A", now: t0.addingTimeInterval(NoAIHost.window + 1)).isEmpty, "no AI: line ends after a day")
    var reply = MeshMessage(origin: "MAC", destination: .peer("PHONE_A"), kind: .answer, body: "Friday")
    reply.replyTo = lonely.message.askKey
    let answered = ChatEntry(id: reply.id, message: reply, direction: .received, receivedAt: t0)
    check(ChatLayout.unansweredAsks([lonely, answered], device: "PHONE_A", now: t0).isEmpty, "no AI: answered ask stops waiting")

    // Queued only while the resend book still holds it.
    var book = PendingAskBook()
    book.add(lonely.message, room: "r1", now: t0)
    check(book.isQueued(lonely.message.id, now: t0.addingTimeInterval(60)), "no AI: saved ask is queued")
    check(!book.isQueued(lonely.message.id, now: t0.addingTimeInterval(PendingAskBook.lifetime + 1)), "no AI: expired ask is not queued")
    for _ in 0..<PendingAskBook.maxAttempts { book.markSent(lonely.message.id, now: t0) }
    check(!book.isQueued(lonely.message.id, now: t0), "no AI: out of attempts is not queued")
    check(!book.isQueued(UUID(), now: t0), "no AI: unknown ask is not queued")
    for line in [NoAIHost.queuedLine, NoAIHost.askAgainLine, NoAIHost.voiceLine] {
        check(line.hasPrefix("No AI computer nearby.") && !line.contains("\u{2014}"), "no AI: wording")
    }
}
