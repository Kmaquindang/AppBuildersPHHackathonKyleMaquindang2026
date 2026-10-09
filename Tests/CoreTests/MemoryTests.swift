// MemoryTests.swift: OrgMemory permissions, versioning, merge, persistence; NameMatcher; Compactor; payloads.

import Foundation

func runMemoryTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Permissions and versioning.
    do {
        let m = OrgMemory(admins: ["iPhone 14 Pro Max", "MacBook Air"])
        let created = m.upsertRule(title: "No site visits after 5 PM", body: "No site visits after 5 PM.", by: "iPhone 12", now: t0)
        guard case .created(let rule) = created else { check(false, "non-admin can add a new rule"); return }
        check(rule.version == 1 && rule.addedBy == "iPhone 12", "new rule is v1 with author")
        check(rule.citation == "[Rule: No site visits after 5 PM v1]", "citation format")

        if case .denied = m.upsertRule(title: "no site visits after 5 pm", body: "Changed", by: "iPhone 12", now: t0) {
            check(true, "non-admin cannot edit an existing rule")
        } else { check(false, "non-admin cannot edit an existing rule") }

        guard case .updated(let v2) = m.upsertRule(title: "No site visits after 5 PM", body: "No site visits after 6 PM.", by: "iPhone 14 Pro Max", now: t0.addingTimeInterval(60)) else {
            check(false, "admin can edit"); return
        }
        check(v2.version == 2 && v2.body == "No site visits after 6 PM.", "admin edit makes v2")
        check(v2.history.count == 1 && v2.history[0].body == "No site visits after 5 PM." && v2.history[0].version == 1, "history keeps v1")
        check(v2.citation == "[Rule: No site visits after 5 PM v2]", "citation shows v2")
        check(m.rules.count == 1, "edit does not duplicate")

        if case .unchanged = m.upsertRule(title: "No site visits after 5 PM", body: "No site visits after 6 PM.", by: "MacBook Air") {
            check(true, "same body is unchanged")
        } else { check(false, "same body is unchanged") }

        if case .denied = m.setLocked(title: "No site visits after 5 PM", locked: true, by: "iPhone 12") {
            check(true, "non-admin cannot lock")
        } else { check(false, "non-admin cannot lock") }
        if case .updated(let locked) = m.setLocked(title: "site visits", locked: true, by: "MacBook Air") {
            check(locked.locked, "admin locks by fuzzy title")
        } else { check(false, "admin locks by fuzzy title") }
        if case .denied = m.upsertRule(title: "No site visits after 5 PM", body: "Anything", by: "MacBook Air") {
            check(true, "locked rule cannot be edited, even by admin")
        } else { check(false, "locked rule cannot be edited, even by admin") }
        _ = m.setLocked(title: "No site visits after 5 PM", locked: false, by: "iPhone 14 Pro Max")
        if case .updated(let v3) = m.upsertRule(title: "No site visits after 5 PM", body: "No site visits after 7 PM.", by: "MacBook Air") {
            check(v3.version == 3 && v3.history.count == 2, "after unlock, admin edit makes v3")
        } else { check(false, "after unlock, admin edit makes v3") }

        if case .created(let other) = m.upsertRule(title: "Hard hats", body: "Hard hats on site.", by: "iPhone 12") {
            check(other.version == 1 && m.rules.count == 2, "second rule added")
        } else { check(false, "second rule added") }
    }

    // Cache merge: newest version wins, ties by updatedAt, history kept.
    do {
        let phone = OrgMemory()
        let id = UUID()
        let v1 = RuleEntry(id: id, title: "Gate", body: "Lock gate", addedBy: "Mac", createdAt: t0)
        var v2 = v1
        v2.version = 2; v2.body = "Lock gate at 6"; v2.updatedAt = t0.addingTimeInterval(10)
        check(phone.mergeRule(v1), "merge new rule")
        check(phone.mergeRule(v2.meshSummary), "newer version replaces")
        check(!phone.mergeRule(v1), "older version ignored")
        check(phone.rules.first?.body == "Lock gate at 6", "cache holds newest body")
        check(phone.rules.first?.history.map { $0.version } == [1], "merge records the replaced version in history")
        var v2b = v2
        v2b.locked = true; v2b.updatedAt = t0.addingTimeInterval(20)
        check(phone.mergeRule(v2b.meshSummary), "same version with later update wins")
        check(phone.rules.first?.locked == true, "lock state propagated")
    }

    // Tasks.
    do {
        let m = OrgMemory()
        let roster = ["Ana": "iPhone 12"]
        let a = m.addTask(title: "Order cement", assignee: "Ana", assigneeDevice: nil, due: "Friday", by: "MacBook Air", now: t0)
        _ = m.addTask(title: "Check scaffolding", assignee: "iPhone 14 Pro Max", assigneeDevice: "iPhone 14 Pro Max", due: nil, by: "MacBook Air", now: t0)
        check(m.tasks(forDevice: "iPhone 12", roster: roster).map { $0.id } == [a.id], "roster maps Ana to iPhone 12")
        check(m.tasks(forDevice: "iPhone 14 Pro Max").count == 1, "device assignment")
        check(m.findOpenTask(matching: "the cement order")?.id == a.id, "find task by loose words")
        check(m.findOpenTask(matching: "banana") == nil, "no false match")
        let done = m.markDone(a.id, by: "iPhone 12", now: t0.addingTimeInterval(5))
        check(done?.status == .done && done?.completedBy == "iPhone 12", "mark done")
        check(m.openTasks.count == 1, "done task leaves open list")
        check(a.shortLine == "Order cement (Ana, due Friday)", "task short line")

        let phone = OrgMemory()
        check(phone.mergeTask(a), "phone caches task")
        check(phone.mergeTask(done!), "newer task update wins")
        check(!phone.mergeTask(a), "stale task update ignored")
        check(phone.tasks.first?.status == .done, "phone sees done")
    }

    // Chat log cap.
    do {
        let m = OrgMemory()
        m.maxChatLog = 5
        for i in 0..<12 { m.recordChat(from: "A", text: "msg \(i)") }
        check(m.snapshot.chatLog.count == 5 && m.recentChat(limit: 2).map { $0.text } == ["msg 10", "msg 11"], "chat log capped, newest kept")
    }

    // Persistence round trip.
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("libre-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("org-memory.json")
        let m = OrgMemory(fileURL: url, admins: ["Mac"])
        _ = m.upsertRule(title: "Hard hats", body: "Always", by: "Mac", now: t0)
        _ = m.upsertRule(title: "Hard hats", body: "Always, even in the office", by: "Mac", now: t0.addingTimeInterval(1))
        _ = m.addTask(title: "Buy nails", assignee: nil, assigneeDevice: nil, due: nil, by: "Mac", now: t0)
        _ = m.addNote(title: "Huddle", summary: "Short", decisions: ["Start 7 AM"], taskIDs: [], by: "Mac", now: t0)
        check(m.lastSaveError == nil, "save has no error")
        let reloaded = OrgMemory(fileURL: url)
        check(reloaded.rules.first?.version == 2 && reloaded.rules.first?.history.count == 1, "rules persist with history")
        check(reloaded.tasks.first?.title == "Buy nails", "tasks persist")
        check(reloaded.notes.first?.decisions == ["Start 7 AM"], "notes persist")
        try? FileManager.default.removeItem(at: dir)
    }

    // NameMatcher.
    do {
        let devices = ["iPhone 12", "iPhone 14 Pro Max", "MacBook Air"]
        check(NameMatcher.match("ana", in: ["Ana", "Ben"]) == "Ana", "match person case-insensitive")
        check(NameMatcher.match("@iphone 12", in: devices) == "iPhone 12", "match device exact")
        check(NameMatcher.match("iphone", in: devices) == nil, "ambiguous word gives nil")
        check(NameMatcher.match("the 14 pro", in: devices) == "iPhone 14 Pro Max", "distinctive words match")
        check(NameMatcher.match("mac", in: devices) == nil, "partial word is not a match")
        check(NameMatcher.match("macbook", in: devices) == "MacBook Air", "distinctive device word")
        check(NameMatcher.match("Ana Reyes", in: ["Ana", "Ben"]) == "Ana", "prefix match")
    }

    // Roster.
    do {
        let roster = Roster.parse("Ana = iPhone 12\nBen: iPhone 14 Pro Max\n\nbad line\n = x")
        check(roster == ["Ana": "iPhone 12", "Ben": "iPhone 14 Pro Max"], "roster parse")
        check(Roster.parse(Roster.format(roster)) == roster, "roster format round trip")
    }

    // Compactor.
    do {
        let short = Compactor.split("Short answer.")
        check(short.first == "Short answer." && short.rest == nil, "short reply untouched")
        let sentence = "This is a sentence about site safety and hard hats. "
        let long = String(repeating: sentence, count: 15)
        let parts = Compactor.split(long)
        check(parts.first.count <= Compactor.firstPacketLimit, "first packet within limit")
        check(parts.first.hasSuffix(Compactor.moreHint), "first packet offers more")
        check((parts.rest ?? "").count > 300, "rest is kept")
        let rebuilt = parts.first.replacingOccurrences(of: Compactor.moreHint, with: "") + " " + (parts.rest ?? "")
        check(NameMatcher.normalize(rebuilt) == NameMatcher.normalize(long), "no text lost between packets")
    }

    // Payloads.
    do {
        let task = TaskItem(title: "Order cement", assignee: "Ana", assigneeDevice: "iPhone 12", due: "Friday", createdBy: "Mac", createdAt: t0)
        let body = MeshPayload.encode(task) ?? ""
        check(MeshPayload.decodeTask(body) == task, "task payload round trip")
        let msg = MeshMessage(origin: "Mac", destination: .peer("iPhone 12"), kind: .task, body: body)
        check(MeshPayload.displayText(for: msg) == "Task: Order cement (Ana, due Friday)", "task display text")
        let rule = RuleEntry(title: "Hard hats", body: "Always", addedBy: "Mac", createdAt: t0)
        let rmsg = MeshMessage(origin: "Mac", kind: .rule, body: MeshPayload.encode(rule.meshSummary) ?? "")
        check(MeshPayload.decodeRule(rmsg.body)?.id == rule.id, "rule payload round trip")
        check(MeshPayload.displayText(for: rmsg) == "[Rule: Hard hats v1] Always", "rule display text")
        let answer = MeshMessage(origin: "Mac", kind: .answer, body: "x", compact: true, model: "qwen3:8b", latencyMs: 900, tokensPerSecond: 21.5)
        let back = try? MeshCodec.decode(MeshCodec.encode(answer))
        check(back?.compact == true && back?.model == "qwen3:8b" && back?.latencyMs == 900 && back?.tokensPerSecond == 21.5, "answer metadata survives the wire")
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","origin":"A","kind":"chat","body":"hi","ttl":7,"hops":["A"],"createdAt":1800000000000}"#
        check((try? MeshCodec.decode(Data(legacy.utf8)))?.compact == nil, "milestone 1 packets still decode")
    }
}
