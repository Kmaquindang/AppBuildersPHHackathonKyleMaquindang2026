// ChatStatusTests.swift: duplicate ask coalescing, bubble status, plain-word header and banner.

import Foundation

private func ask(_ text: String, from device: String = "PHONE_A", at: Date, sentTo: [String] = []) -> ChatEntry {
    var m = MeshMessage(origin: device, destination: .role(MeshDestination.aiRole), kind: .ask, body: text)
    m.createdAt = at
    return ChatEntry(id: m.id, message: m, direction: .sent, receivedAt: at, sentTo: sentTo)
}

private func answer(to a: ChatEntry, at: Date) -> ChatEntry {
    var m = MeshMessage(origin: "MAC", destination: .peer(a.message.origin), kind: .answer, body: "ok")
    m.replyTo = a.message.askKey
    m.createdAt = at
    return ChatEntry(id: m.id, message: m, direction: .received, receivedAt: at)
}

func runChatStatusTests() {
    let t0 = Date(timeIntervalSince1970: 1_791_500_000)
    check(AskCoalescer.normalize("  What did I   miss? ") == "what did i miss", "normalize ask text")

    let first = ask("what did I miss?", at: t0)
    var entries = [first]
    check(AskCoalescer.pendingDuplicate(of: "What did I miss", from: "PHONE_A", in: entries, now: t0 + 30)?.id == first.id, "same unanswered ask is a duplicate")
    check(AskCoalescer.pendingDuplicate(of: "my tasks", from: "PHONE_A", in: entries, now: t0 + 30) == nil, "different ask is not")
    check(AskCoalescer.pendingDuplicate(of: "what did I miss?", from: "PHONE_B", in: entries, now: t0 + 30) == nil, "another device's ask does not block mine")
    check(AskCoalescer.pendingDuplicate(of: "what did I miss?", from: "PHONE_A", in: entries, now: t0 + 25 * 3600) == nil, "a day-old ask no longer blocks")
    entries.append(answer(to: first, at: t0 + 10))
    check(AskCoalescer.pendingDuplicate(of: "what did I miss?", from: "PHONE_A", in: entries, now: t0 + 30) == nil, "answered ask can be asked again")

    // Bubble status
    let answered = AskCoalescer.answered(entries)
    check(BubbleStatus.of(first, answered: answered, waiting: false) == .answered, "answered ask shows answered")
    let queued = ask("my tasks", at: t0)
    check(BubbleStatus.of(queued, answered: answered, waiting: false) == .queued, "unsent ask shows queued (clock)")
    check(BubbleStatus.queued.symbol == "clock" && BubbleStatus.queued.accessibilityLabel.contains("Queued"), "queued icon and VoiceOver label")
    let sent = ask("my tasks", at: t0, sentTo: ["MAC"])
    check(BubbleStatus.of(sent, answered: answered, waiting: true) == .waiting && BubbleStatus.of(sent, answered: answered, waiting: false) == .sent, "sent vs waiting")
    check(BubbleStatus.of(entries[1], answered: answered, waiting: false) == .received, "received answer has no status icon")

    // Words
    check(StatusWords.line(linked: 0, nearby: 0, isAIPeer: false, ai: .unknown) == "No devices nearby · No AI Mac yet", "empty status line")
    check(StatusWords.line(linked: 2, nearby: 3, isAIPeer: false, ai: .awake) == "2 devices linked · AI Mac connected", "linked status line")
    check(StatusWords.line(linked: 0, nearby: 1, isAIPeer: false, ai: .asleep) == "1 device nearby, linking · AI Mac asleep", "nearby status line")
    check(StatusWords.offlineBanner(linked: 0, queued: 6) == "No one nearby. 6 messages will send when a teammate is in range.", "offline banner")
    check(StatusWords.offlineBanner(linked: 1, queued: 6) == nil && StatusWords.offlineBanner(linked: 0, queued: 0) == nil, "no banner when linked or nothing queued")
}
