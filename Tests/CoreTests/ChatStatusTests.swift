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

/// Round 2 UI review (Kyle's 8:54 and 8:55 PM iPhone 14 screenshots).
func runRound2UITests() {
    let t0 = Date(timeIntervalSince1970: 1_791_549_180)

    // 6. Same question answered in the last 10 minutes: "Answered above".
    let q = ask("can I put a Christmas tree up in October?", at: t0, sentTo: ["MAC"])
    let a = answer(to: q, at: t0 + 3)
    let entries = [q, a]
    let hit = AskCoalescer.recentAnswer(of: "Can I put a Christmas tree up in October", in: entries, now: t0 + 120)
    check(hit?.answer.id == a.id && hit?.ask.id == q.id, "round2: repeat question finds the answer above")
    check(AskCoalescer.recentAnswer(of: "can I put a Christmas tree up in October?", in: entries, now: t0 + 11 * 60) == nil, "round2: older than 10 min asks again")
    check(AskCoalescer.recentAnswer(of: "my tasks", in: entries, now: t0 + 60) == nil, "round2: a different question is not a repeat")
    check(AskCoalescer.recentAnswer(of: "can I put a Christmas tree up in October?", in: [q], now: t0 + 60) == nil, "round2: unanswered question is not 'answered above'")
    let fromAna = ask("can I put a Christmas tree up in October?", from: "PHONE_B", at: t0, sentTo: ["MAC"])
    check(AskCoalescer.recentAnswer(of: "can i put a christmas tree up in october", in: [fromAna, answer(to: fromAna, at: t0 + 2)], now: t0 + 30) != nil, "round2: a teammate's answered question in the room counts too")
    var retried = ask("my tasks", at: t0, sentTo: ["MAC"])
    retried.message.retryOf = UUID()
    check(AskCoalescer.recentAnswer(of: "my tasks", in: [retried, answer(to: retried, at: t0 + 1)], now: t0 + 5) != nil, "round2: resent asks match by original id")

    // 2. "@" suggestions and starter chips.
    check(MentionSuggest.suggestions(for: "@") == MentionSuggest.items && MentionSuggest.suggestions(for: "@pa").count == 4, "round2: '@' at the start lists ready asks")
    check(MentionSuggest.suggestions(for: "hi @p") == ["@libre"], "round2: mid-sentence offers only @libre")
    check(MentionSuggest.suggestions(for: "@libre ").isEmpty && MentionSuggest.suggestions(for: "@bob").isEmpty && MentionSuggest.suggestions(for: "hello").isEmpty, "round2: no list after a space or for other words")
    check(MentionSuggest.apply("@libre", to: "@p") == "@libre " && MentionSuggest.apply("@libre my tasks", to: "@") == "@libre my tasks", "round2: picking a suggestion fills the field")
    check(StarterChipPolicy.visible(entriesEmpty: true, afterOnboarding: false, canSend: true, typing: false), "round2: chips in an empty chat")
    check(!StarterChipPolicy.visible(entriesEmpty: false, afterOnboarding: false, canSend: true, typing: false), "round2: chips hidden once the chat has messages")
    check(!StarterChipPolicy.visible(entriesEmpty: false, afterOnboarding: true, canSend: true, typing: false) && !StarterChipPolicy.visible(entriesEmpty: true, afterOnboarding: true, canSend: true, typing: true), "ui pass: chips only in an empty chat, hidden while typing")
    check(StarterChipPolicy.asks.count <= StarterChipPolicy.maxChips && StarterChipPolicy.maxChips == 3, "ui pass: at most 3 chips")
    check(StatusWords.linkDot(linked: 0, nearby: 0) == .searching, "ui pass: dot gray while searching")
    check(StatusWords.linkDot(linked: 0, nearby: 2) == .connecting, "ui pass: dot amber while connecting (never green)")
    check(StatusWords.linkDot(linked: 1, nearby: 2) == .connected, "ui pass: dot green when linked")
    check(StatusWords.subtitle(linked: 0, nearby: 2, isAIPeer: true, ai: .unknown, aiMac: nil, firstPeer: nil) == "Connecting..." && StatusWords.linkDot(linked: 0, nearby: 2) != .connected, "ui pass: the Mac screenshot case (Connecting with a green dot) is fixed")
    check(!StarterChipPolicy.asks.contains { $0.title == "More" }, "round2: no 'More' chip")

    // 4. Pasa's name once, not after every question.
    func row(_ origin: String, _ kind: MessageKind, _ at: Date, mine: Bool, replyTo: UUID? = nil) -> ChatEntry {
        var m = MeshMessage(origin: origin, kind: kind, body: "x", createdAt: at)
        m.replyTo = replyTo
        return ChatEntry(id: m.id, message: m, direction: mine ? .sent : .received, receivedAt: at, sentTo: mine ? ["MAC"] : [])
    }
    let k1 = row("KYLE", .ask, t0, mine: true)
    let p1 = row("MAC", .answer, t0 + 2, mine: false, replyTo: k1.id)
    let k2 = row("KYLE", .ask, t0 + 30, mine: true)
    let p2 = row("MAC", .answer, t0 + 32, mine: false, replyTo: k2.id)
    let ana = row("PHONE_B", .chat, t0 + 40, mine: false)
    let k3 = row("KYLE", .ask, t0 + 50, mine: true)
    let p3 = row("MAC", .answer, t0 + 52, mine: false, replyTo: k3.id)
    let l = ChatLayout.layout([k1, p1, k2, p2, ana, k3, p3], statuses: [:], now: t0 + 60)
    check(l[p1.id]?.showName == true && l[p2.id]?.showName == false, "round2: 'Libre AI' once across a Q and A run")
    check(l[ana.id]?.showName == true && l[p3.id]?.showName == true, "round2: name again after someone else spoke")
    check(l[p2.id]?.lastInGroup == true && l[k2.id]?.showName == false, "round2: avatar on the last Libre bubble; never a name for self")

    // 7. Live info prompt.
    let system = AssistantPrompts.answerSystem
    check(system.contains("cannot get live or real-time information") && system.contains("weather") && system.contains("can't get live info while offline"), "round2: prompt says no live info offline")
    check(system.contains("Never tell them to check an app, a website or the internet") && system.contains("team's notes"), "round2: prompt offers what Libre can do instead")
    check(LiveInfo.looksLive("what's the weather looking like?") && LiveInfo.looksLive("Any news today?") && LiveInfo.looksLive("presyo ngayon ng semento?"), "round2: live questions detected")
    check(!LiveInfo.looksLive("can I put a Christmas tree up in October?") && !LiveInfo.looksLive("what are our rules?") && !LiveInfo.looksLive("renews the permit?"), "round2: normal questions are not live")
    let weatherPrompt = AssistantPrompts.answerUser(question: "what's the weather looking like?", asker: "Kyle", rules: [], notes: [], openTasks: [])
    let treePrompt = AssistantPrompts.answerUser(question: "can I put a Christmas tree up in October?", asker: "Kyle", rules: [], notes: [], openTasks: [])
    check(weatherPrompt.contains(LiveInfo.note) && !treePrompt.contains(LiveInfo.note), "round2: live-info note only on live questions")

    // 8. Mac default name.
    check(MacName.suggested(fullUserName: "Kyle Maquindang", hostName: "Kyle’s MacBook Air") == "Kyle's Mac", "round2: Mac name from the user's first name")
    check(MacName.suggested(fullUserName: "", hostName: "kyles-macbook-air.local") == "Kyles MacBook Air", "round2: Mac name from the host name")
    check(MacName.suggested(fullUserName: nil, hostName: "Kyle's MaC") == "Kyle's Mac", "round2: host name casing cleaned")
    check(MacName.suggested(fullUserName: nil, hostName: nil) == "Mac", "round2: fallback Mac")
}

/// Admin badges come from the signed manifest (device keys), never from names.
@MainActor
func runAdminBadgeTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var room = Room.fromPasscode(name: "GROUP-2", passcode: "mangga hinog 42", creator: "Mac", now: t0, rounds: 1000)!
    let teacher = DeviceIdentity.generate()
    let ana = DeviceIdentity.generate()
    let ben = DeviceIdentity.generate()
    _ = RoomGovernor.setUp(&room, identity: teacher, device: "Mac", name: "Teacher", now: t0)
    check(room.gov?.manifest?.creatorKey == teacher.signKey && room.gov?.manifest?.role(device: "Mac") == .creator, "badge: creator from the signed manifest")
    for (id, dev, name) in [(ana, "PHONE_A", "Ana"), (ben, "PHONE_B", "Teacher")] {
        let req = RoomGovernor.joinRequest(room: room, identity: id, device: dev, name: name, now: t0)!
        _ = RoomGovernor.admit(req, room: &room, identity: teacher, now: t0)
    }
    check(room.gov?.manifest?.role(device: "PHONE_A") == .member, "badge: members have no badge")
    check(room.gov?.manifest?.role(device: "PHONE_B") == .member, "badge: a member named like the admin gets no badge")
    _ = RoomGovernor.setCoAdmin(ana.signKey, on: true, room: &room, identity: teacher, now: t0)
    check(room.gov?.manifest?.role(device: "PHONE_A") == .admin && RoomRole.admin.spoken == "admin" && RoomRole.creator.spoken == "creator, admin", "badge: co-admin gets the shield, VoiceOver says admin")
    check(room.gov?.manifest?.role(device: "NOBODY") == nil && RoomRole.member.symbol == nil, "badge: unknown device has no role")
    // Older manifests without creatorKey still decode; the creator stamps it on its next action.
    var legacy = room.gov!.manifest!
    legacy.creatorKey = nil
    let json = try! PasaJSON.encoder.encode(legacy)
    let stripped = String(decoding: json, as: UTF8.self).replacingOccurrences(of: #","creatorKey":null"#, with: "")
    check((try? PasaJSON.decoder.decode(RoomManifest.self, from: Data(stripped.utf8)))?.role(device: "Mac") == .member, "badge: older manifest decodes, creator unknown until stamped")
}

/// Composer staging: photos wait in the composer until the send arrow.
func runStagingTests() {
    func photo() -> StagedItem { StagedItem(kind: .image, data: Data([1, 2, 3]), mime: "image/jpeg", width: 10, height: 10) }
    var d = ComposerDraft()
    check(!d.canSend && d.photoSlots == 4 && d.plan.isEmpty, "staging: empty draft cannot send")
    d.text = "   "
    check(!d.canSend, "staging: spaces alone do not show the send arrow")
    let dropped = d.addPhotos([photo(), photo(), photo()])
    check(dropped == 0 && d.photos.count == 3 && d.canSend && d.photoSlots == 1, "staging: photos alone enable send")
    check(d.addPhotos([photo(), photo()]) == 1 && d.photos.count == 4 && d.photoSlots == 0, "staging: capped at 4 photos")
    check(d.addPhotos([StagedItem(kind: .audio, data: Data([9]), mime: "audio/mp4")]) == 1, "staging: voice notes are not photos")
    let second = d.photos[1].id
    check(d.accessibilityLabel(for: second) == "Photo 2 of 4, staged. Not sent yet.", "staging: VoiceOver label for a staged photo")
    d.removePhoto(second)
    check(d.photos.count == 3 && !d.photos.contains { $0.id == second } && d.photoSlots == 1, "staging: X removes that photo")
    check(d.plan.text == nil && d.plan.photos.count == 3 && !d.plan.isAsk, "staging: photos without a caption")
    d.text = "  @libre what is this? "
    check(d.plan.isAsk && d.plan.text == "@libre what is this?" && d.plan.photos.count == 3, "staging: @libre caption is one ask with the photos")
    d.text = "new rebar delivery"
    check(!d.plan.isAsk && d.plan.text == "new rebar delivery", "staging: plain caption goes as chat")
    d.clear()
    check(d.isEmpty && !d.canSend && d.photos.isEmpty, "staging: cleared after sending")
    var t = ComposerDraft(text: "hi")
    check(t.canSend && t.plan.photos.isEmpty && t.plan.text == "hi", "staging: text alone sends as before")
    t.text = ""
    check(!t.canSend, "staging: send arrow hides when the text is cleared")
}
