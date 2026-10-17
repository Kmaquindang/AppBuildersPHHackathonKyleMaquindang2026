// TaskDetailsTests.swift: task card details (owner, Oct 9, 2026, 9:50 PM PHT): status with Overdue,
// relative age, board order, owner or admin Done, backward-compatible decoding.

import Foundation

@MainActor
func runTaskDetailsTests() async {
    let cal = manilaCalendar()
    let fri = manila(2026, 10, 9, 10)   // Friday Oct 9, 2026, 10 AM PHT

    // Due text resolution (relative to creation).
    check(TaskDue.resolve("Friday", from: fri, calendar: cal) == manila(2026, 10, 9, 23, 59).addingTimeInterval(59), "due: Friday said on Friday is end of today")
    check(TaskDue.resolve("Saturday", from: fri, calendar: cal) == manila(2026, 10, 10, 23, 59).addingTimeInterval(59), "due: next Saturday")
    check(TaskDue.resolve("next Friday", from: fri, calendar: cal) == manila(2026, 10, 16, 23, 59).addingTimeInterval(59), "due: next Friday is a week out")
    check(TaskDue.resolve("tomorrow 8 AM", from: fri, calendar: cal) == manila(2026, 10, 10, 8), "due: tomorrow 8 AM")
    check(TaskDue.resolve("bukas 5:30pm", from: fri, calendar: cal) == manila(2026, 10, 10, 17, 30), "due: Tagalog bukas with time")
    check(TaskDue.resolve("today noon", from: fri, calendar: cal) == manila(2026, 10, 9, 12), "due: today noon")
    check(TaskDue.resolve("Oct 12", from: fri, calendar: cal) == manila(2026, 10, 12, 23, 59).addingTimeInterval(59), "due: month day")
    check(TaskDue.resolve("2026-10-11 17:00", from: fri, calendar: cal) == manila(2026, 10, 11, 17), "due: ISO with 24 h time")
    check(TaskDue.resolve("Biyernes", from: manila(2026, 10, 10, 9), calendar: cal) == manila(2026, 10, 16, 23, 59).addingTimeInterval(59), "due: Biyernes from Saturday is next Friday")
    check(TaskDue.resolve("next week", from: fri, calendar: cal) == nil, "due: vague text is not a deadline (fail closed)")
    check(TaskDue.resolve("after the pour", from: fri, calendar: cal) == nil, "due: unknown text gives nil")
    check(TaskDue.resolve(nil, from: fri, calendar: cal) == nil && TaskDue.resolve("  ", from: fri, calendar: cal) == nil, "due: none")

    // Status: Overdue only when due passed and not done.
    let cement = TaskItem(title: "Order cement", assignee: "Ana", assigneeDevice: "PHONE_ANA", due: "tomorrow 8 AM", createdBy: "PHONE_KYLE", createdAt: fri)
    check(cement.displayStatus(now: manila(2026, 10, 10, 7), calendar: cal) == .open, "status: open before due")
    check(cement.displayStatus(now: manila(2026, 10, 10, 9), calendar: cal) == .overdue, "status: overdue after due")
    var doneCement = cement; doneCement.status = .done
    check(doneCement.displayStatus(now: manila(2026, 10, 12, 9), calendar: cal) == .done, "status: done is never overdue")
    let vague = TaskItem(title: "Sweep", due: "soon", createdBy: "Mac", createdAt: fri)
    check(vague.displayStatus(now: manila(2026, 12, 1, 9), calendar: cal) == .open, "status: unparsed due never overdue")
    check(TaskDisplayStatus.overdue.label == "Overdue" && TaskDisplayStatus.open.label == "Open" && TaskDisplayStatus.done.label == "Done", "status: text labels")

    // Age.
    check(TaskAge.short(from: fri, now: fri.addingTimeInterval(20)) == "just now", "age: just now")
    check(TaskAge.short(from: fri, now: fri.addingTimeInterval(5 * 60)) == "5m ago", "age: minutes")
    check(TaskAge.short(from: fri, now: fri.addingTimeInterval(2 * 3600 + 59)) == "2h ago", "age: hours")
    check(TaskAge.short(from: fri, now: fri.addingTimeInterval(3 * 86400)) == "3d ago", "age: days")
    check(TaskAge.short(from: fri, now: fri.addingTimeInterval(15 * 86400)) == "2w ago", "age: weeks")
    check(TaskAge.short(from: fri, now: fri.addingTimeInterval(-300)) == "just now", "age: clock skew is just now")
    check(TaskAge.opened(cement, now: fri.addingTimeInterval(7200)) == "opened 2h ago", "age: opened label")
    check(TaskAge.spoken(from: fri, now: fri.addingTimeInterval(3600)) == "1 hour ago" && TaskAge.spoken(from: fri, now: fri.addingTimeInterval(7200)) == "2 hours ago", "age: spoken for VoiceOver")

    // Board order.
    let now = manila(2026, 10, 10, 9)
    let late1 = TaskItem(title: "Late A", due: "Friday", createdBy: "Mac", createdAt: fri)                 // Oct 9 end
    let late2 = TaskItem(title: "Late B", due: "today 8 AM", createdBy: "Mac", createdAt: manila(2026, 10, 10, 6)) // Oct 10 8 AM
    let soon = TaskItem(title: "Soon", due: "Sunday", createdBy: "Mac", createdAt: fri)
    let later = TaskItem(title: "Later", due: "Oct 20", createdBy: "Mac", createdAt: fri)
    let undatedOld = TaskItem(title: "Undated old", createdBy: "Mac", createdAt: fri)
    let undatedNew = TaskItem(title: "Undated new", createdBy: "Mac", createdAt: manila(2026, 10, 10, 8))
    var d1 = TaskItem(title: "Done first", createdBy: "Mac", createdAt: fri); d1.status = .done; d1.completedAt = manila(2026, 10, 9, 12)
    var d2 = TaskItem(title: "Done old build", createdBy: "Mac", createdAt: fri, updatedAt: manila(2026, 10, 10, 8)); d2.status = .done
    let board = TaskBoard([undatedOld, d1, later, late2, soon, d2, undatedNew, late1], now: now, calendar: cal)
    check(board.overdue.map(\.title) == ["Late A", "Late B"], "sort: overdue, most overdue first: \(board.overdue.map(\.title))")
    check(board.open.map(\.title) == ["Soon", "Later", "Undated new", "Undated old"], "sort: open by due, then undated newest: \(board.open.map(\.title))")
    check(board.done.map(\.title) == ["Done old build", "Done first"], "sort: done newest finished first (old builds use updatedAt)")
    check(d2.doneAt == manila(2026, 10, 10, 8) && cement.doneAt == nil, "doneAt falls back to updatedAt")

    // Backward decode: a task JSON from an older build (no completedAt) and forward: old decoder ignores the new key.
    let oldJSON = #"{"createdAt":1791511200000,"createdBy":"Mac","id":"6F1C2C6E-1111-4A6B-9C11-2D6E0B9C1A11","status":"done","title":"Call supplier","updatedAt":1791514800000,"completedBy":"PHONE_ANA"}"#
    if let old = MeshPayload.decodeTask(oldJSON) {
        check(old.completedAt == nil && old.doneAt == old.updatedAt && old.assignee == nil && old.due == nil, "decode: old task without new fields gets defaults")
        check(old.displayStatus(now: Date()) == .done, "decode: old done task shows Done")
    } else {
        check(false, "decode: old task JSON decodes")
    }
    var withDone = cement; withDone.status = .done; withDone.completedAt = manila(2026, 10, 9, 15); withDone.completedBy = "PHONE_ANA"
    if let body = MeshPayload.encode(withDone), let back = MeshPayload.decodeTask(body) {
        check(back.completedAt == withDone.completedAt && back == withDone, "decode: completedAt round trips")
        struct OldTask: Decodable { var id: UUID; var title: String; var status: String }
        let old = try? JSONDecoder().decode(OldTask.self, from: Data(body.utf8))
        check(old?.title == "Order cement" && old?.status == "done", "decode: older builds still read the new JSON (status stays open/done)")
    } else {
        check(false, "decode: encode new task")
    }
    let mem = OrgMemory(admins: ["Mac"])
    let t = mem.addTask(title: "Fix gate", assignee: "Ana", assigneeDevice: "PHONE_ANA", due: nil, by: "Mac", now: fri)
    let marked = mem.markDone(t.id, by: "PHONE_ANA", now: manila(2026, 10, 9, 11))
    check(marked?.completedAt == manila(2026, 10, 9, 11) && marked?.completedBy == "PHONE_ANA", "markDone stamps completedAt")
    let reopened = mem.reopen(t.id, by: "Mac", now: manila(2026, 10, 9, 12))
    check(reopened?.completedAt == nil && reopened?.completedBy == nil, "reopen clears completedAt")

    // Who may mark done.
    check(cement.canComplete(by: "PHONE_ANA", isAdmin: false), "done: owner device may")
    check(!cement.canComplete(by: "PHONE_BEN", isAdmin: false), "done: someone else may not")
    check(cement.canComplete(by: "PHONE_BEN", isAdmin: true), "done: admin may")
    check(!doneCement.canComplete(by: "PHONE_ANA", isAdmin: true), "done: already done")
    let byName = TaskItem(title: "Check generator", assignee: "Ana", createdBy: "Mac")
    check(byName.canComplete(by: "PHONE_X", names: ["ana"], isAdmin: false), "done: owner by chosen name when device unknown")
    check(byName.canComplete(by: "PHONE_ANA", isAdmin: false, roster: ["Ana": "PHONE_ANA"]), "done: owner by roster")
    check(TaskItem(title: "Sweep", createdBy: "Mac").canComplete(by: "PHONE_BEN", isAdmin: false), "done: anyone for a task with no owner")

    // Done button flow on the Mac: fast path with short id, owner or admin enforced.
    check(IntentParser.fastPath("mark done: Order cement #\(cement.shortID)")?.kind == .markDone, "fast path: mark done")
    do {
        let mem = OrgMemory(admins: ["Mac"])
        let a1 = mem.addTask(title: "Order cement", assignee: "Ana", assigneeDevice: "PHONE_ANA", due: "Friday", by: "Mac")
        let a2 = mem.addTask(title: "Order cement", assignee: "Ben", assigneeDevice: "PHONE_BEN", due: "Monday", by: "Mac")
        let ai = ExecutiveAssistant(memory: mem, llm: FakeLLM([]), selfName: "Mac")
        let denied = await ai.handle("mark done: Order cement #\(a1.shortID)", from: "PHONE_BEN")
        check(denied.taskUpdates.isEmpty && denied.reply.contains("or an admin"), "done: Mac refuses a non-owner: \(denied.reply)")
        let ok = await ai.handle("mark done: Order cement #\(a2.shortID)", from: "PHONE_BEN")
        check(ok.taskUpdates.map(\.id) == [a2.id] && mem.tasks.first { $0.id == a2.id }?.status == .done, "done: short id picks the exact duplicate-titled task")
        let admin = await ai.handle("mark done: Order cement #\(a1.shortID)", from: "Mac")
        check(admin.taskUpdates.first?.id == a1.id && admin.taskUpdates.first?.completedAt != nil, "done: admin may finish another's task")
    }
}
