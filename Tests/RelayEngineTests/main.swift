// main.swift: tiny dependency-free test runner for RelayEngine and MeshMessage.
// Run with: scripts/test-relay.sh  (needs swiftc; works on macOS and Linux)

import Foundation

var failures = 0
var passes = 0

func check(_ condition: Bool, _ label: String, file: String = #file, line: Int = #line) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL [line \(line)]: \(label)")
    }
}

/// In-memory mesh: each node has a RelayEngine and a set of direct links.
final class SimMesh {
    var engines: [String: RelayEngine] = [:]
    var links: [String: Set<String>] = [:]
    var inbox: [String: [MeshMessage]] = [:]

    init(nodes: [String], links pairs: [(String, String)], aiNode: String? = nil) {
        for n in nodes {
            engines[n] = RelayEngine(selfName: n, roles: n == aiNode ? [MeshDestination.aiRole] : [])
            links[n] = []
            inbox[n] = []
        }
        for (a, b) in pairs {
            links[a, default: []].insert(b)
            links[b, default: []].insert(a)
        }
    }

    /// Floods `message` from `from` and processes every hop until quiet.
    func send(_ message: MeshMessage, from: String) {
        var queue: [(to: String, from: String, msg: MeshMessage)] = []
        for peer in links[from] ?? [] where !message.hops.contains(peer) {
            queue.append((peer, from, message))
        }
        while !queue.isEmpty {
            let item = queue.removeFirst()
            guard let engine = engines[item.to] else { continue }
            let decision = engine.handleIncoming(item.msg, from: item.from)
            if decision.isDuplicate { continue }
            if let d = decision.deliver { inbox[item.to, default: []].append(d) }
            if let f = decision.forward {
                for peer in links[item.to] ?? [] where !decision.forwardExcluding.contains(peer) {
                    queue.append((peer, item.to, f))
                }
            }
        }
    }
}

// 1. Codec round trip.
do {
    let m = MeshMessage(origin: "A", destination: .role("ai"), kind: .ask, body: "hello", replyTo: UUID(), replyPath: ["A", "B"])
    let data = try MeshCodec.encode(m)
    let back = try MeshCodec.decode(data)
    check(back.id == m.id, "codec keeps id")
    check(back.destination == .role("ai"), "codec keeps role destination")
    check(back.kind == .ask && back.body == "hello", "codec keeps kind and body")
    check(back.hops == ["A"], "codec keeps hops")
    check(abs(back.createdAt.timeIntervalSince(m.createdAt)) < 0.002, "codec keeps createdAt to the millisecond")
    let broadcast = MeshMessage(origin: "A", kind: .chat, body: "hi")
    check(try MeshCodec.decode(MeshCodec.encode(broadcast)).destination == nil, "codec keeps nil destination")
} catch {
    check(false, "codec threw \(error)")
}

// 2. Dedup: same id twice is dropped the second time.
do {
    let b = RelayEngine(selfName: "B")
    let m = MeshMessage(origin: "A", kind: .chat, body: "x")
    let first = b.handleIncoming(m, from: "A")
    let second = b.handleIncoming(m, from: "A")
    check(!first.isDuplicate && first.deliver != nil, "first copy delivered")
    check(second.isDuplicate && second.deliver == nil && second.forward == nil, "second copy dropped")
    check(first.deliver?.hops == ["A", "B"], "receiver appends itself to hops")
    check(first.forward?.ttl == MeshMessage.defaultTTL - 1, "forward decrements ttl")
    check(first.forwardExcluding == ["A", "B"], "forward excludes path")
}

// 3. Dedup entries expire.
do {
    let b = RelayEngine(selfName: "B", seenLifetime: 10)
    let t0 = Date()
    let m = MeshMessage(origin: "A", kind: .chat, body: "x")
    _ = b.handleIncoming(m, from: "A", now: t0)
    check(b.hasSeen(m.id, now: t0.addingTimeInterval(5)), "still seen before expiry")
    check(!b.hasSeen(m.id, now: t0.addingTimeInterval(11)), "forgotten after expiry")
}

// 4. Dedup cache size cap.
do {
    let b = RelayEngine(selfName: "B", maxSeen: 5)
    for _ in 0..<20 { b.markSeen(UUID()) }
    check(b.seenCount <= 5, "seen cache capped")
}

// 5. ttl 1 is delivered but not forwarded.
do {
    let b = RelayEngine(selfName: "B")
    let m = MeshMessage(origin: "A", kind: .chat, body: "x", ttl: 1)
    let d = b.handleIncoming(m, from: "A")
    check(d.deliver != nil && d.forward == nil, "ttl 1 stops here")
}

// 6. Own echo is dropped.
do {
    let a = RelayEngine(selfName: "A")
    let m = a.makeOutgoing(kind: .chat, body: "mine")
    var echo = m
    echo.hops = ["A", "B"]
    check(a.handleIncoming(echo, from: "B").isDuplicate, "own message coming back is dropped")
}

// 7. Forced relay: A and Mac are not linked (A blocks Mac). Ask goes A -> B -> Mac, answer comes back.
do {
    let mesh = SimMesh(nodes: ["A", "B", "Mac"], links: [("A", "B"), ("B", "Mac")], aiNode: "Mac")
    let ask = mesh.engines["A"]!.makeOutgoing(kind: .ask, body: "q?", destination: .role(MeshDestination.aiRole))
    mesh.send(ask, from: "A")
    check(mesh.inbox["B"]!.isEmpty, "relay B does not deliver an ask meant for the AI")
    let macGot = mesh.inbox["Mac"]!
    check(macGot.count == 1, "Mac receives the ask exactly once")
    check(macGot.first?.hops == ["A", "B", "Mac"], "ask path is A -> B -> Mac")
    check(macGot.first?.hopCount == 2, "ask took 2 hops")

    let answer = mesh.engines["Mac"]!.makeOutgoing(
        kind: .answer, body: "AI peer received: q?", destination: .peer("A"),
        replyTo: ask.id, replyPath: macGot.first?.hops)
    mesh.send(answer, from: "Mac")
    let aGot = mesh.inbox["A"]!
    check(aGot.count == 1, "A receives the answer once")
    check(aGot.first?.hops == ["Mac", "B", "A"], "answer path is Mac -> B -> A")
    check(aGot.first?.replyTo == ask.id, "answer links to ask")
    check(aGot.first?.replyPath == ["A", "B", "Mac"], "answer carries the ask path")
    check(mesh.inbox["B"]!.isEmpty, "B does not deliver a unicast for A")
}

// 8. Broadcast in a fully connected triangle reaches everyone exactly once.
do {
    let mesh = SimMesh(nodes: ["A", "B", "C"], links: [("A", "B"), ("B", "C"), ("A", "C")])
    let m = mesh.engines["A"]!.makeOutgoing(kind: .chat, body: "hi all")
    mesh.send(m, from: "A")
    check(mesh.inbox["B"]!.count == 1 && mesh.inbox["C"]!.count == 1, "broadcast delivered once per node")
    check(mesh.inbox["A"]!.isEmpty, "origin does not deliver its own broadcast")
}

// 9. Hop budget: chain n0-n1-n2-n3 with ttl 2 reaches n1 and n2 but not n3.
do {
    let mesh = SimMesh(nodes: ["n0", "n1", "n2", "n3"], links: [("n0", "n1"), ("n1", "n2"), ("n2", "n3")])
    let m = mesh.engines["n0"]!.makeOutgoing(kind: .chat, body: "short range", ttl: 2)
    mesh.send(m, from: "n0")
    check(mesh.inbox["n1"]!.count == 1, "ttl 2 reaches 1st hop")
    check(mesh.inbox["n2"]!.count == 1, "ttl 2 reaches 2nd hop")
    check(mesh.inbox["n3"]!.isEmpty, "ttl 2 does not reach 3rd hop")
}

// 10. Long chain with default ttl 7 reaches 7 hops away.
do {
    let names = (0...8).map { "n\($0)" }
    let pairs = (0..<8).map { (names[$0], names[$0 + 1]) }
    let mesh = SimMesh(nodes: names, links: pairs)
    let m = mesh.engines["n0"]!.makeOutgoing(kind: .chat, body: "far")
    mesh.send(m, from: "n0")
    check(mesh.inbox["n7"]!.count == 1, "default ttl reaches 7 hops")
    check(mesh.inbox["n7"]!.first?.hopCount == 7, "hop count is 7")
    check(mesh.inbox["n8"]!.isEmpty, "default ttl stops after 7 hops")
}

// 11. Unicast to a named peer stops at that peer.
do {
    let mesh = SimMesh(nodes: ["A", "B", "C"], links: [("A", "B"), ("B", "C")])
    let m = mesh.engines["A"]!.makeOutgoing(kind: .chat, body: "for B", destination: .peer("B"))
    mesh.send(m, from: "A")
    check(mesh.inbox["B"]!.count == 1, "B gets its unicast")
    check(mesh.inbox["C"]!.isEmpty, "unicast not delivered past its target")
}

// 12. Outbox: dedups, expires, drains.
do {
    let e = RelayEngine(selfName: "A", outboxLifetime: 60, maxOutbox: 3)
    let t0 = Date()
    let m1 = e.makeOutgoing(kind: .chat, body: "1", now: t0)
    e.enqueue(m1, now: t0)
    e.enqueue(m1, now: t0)
    check(e.outbox.count == 1, "outbox dedups by id")
    for i in 2...5 { e.enqueue(e.makeOutgoing(kind: .chat, body: "\(i)", now: t0), now: t0) }
    check(e.outbox.count == 3, "outbox capped")
    check(e.drainOutbox(now: t0.addingTimeInterval(120)).isEmpty, "expired items are dropped")
    e.enqueue(m1, excluding: ["Z"], now: t0)
    let drained = e.drainOutbox(now: t0.addingTimeInterval(1))
    check(drained.count == 1 && drained.first?.excluding == ["Z"], "drain returns item with exclusions")
    check(e.outbox.isEmpty, "drain empties outbox")
}

print("RelayEngine tests: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
