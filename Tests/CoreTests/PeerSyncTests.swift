// PeerSyncTests.swift: phone-to-phone history sync (issue #6). Same cases as PeerSyncTest.kt.
import Foundation

func runPeerSyncTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func chat(_ body: String, from origin: String, minutesAgo: Double, id: UUID = UUID()) -> ChatEntry {
        let m = MeshMessage(id: id, origin: origin, kind: .chat, body: body, createdAt: now.addingTimeInterval(-minutesAgo * 60))
        return ChatEntry(id: m.id, message: m, direction: .received, receivedAt: now)
    }
    /// One sync exchange: `client` asks `server`, then merges what came back (by id).
    func exchange(_ server: [ChatEntry], into client: inout [ChatEntry]) -> Int {
        let got = PeerSync.select(from: server, request: PeerSync.request(from: client, now: now), now: now)
        let have = Set(client.map(\.id))
        for m in got where !have.contains(m.id) { client.append(ChatEntry(id: m.id, message: m, direction: .received, receivedAt: now, backfilled: true)) }
        return got.count
    }

    // Three phones, no Mac: A meets B, later B meets C; C ends up with A's message.
    var a = [chat("Gate 2 is closed, use gate 3", from: "PHONE_A", minutesAgo: 30)]
    var b = [chat("Water at the tent", from: "PHONE_B", minutesAgo: 20)]
    var c = [chat("Ana is at the clinic", from: "PHONE_C", minutesAgo: 5)]
    check(exchange(a, into: &b) == 1 && exchange(b, into: &a) == 1, "peer sync: A and B swap what they miss")
    check(exchange(b, into: &c) == 2, "peer sync: B carries A's and its own chat to C")
    check(c.contains { $0.message.body == "Gate 2 is closed, use gate 3" }, "peer sync: C has A's message without the Mac")
    check(exchange(b, into: &c) == 0, "peer sync: nothing resent once known")

    // Only team chat in the window; answers, rules, private messages and old chat stay out.
    var answer = MeshMessage(origin: "Mac-1", destination: .peer("PHONE_A"), kind: .answer, body: "Visits end at 8 PM.", createdAt: now)
    answer.replyTo = UUID()
    let rule = MeshMessage(origin: "Mac-1", kind: .rule, body: "{}", createdAt: now)
    var silent = MeshMessage(origin: "Mac-1", kind: .chat, body: "sync", createdAt: now); silent.silent = true
    let server = [chat("old news", from: "PHONE_A", minutesAgo: 7 * 60), chat("fresh", from: "PHONE_A", minutesAgo: 1),
                  ChatEntry(id: answer.id, message: answer, direction: .received, receivedAt: now),
                  ChatEntry(id: rule.id, message: rule, direction: .received, receivedAt: now),
                  ChatEntry(id: silent.id, message: silent, direction: .received, receivedAt: now),
                  chat("from the future", from: "PHONE_A", minutesAgo: -60)]
    let picked = PeerSync.select(from: server, request: PeerSync.request(from: [], now: now), now: now)
    check(picked.map(\.body) == ["fresh"], "peer sync: only broadcast team chat from the last 6 hours, no future stamps")

    // Clear watermarks on either side are respected.
    var cleared = PeerSync.request(from: [], now: now, clearedAt: now.addingTimeInterval(-10 * 60))
    check(PeerSync.select(from: [chat("before clear", from: "X", minutesAgo: 20)], request: cleared, now: now).isEmpty, "peer sync: asker's clear respected")
    cleared = PeerSync.request(from: [], now: now)
    check(PeerSync.select(from: [chat("before clear", from: "X", minutesAgo: 20)], request: cleared, now: now,
                          clearedAt: now.addingTimeInterval(-10 * 60)).isEmpty, "peer sync: server's clear respected")

    // A plain AI Mac backfill request is never answered by peer sync.
    check(PeerSync.select(from: server, request: SyncRequest(newest: nil, knownIDs: []), now: now).isEmpty, "peer sync: plain backfill request ignored")

    // Caps: count and bytes.
    let many = (0..<150).map { chat("message \($0) " + String(repeating: "x", count: 300), from: "PHONE_A", minutesAgo: Double(150 - $0)) }
    let capped = PeerSync.select(from: many, request: PeerSync.request(from: [], now: now), now: now)
    let size = capped.reduce(0) { $0 + ((try? MeshCodec.encode($1).count) ?? 0) }
    check(capped.count <= PeerSync.maxMessages && size <= PeerSync.maxBytes && capped.last?.body.hasPrefix("message 149") == true,
          "peer sync: capped by count and bytes, newest kept")
    let req = PeerSync.request(from: many + many, now: now)
    check((req.knownShort?.count ?? 0) == 150 && req.knownShort?.allSatisfy { $0.count == 12 } == true, "peer sync: known list holds short ids, no duplicates added")

    // Wire: the new fields encode, and a request without them still decodes.
    let fixed = UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8")!
    check(PeerSync.shortID(fixed) == "6f1c2a3b4d5e", "peer sync: short id is the first 12 hex characters")
    var wire = SyncRequest(newest: nil, knownIDs: []); wire.window = now; wire.knownShort = ["6f1c2a3b4d5e"]
    let json = SyncPayload(request: wire).encoded() ?? ""
    check(json.contains("\"window\":1800000000000") && json.contains("\"knownShort\":[\"6f1c2a3b4d5e\"]"), "peer sync wire: window and knownShort encoded")
    let old = SyncPayload.decode(#"{"request":{"knownIDs":[],"newest":1800000000000}}"#)
    check(old?.request?.window == nil && old?.request?.newest == now, "peer sync wire: request without the new fields still decodes")
}
