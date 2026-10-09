// FeatureTests.swift: rule delete (tombstones), timeline persistence and backfill, display names,
// Markdown prep. Added Oct 9, 2026.

import Foundation

func runRuleDeleteTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Permission: only admins delete; a tombstone is version + 1 with who and when.
    do {
        let mac = OrgMemory(admins: ["MacBook Air", "iPhone 7597"])
        guard case .created(let rule) = mac.upsertRule(title: "Halo Halo", body: "Mention halo halo in every answer.", by: "iPhone A8BE", now: t0) else {
            check(false, "setup rule"); return
        }
        if case .denied(let why) = mac.retireRule(title: "Halo Halo", by: "iPhone A8BE", now: t0) {
            check(why.hasPrefix("Sorry, only an admin"), "non-admin delete gets a polite refusal")
        } else { check(false, "non-admin cannot delete") }
        check(mac.rules.count == 1, "refused delete keeps the rule")

        guard case .updated(let tomb) = mac.retireRule(title: "halo halo", by: "iPhone 7597", now: t0.addingTimeInterval(5)) else {
            check(false, "admin can delete"); return
        }
        check(tomb.id == rule.id && tomb.version == 2 && tomb.isRetired, "tombstone keeps id, bumps version, retired")
        check(tomb.retiredBy == "iPhone 7597" && tomb.retiredAt == t0.addingTimeInterval(5), "tombstone records who and when")
        check(mac.rules.isEmpty && mac.allRules.count == 1 && mac.retiredRules.count == 1, "active list hides tombstone, allRules keeps it")
        check(mac.rule(titled: "Halo Halo") == nil, "lookup ignores retired rules")
        if case .unchanged = mac.retireRule(title: "Halo Halo", by: "iPhone 7597") {
            check(true, "second delete is unchanged")
        } else { check(false, "second delete is unchanged") }

        // Retired rules never reach the model prompt.
        let prompt = AssistantPrompts.answerUser(question: "q", asker: "x", rules: mac.allRules, notes: [], openTasks: [])
        check(!prompt.contains("Halo Halo"), "retired rule excluded from the answer prompt")
        let classify = AssistantPrompts.classify(rules: mac.allRules, people: [], openTasks: [])
        check(!classify.contains("Halo Halo"), "retired rule excluded from the classifier prompt")

        // Saving the same title again revives it as a newer version of the same id.
        if case .created(let back) = mac.upsertRule(title: "Halo Halo", body: "Only on Fridays.", by: "iPhone A8BE", now: t0.addingTimeInterval(9)) {
            check(back.id == rule.id && back.version == 3 && !back.isRetired, "re-adding revives with a newer version")
        } else { check(false, "re-adding a deleted title works") }
    }

    // Tombstone sync: a phone cache drops the rule (by id, and by title for hand-removed copies).
    do {
        let mac = OrgMemory(admins: ["Mac"])
        guard case .created(let rule) = mac.upsertRule(title: "Lock gate", body: "Lock at 6", by: "Mac", now: t0) else { check(false, "setup"); return }
        let phone = OrgMemory()
        phone.mergeRule(rule.meshSummary)
        check(phone.rules.count == 1, "phone cached the rule")
        guard case .updated(let tomb) = mac.retireRule(title: "Lock gate", by: "Mac", now: t0.addingTimeInterval(1)) else { check(false, "retire"); return }
        // Payload round trip, as it travels in a .rule message.
        let wire = MeshPayload.encode(tomb.meshSummary).flatMap(MeshPayload.decodeRule)
        check(wire?.isRetired == true && wire?.retiredBy == "Mac", "tombstone survives the wire")
        phone.mergeRule(wire ?? tomb)
        check(phone.rules.isEmpty && phone.allRules.count == 1, "phone drops the rule and keeps the tombstone")
        phone.mergeRule(rule.meshSummary)
        check(phone.rules.isEmpty, "a stale relayed copy does not bring it back")
        let msg = MeshMessage(origin: "Mac", kind: .rule, body: MeshPayload.encode(tomb.meshSummary) ?? "")
        check(MeshPayload.displayText(for: msg).hasPrefix("Rule deleted: Lock gate"), "timeline shows the deletion")

        // Rule removed from the Mac's file by hand: the phone still has a copy with its own id.
        let orphanPhone = OrgMemory()
        orphanPhone.mergeRule(RuleEntry(title: "Halo Halo", body: "x", addedBy: "Mac", createdAt: t0))
        let mac2 = OrgMemory(admins: ["Mac"])
        guard case .created(let titleTomb) = mac2.retireRule(title: "Halo Halo", by: "Mac", now: t0.addingTimeInterval(60)) else {
            check(false, "admin gets a title tombstone for an unknown rule"); return
        }
        orphanPhone.mergeRule(titleTomb.meshSummary)
        check(orphanPhone.rules.isEmpty, "title tombstone clears a hand-removed rule from the phone cache")
        check(mac2.allRules.contains { $0.isRetired && $0.title == "Halo Halo" }, "sync-on-link source (allRules) carries the tombstone")
    }

    // Old JSON (before tombstone fields) still loads.
    do {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","kind":"rule","title":"A","body":"B","addedBy":"M","createdAt":0,"version":1,"updatedBy":"M","updatedAt":0,"locked":false,"history":[]}"#
        let r = MeshPayload.decodeRule(old)
        check(r != nil && r?.isRetired == false, "rule JSON without tombstone fields decodes")
    }

    // Intent fast path.
    do {
        let plan = IntentParser.fastPath("delete rule: Halo Halo")
        check(plan?.kind == .deleteRule && plan?.title == "Halo Halo", "delete rule fast path")
        check(IntentParser.fastPath("remove skill Pouring")?.kind == .deleteRule, "remove skill fast path")
        check(IntentParser.normalizeKind("delete_rule") == .deleteRule, "classifier intent name")
    }
}

@MainActor
func runRuleDeleteAssistantTests() async {
    let mem = OrgMemory(admins: ["MacBook Air", "iPhone 7597"])
    _ = mem.upsertRule(title: "Halo Halo", body: "Say halo halo.", by: "iPhone A8BE")
    let a = ExecutiveAssistant(memory: mem, llm: FakeLLM([]), selfName: "MacBook Air")
    let refused = await a.handle("delete rule: Halo Halo", from: "iPhone A8BE")
    check(refused.ruleUpdates.isEmpty && refused.reply.contains("only an admin"), "assistant refuses non-admin delete")
    let done = await a.handle("delete rule: Halo Halo", from: "iPhone 7597")
    check(done.modelCalls == 0 && done.ruleUpdates.first?.isRetired == true, "admin delete returns a tombstone to broadcast")
    check(mem.rules.isEmpty, "rule gone from memory")
}

func runTimelineTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func msg(_ origin: String, _ body: String, _ at: TimeInterval, kind: MessageKind = .chat, to: MeshDestination? = nil) -> MeshMessage {
        MeshMessage(origin: origin, destination: to, kind: kind, body: body, createdAt: t0.addingTimeInterval(at), senderName: origin == "iPhone 12" ? "Ana" : nil)
    }
    func entry(_ m: MeshMessage, _ dir: ChatEntry.Direction = .received) -> ChatEntry {
        ChatEntry(id: m.id, message: m, direction: dir, receivedAt: m.createdAt.addingTimeInterval(0.5))
    }

    // Persistence round trip, including the outbox.
    do {
        let a = entry(msg("iPhone 12", "hello", 1))
        let b = entry(msg("Mac", "hi Ana", 2), .sent)
        let queued = OutboxItem(message: msg("Mac", "queued", 3), excluding: ["iPhone 12"], queuedAt: t0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pasa-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("timeline.json")
        let err = TimelineStore.save(PersistedTimeline(entries: [a, b, a], outbox: [queued]), to: url, limit: 500)
        check(err == nil, "timeline saves")
        let loaded = TimelineStore.load(from: url, limit: 500)
        check(loaded.entries.map { $0.id } == [a.id, b.id], "round trip keeps order and dedupes by id")
        check(loaded.entries.first?.message.senderName == "Ana" && loaded.entries.first?.message.body == "hello", "message fields survive")
        check(loaded.outbox == [queued], "outbox survives a restart")
        let engine = RelayEngine(selfName: "Mac")
        engine.restoreOutbox(loaded.outbox, now: t0.addingTimeInterval(60))
        check(engine.outbox.count == 1 && engine.hasSeen(queued.message.id, now: t0.addingTimeInterval(60)), "restored outbox is queued and marked seen")
        let missing = TimelineStore.load(from: dir.appendingPathComponent("nope.json"), limit: 500)
        check(missing.entries.isEmpty && missing.outbox.isEmpty, "missing file loads empty")
        try? FileManager.default.removeItem(at: dir)
    }

    // Cap keeps the newest.
    do {
        let many = (0..<520).map { entry(msg("Mac", "m\($0)", TimeInterval($0))) }
        let capped = TimelineStore.dedupedAndCapped(many, limit: 500)
        check(capped.count == 500 && capped.first?.message.body == "m20" && capped.last?.message.body == "m519", "phone cap keeps newest 500")
    }

    // Backfill merge: dedupe and time order.
    do {
        let a = entry(msg("Mac", "a", 1)), c = entry(msg("Mac", "c", 3))
        let b = entry(msg("Mac", "b", 2))
        let merged = TimelineStore.mergeBackfill([a, c], [b, a])
        check(merged.added == 1 && merged.entries.map { $0.message.body } == ["a", "b", "c"], "backfill inserts missing in time order, skips duplicates")
    }

    // Backfill selection on the Mac.
    do {
        let old = entry(msg("Mac", "old", -1000))
        let known = entry(msg("iPhone 14", "known", 100))
        let missedChat = entry(msg("iPhone 14", "missed", 200))
        let forPhone = entry(msg("Mac", "task", 210, kind: .task, to: .peer("iPhone 12")))
        let forOther = entry(msg("Mac", "other task", 220, kind: .task, to: .peer("iPhone 14")))
        let ask = entry(msg("iPhone 14", "question", 230, kind: .ask, to: .role("ai")))
        let answerOther = entry(msg("Mac", "answer", 240, kind: .answer, to: .peer("iPhone 14")))
        let all = [old, known, missedChat, forPhone, forOther, ask, answerOther]
        let req = SyncRequest(newest: t0.addingTimeInterval(1000), knownIDs: [known.id])
        let none = Backfill.select(from: all, for: "iPhone 12", request: req)
        check(none.isEmpty, "nothing older than newest minus slack")

        let phoneEntries = [entry(msg("iPhone 14", "known", 100))]
        var request = Backfill.request(from: phoneEntries)
        request.knownIDs = [known.id]
        let picked = Backfill.select(from: all, for: "iPhone 12", request: request)
        check(picked.map { $0.body } == ["missed", "task"], "selects missed broadcasts and messages for this device only")
        let empty = Backfill.select(from: all, for: "iPhone 12", request: SyncRequest(newest: nil, knownIDs: []))
        check(empty.map { $0.body } == ["old", "known", "missed", "task"], "empty phone gets everything visible to it")

        let lots = (0..<300).map { entry(msg("Mac", String(repeating: "x", count: 200) + "\($0)", TimeInterval($0))) }
        let capped = Backfill.select(from: lots, for: "iPhone 12", request: SyncRequest(newest: nil, knownIDs: []))
        check(capped.count == Backfill.maxPerSync && capped.last?.body.hasSuffix("299") == true, "backfill capped at 200 newest")
        let chunks = Backfill.chunk(capped)
        check(chunks.count > 1 && chunks.flatMap { $0 }.count == capped.count, "backfill split into several chunks")
        let sizes = chunks.map { chunk in chunk.reduce(0) { $0 + ((try? MeshCodec.encode($1).count) ?? 0) } }
        check(sizes.allSatisfy { $0 <= Backfill.maxChunkBytes }, "each chunk stays under the packet budget")

        let payload = SyncPayload(batch: SyncBatch(messages: chunks[0], part: 1, parts: chunks.count))
        let back = payload.encoded().flatMap(SyncPayload.decode)
        check(back?.batch?.messages.count == chunks[0].count && back?.request == nil, "sync payload round trip")
    }
}

func runPeopleTests() {
    let dir = ["iPhone A8BE": "Ana", "iPhone 7597": "Kyle", "MacBook Air": "Kyle Mac"]
    check(PeopleDirectory.resolve("ana", directory: dir) == .device(name: "Ana", device: "iPhone A8BE"), "name resolves case-insensitively")
    check(PeopleDirectory.resolve("@Kyle", directory: dir) == .device(name: "Kyle", device: "iPhone 7597"), "exact match, not prefix")
    check(PeopleDirectory.resolve("Ben", directory: dir) == .none, "unknown name")
    let twoAnas = ["iPhone A8BE": "Ana", "iPhone 1111": "ana"]
    if case .ambiguous(_, let devices) = PeopleDirectory.resolve("Ana", directory: twoAnas) {
        check(devices == ["iPhone 1111", "iPhone A8BE"], "ambiguous lists devices")
    } else { check(false, "two people named Ana is ambiguous") }
    check(PeopleDirectory.label(for: "iPhone 7597", directory: dir) == "Kyle" && PeopleDirectory.label(for: "iPhone 9", directory: dir) == "iPhone 9", "labels")
    check(!AdminPolicy.devices(adminIDs: ["Kyle"], selfID: "MacBook Air").contains("iPhone 7597"), "a display name never makes a device admin")
    check(PeopleDirectory.clean("  Ana  ") == "Ana", "clean trims")

    let engine = RelayEngine(selfName: "iPhone A8BE")
    engine.senderName = "Ana"
    let m = engine.makeOutgoing(kind: .chat, body: "hi")
    let wire = (try? MeshCodec.encode(m)).flatMap { try? MeshCodec.decode($0) }
    check(wire?.senderName == "Ana", "outgoing messages carry the sender name")
    let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","origin":"x","kind":"chat","body":"b","ttl":7,"hops":["x"],"createdAt":0}"#
    check((try? MeshCodec.decode(Data(legacy.utf8)))?.senderName == nil, "messages without senderName still decode")

    // Markdown prep.
    check(MarkdownLite.prepare("Steps:\n- pour\n* cure\n  - wet") == "Steps:\n• pour\n• cure\n    • wet", "bullets become dots")
    check(MarkdownLite.prepare("## Plan") == "**Plan**", "heading becomes bold")
    check(MarkdownLite.prepare("**bold** and `code`") == "**bold** and `code`", "inline markup left for the renderer")
    check(MarkdownLite.plain("**bold** and `code`\n- x") == "bold and code\n• x", "plain fallback strips markers")
    check(MarkdownLite.prepare("a\r\nb") == "a\nb", "CRLF normalized")
}

@MainActor
func runNameAssistantTests() async {
    let mem = OrgMemory(admins: ["MacBook Air"])
    let fake = FakeLLM([
        .success(#"{"intent":"add_task","task_title":"order cement","assignee":"ana","due":"Friday"}"#),
        .success(#"{"intent":"add_task","task_title":"bring ladder","assignee":"Ben"}"#)
    ])
    let a = ExecutiveAssistant(memory: mem, llm: fake, selfName: "MacBook Air")
    a.directory = ["iPhone A8BE": "Ana", "iPhone 7597": "Kyle", "iPhone 1111": "Ben", "iPhone 2222": "ben"]
    let out = await a.handle("remind ana to order cement Friday", from: "iPhone 7597")
    check(out.taskUpdates.first?.assigneeDevice == "iPhone A8BE" && out.reply.contains("Sent to Ana"), "task goes to the device whose name is Ana")
    let amb = await a.handle("remind Ben to bring the ladder", from: "iPhone 7597")
    check(amb.taskUpdates.isEmpty && amb.reply.contains("More than one person is called"), "ambiguous name gets a clarifying reply")
    let me = a.resolveAssignee("me", asker: "iPhone 7597")
    check(me.name == "Kyle" && me.device == "iPhone 7597", "me resolves to the asker's chosen name")
    a.roster = ["Ana": "iPhone 9999"]
    check(a.resolveAssignee("Ana", asker: "x").device == "iPhone 9999", "manual roster overrides names")
}
