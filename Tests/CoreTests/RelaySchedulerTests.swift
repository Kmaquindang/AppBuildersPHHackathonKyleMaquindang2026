// RelaySchedulerTests.swift: relay jitter, cancel on duplicate, adaptive hop budget.
import Foundation

func runRelaySchedulerTests() {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    // Jitter ranges.
    check(RelayPolicy.jitterRange(broadcast: true, links: 2) == 10...120, "relay jitter: broadcast in a small group waits 10 to 120 ms")
    check(RelayPolicy.jitterRange(broadcast: true, links: 5) == 30...250, "relay jitter: dense room (5+ links) waits 30 to 250 ms")
    check(RelayPolicy.jitterRange(broadcast: false, links: 9) == 0...30, "relay jitter: directed packets (answers) wait at most 30 ms")
    var s = RelayScheduler<String>()
    var seen: [ClosedRange<Int>] = []
    let delay = s.schedule(a, item: "chat", targets: ["B", "C"], broadcast: true, links: 3, now: t0) { r in seen.append(r); return r.upperBound }
    check(abs(delay - 0.12) < 0.0001 && seen == [10...120], "relay jitter: the delay is drawn from the range")
    check(s.due(now: t0.addingTimeInterval(0.1)).isEmpty, "relay jitter: not sent before its delay")
    let ready = s.due(now: t0.addingTimeInterval(0.12))
    check(ready.map(\.item) == ["chat"] && s.pending.isEmpty, "relay jitter: sent when due, then forgotten")
    let real = (0..<200).map { _ -> TimeInterval in var r = RelayScheduler<Int>(); return r.schedule(UUID(), item: 0, targets: ["X"], broadcast: true, links: 1) }
    check(real.allSatisfy { $0 >= 0.010 && $0 <= 0.120 } && Set(real).count > 20, "relay jitter: real random delays stay in range and vary")

    // Cancel when every target already has it.
    var k = RelayScheduler<String>()
    k.schedule(b, item: "x", targets: ["B", "C"], broadcast: true, links: 3, now: t0)
    check(!k.heardDuplicate(b, from: "B"), "relay cancel: one neighbor's copy is not enough when another still needs it")
    check(k.pending[b]?.heardFrom == ["B"] && k.pending[b]?.targets == ["C"], "relay cancel: that neighbor is skipped when we send")
    check(k.heardDuplicate(b, from: "C") && k.pending[b] == nil && k.cancelledCount == 1, "relay cancel: cancelled once every neighbor has it")
    check(!k.heardDuplicate(UUID(), from: "Z"), "relay cancel: a duplicate for nothing pending is a no-op")

    // Dense room: 2 copies heard cancel a broadcast; directed packets are not cancelled that way.
    var dense = RelayScheduler<String>()
    let many: Set<String> = ["B", "C", "D", "E", "F", "G"]
    dense.schedule(c, item: "chat", targets: many, broadcast: true, links: 6, now: t0)
    _ = dense.heardDuplicate(c, from: "B")
    check(dense.heardDuplicate(c, from: "C"), "relay cancel: in a dense room a broadcast heard twice is dropped")
    dense.schedule(d, item: "answer", targets: many, broadcast: false, links: 6, now: t0)
    _ = dense.heardDuplicate(d, from: "B"); _ = dense.heardDuplicate(d, from: "C"); _ = dense.heardDuplicate(d, from: "D")
    check(dense.pending[d] != nil, "relay cancel: a directed packet keeps going until every target has it")

    // Adaptive hop budget.
    check(RelayPolicy.forwardTTL(6, links: 2, broadcast: true) == 6, "relay ttl: thin chain keeps the full hop budget")
    check(RelayPolicy.forwardTTL(6, links: 6, broadcast: true) == 4, "relay ttl: crowd (6+ links) caps a relayed broadcast at 4 more hops")
    check(RelayPolicy.forwardTTL(3, links: 9, broadcast: true) == 3, "relay ttl: a smaller budget is never raised")
    check(RelayPolicy.forwardTTL(6, links: 9, broadcast: false) == 6, "relay ttl: directed packets keep their budget in a crowd")
    let engine = RelayEngine(selfName: "Relay")
    let m = MeshMessage(origin: "iPhone 12", kind: .chat, body: "PATIENT_A synthetic", ttl: 7)
    check(engine.handleIncoming(m, from: "iPhone 12", links: 7).forward?.ttl == 4, "relay ttl: RelayEngine applies the crowd cap")
    let m2 = MeshMessage(origin: "iPhone 12", kind: .chat, body: "PATIENT_A synthetic 2", ttl: 7)
    check(engine.handleIncoming(m2, from: "iPhone 12", links: 2).forward?.ttl == 6, "relay ttl: RelayEngine keeps ttl - 1 in a small group")
    check(s.nextDue == nil, "relay scheduler: no timer needed when nothing waits")
}
