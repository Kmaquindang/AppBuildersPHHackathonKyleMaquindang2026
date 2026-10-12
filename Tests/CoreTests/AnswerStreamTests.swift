// AnswerStreamTests.swift: streamed answers (issue #2). Same cases as AnswerStreamTest.kt.
import Foundation

func runAnswerStreamTests() {
    let t0 = Date(timeIntervalSince1970: 1_000)

    // Visible text: tags and think blocks hidden, unfinished ones held back.
    check(AnswerStreamer.visible("<think>\n\n</think>\n\nVisits end at 8 PM.") == "Visits end at 8 PM.", "stream: empty think block hidden")
    check(AnswerStreamer.visible("<think>plan the answ") == "", "stream: unclosed think hides the rest")
    check(AnswerStreamer.visible("Visits end at 8 PM [Rule: Visiting hours].") == "Visits end at 8 PM.", "stream: citation tag hidden")
    check(AnswerStreamer.visible("Visits end at 8 PM [Rule: Visit") == "Visits end at 8 PM", "stream: unclosed tag held back")
    check(AnswerStreamer.visible("See [Doc 2] and <b") == "See and", "stream: doc tag hidden, unclosed angle held back")

    // Pacing: nothing until 40 new characters, then at most one part per 0.6 s.
    var s = AnswerStreamer()
    check(s.add("Visits end ", now: t0) == nil, "stream: short start waits")
    let first = s.add("at 8 PM on weekdays, and the gate closes at 9.", now: t0)
    check(first == AnswerStreamer.Part(seq: 0, text: "Visits end at 8 PM on weekdays, and the gate closes at 9."), "stream: first part once 40 characters are ready")
    check(s.add(" Bring your ID card to the front desk every time.", now: t0.addingTimeInterval(0.3)) == nil, "stream: waits for the interval")
    let second = s.add(" Ask Ana", now: t0.addingTimeInterval(0.7))
    check(second == AnswerStreamer.Part(seq: 1, text: " Bring your ID card to the front desk every time. Ask Ana"), "stream: second part is the exact delta, space included")
    check((first?.text ?? "") + (second?.text ?? "") == AnswerStreamer.visible(
        "Visits end at 8 PM on weekdays, and the gate closes at 9. Bring your ID card to the front desk every time. Ask Ana"), "stream: parts join to the visible text")

    // A tag that closes later never rewrites text already sent.
    var tagged = AnswerStreamer()
    let a = tagged.add("The quiet room is for staff only, after 10 PM every night [Rule: Qu", now: t0)
    let b = tagged.add("iet room]. Students use the library until closing time each day.", now: t0.addingTimeInterval(1))
    check(a?.text == "The quiet room is for staff only, after 10 PM every night", "stream: text before an open tag goes")
    check(b?.text == ". Students use the library until closing time each day.", "stream: text after the closed tag continues it")

    // Caps: at most 8 parts and the first-packet size.
    var long = AnswerStreamer()
    var parts: [AnswerStreamer.Part] = []
    for i in 0..<40 {
        if let p = long.add(String(repeating: "word ", count: 10), now: t0.addingTimeInterval(Double(i))) { parts.append(p) }
    }
    let total = parts.map(\.text).joined()
    check(parts.count <= AnswerStreamer.maxParts && total.count <= AnswerStreamer.maxChars, "stream: parts and characters capped")
    check(parts.map(\.seq) == Array(0..<parts.count), "stream: sequence numbers count up from 0")

    // Phones: in-order prefix only.
    let ask = UUID(), other = UUID()
    var streams = AnswerStreams()
    check(streams.add(askID: ask, seq: 1, text: " world", room: "r1", now: t0) == false, "streams: part 1 alone shows nothing")
    check(streams.text(for: ask) == nil, "streams: gap at part 0 hides text")
    check(streams.add(askID: ask, seq: 0, text: "Hello", room: "r1", now: t0), "streams: part 0 fills the gap")
    check(streams.text(for: ask) == "Hello world", "streams: in-order prefix joins exact deltas")
    check(streams.add(askID: ask, seq: 0, text: "Again", room: "r1", now: t0) == false, "streams: duplicate part ignored")
    check(streams.add(askID: ask, seq: 3, text: "!", room: "r1", now: t0) == false && streams.text(for: ask) == "Hello world", "streams: part after a gap waits")
    check(streams.add(askID: ask, seq: 2, text: " x", room: "r2", now: t0) == false, "streams: part from another room refused")
    check(streams.add(askID: ask, seq: AnswerStreams.maxParts, text: "x", room: "r1", now: t0) == false, "streams: sequence over the cap refused")
    _ = streams.add(askID: other, seq: 0, text: "Other answer", room: "r2", now: t0.addingTimeInterval(1))
    check(streams.open(in: "r1") == [ask] && streams.open(in: "r2") == [other], "streams: open asks per room")

    // Final answer replaces the stream; late parts never bring it back.
    streams.finish(ask, now: t0.addingTimeInterval(2))
    check(streams.text(for: ask) == nil, "streams: final answer clears partial text")
    check(streams.add(askID: ask, seq: 2, text: " late", room: "r1", now: t0.addingTimeInterval(3)) == false, "streams: late part after final ignored")

    // No final answer: the partial is dropped after the timeout (fail closed).
    check(streams.expire(now: t0.addingTimeInterval(60)).isEmpty, "streams: kept before the timeout")
    check(streams.expire(now: t0.addingTimeInterval(1 + AnswerStreams.timeout)) == [other] && streams.text(for: other) == nil, "streams: dropped after the timeout")
    var big = AnswerStreams()
    check(big.add(askID: ask, seq: 0, text: String(repeating: "a", count: AnswerStreams.maxChars + 1), room: "r1", now: t0) == false, "streams: oversized part refused")

    // Wire: the new kind and field round-trip, and ride the urgent lane.
    var part = MeshMessage(origin: "Mac-1", kind: .answerPart, body: " at 8 PM", replyTo: ask)
    part.part = 1
    let json = String(decoding: (try? MeshCodec.encode(part)) ?? Data(), as: UTF8.self)
    check(json.contains("\"kind\":\"answerPart\"") && json.contains("\"part\":1"), "stream wire: kind and part encoded")
    check((try? MeshCodec.decode(Data(json.utf8)))?.part == 1, "stream wire: part decodes")
    check(BLELane.of(kind: .answerPart, bytes: 600) == .urgent, "stream wire: parts ride the urgent lane")

    // Old builds: a sealed packet whose inner kind they do not know cannot be opened (nothing is
    // shown or deduped), but the clear outer packet still decodes and relays.
    let room = Room(label: "WARD-3", key: RoomCrypto.randomKey(), creator: "Mac-1")
    var outer = MeshMessage(origin: "Mac-1", kind: .sealed, body: "", createdAt: Date(timeIntervalSince1970: 0), v: MeshMessage.protocolVersion)
    outer.room = room.id
    var innerJSON = String(decoding: (try? MeshCodec.encode(MeshMessage(id: outer.id, origin: "Mac-1", kind: .answerPart, body: "x", v: 2))) ?? Data(), as: UTF8.self)
    innerJSON = innerJSON.replacingOccurrences(of: "\"answerPart\"", with: "\"answerPiece2099\"")
    if let key = room.contentKey, let box = try? RoomCrypto.seal(Data(innerJSON.utf8), key: key, aad: RoomEnvelope.aad(outer, room: room.id)) {
        outer.sealed = RoomCrypto.base64url(box)
    }
    check(RoomEnvelope.open(outer, in: room) == nil, "stream compat: unknown inner kind is not opened (not shown)")
    if case .message(let m)? = (try? MeshCodec.encode(outer)).map(MeshCodec.decodeLenient) {
        check(m.kind == .sealed && m.room == room.id, "stream compat: outer packet still decodes for relaying")
    } else {
        check(false, "stream compat: outer packet still decodes for relaying")
    }
}
