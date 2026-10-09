// RoomTests.swift: encrypted rooms (protocol v2). Crypto is CryptoKit on Apple, swift-crypto on Linux.

import Foundation

@MainActor
func runRoomTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Tag derivation: deterministic, 16 hex chars, differs per key, hides label and key.
    do {
        let key = Data(repeating: 7, count: 32)
        let tag = RoomCrypto.tag(for: key)
        check(tag == RoomCrypto.tag(for: key), "rooms: tag is deterministic")
        check(tag.count == 16 && tag.allSatisfy { $0.isHexDigit }, "rooms: tag is 16 hex chars")
        check(tag != RoomCrypto.tag(for: Data(repeating: 8, count: 32)), "rooms: different keys give different tags")
        let a = Room(label: "BOHOL-7", key: key, creator: "iPhone 7597")
        let b = Room(label: "CEBU-2", key: key, creator: "Mac")
        check(a.id == b.id, "rooms: tag depends on the key only, not the label")
        check(!a.id.contains("BOHOL") && !key.map { String(format: "%02x", $0) }.joined().contains(a.id), "rooms: tag does not reveal label or key")
        check(Room.makeDefault().id == Room.makeDefault().id && Room.makeDefault().isDefault, "rooms: Default room tag is stable on every device")
        check(RoomCrypto.randomKey().count == 32 && RoomCrypto.randomKey() != RoomCrypto.randomKey(), "rooms: fresh keys are 256-bit and random")
    }

    // Join string round trip; the label is not the secret.
    do {
        let room = Room.create(label: "bohol 7", creator: "iPhone 7597", now: t0)
        check(room.label == "BOHOL-7", "rooms: label cleaned to BOHOL-7")
        let parsed = Room.parse(joinString: "  " + room.joinString + "\n", now: t0)
        check(parsed?.key == room.key && parsed?.label == "BOHOL-7" && parsed?.creator == "iPhone 7597", "rooms: join string round trip")
        check(parsed?.id == room.id, "rooms: joined device derives the same tag")
        check(Room.parse(joinString: "BOHOL-7") == nil, "rooms: the label alone cannot join")
        check(Room.parse(joinString: "PASA1.BOHOL-7.aVBob25l.c2hvcnQ") == nil, "rooms: a short key is rejected")
        check(Room.create(label: "", creator: "Mac").label.hasPrefix("ROOM-"), "rooms: empty label gets ROOM-xxxx")
        check(!room.joinString.contains(" "), "rooms: join string has no spaces (QR and copy safe)")
    }

    // Encrypt and decrypt round trip, with the routing header in the clear.
    let roomA = Room.create(label: "BOHOL-7", creator: "iPhone 7597", now: t0)
    let roomB = Room.create(label: "CEBU-2", creator: "iPhone 12", now: t0)
    do {
        let engine = RelayEngine(selfName: "iPhone 7597")
        engine.senderName = "Kyle"
        let inner = engine.makeOutgoing(kind: .chat, body: "Concrete pour moved to 3 PM")
        guard let outer = try? RoomEnvelope.seal(inner, in: roomA) else { check(false, "rooms: seal failed"); return }
        check(outer.kind == .sealed && outer.body.isEmpty && outer.senderName == nil, "rooms: outer packet hides kind, body and name")
        check(outer.room == roomA.id && outer.id == inner.id && outer.origin == inner.origin && outer.ttl == inner.ttl, "rooms: clear header keeps id, origin, ttl, room tag")
        let wire = (try? MeshCodec.encode(outer)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!wire.contains("Concrete") && !wire.contains("Kyle"), "rooms: plaintext never on the wire")
        let decoded = (try? MeshCodec.encode(outer)).flatMap { try? MeshCodec.decode($0) }
        let opened = decoded.flatMap { RoomEnvelope.open($0, in: roomA) }
        check(opened?.body == "Concrete pour moved to 3 PM" && opened?.kind == .chat && opened?.senderName == "Kyle", "rooms: round trip restores the message")
        check(RoomEnvelope.open(outer, in: roomB) == nil, "rooms: another room's key cannot open it")
        var otherKeySameTag = outer
        otherKeySameTag.room = roomB.id
        check(RoomEnvelope.open(otherKeySameTag, in: roomB) == nil, "rooms: relabelled tag still fails")
        var tampered = outer
        tampered.origin = "Mallory"
        check(RoomEnvelope.open(tampered, in: roomA) == nil, "rooms: a changed header fails authentication")
        var relayed = outer
        relayed.ttl -= 1
        relayed.hops.append("iPhone 12")
        let viaRelay = RoomEnvelope.open(relayed, in: roomA)
        check(viaRelay?.body == inner.body && viaRelay?.hops == ["iPhone 7597", "iPhone 12"] && viaRelay?.ttl == inner.ttl - 1, "rooms: relays may change ttl and hops only")
    }

    // A wrong-room packet is relayed but not delivered (and the relay still dedupes it).
    do {
        let sender = RelayEngine(selfName: "iPhone 12")
        let inner = sender.makeOutgoing(kind: .chat, body: "CEBU team only")
        guard let outer = try? RoomEnvelope.seal(inner, in: roomB) else { check(false, "rooms: seal B failed"); return }
        let wire = (try? MeshCodec.encode(outer)) ?? Data()
        let relay = RelayEngine(selfName: "iPhone 7597")  // member of BOHOL-7 only
        guard case .message(let packet)? = Optional(MeshCodec.decodeLenient(wire)) else { check(false, "rooms: v2 packet decodes as a message"); return }
        let decision = relay.handleIncoming(packet, from: "iPhone 12")
        check(decision.forward != nil && decision.forward?.sealed == outer.sealed && decision.forward?.ttl == outer.ttl - 1, "rooms: wrong-room packet is forwarded unchanged except ttl and hops")
        check(decision.deliver.flatMap { RoomEnvelope.open($0, in: roomA) } == nil, "rooms: wrong-room packet is not delivered")
        check(relay.handleIncoming(packet, from: "iPhone 12").isDuplicate, "rooms: dedupe works on the clear id")
        let member = RelayEngine(selfName: "MacBook")
        let atMember = member.handleIncoming(decision.forward!, from: "iPhone 7597")
        check(atMember.deliver.flatMap { RoomEnvelope.open($0, in: roomB) }?.body == "CEBU team only", "rooms: the CEBU member two hops away reads it")
    }

    // An "@ai" ask from room B passes through room A's AI Mac (role match is per room).
    do {
        let asker = RelayEngine(selfName: "iPhone 12")
        let ask = asker.makeOutgoing(kind: .ask, body: "gate code?", destination: .role(MeshDestination.aiRole))
        guard let outer = try? RoomEnvelope.seal(ask, in: roomB) else { check(false, "rooms: seal ask failed"); return }
        let macA = RelayEngine(selfName: "MacBook A", roles: [MeshDestination.aiRole])
        macA.roomID = roomA.id
        let atA = macA.handleIncoming(outer, from: "iPhone 12")
        check(atA.deliver == nil && atA.forward != nil, "rooms: room A's Mac relays room B's @ai ask instead of swallowing it")
        let macB = RelayEngine(selfName: "MacBook B", roles: [MeshDestination.aiRole])
        macB.roomID = roomB.id
        let atB = macB.handleIncoming(atA.forward!, from: "MacBook A")
        check(atB.deliver.flatMap { RoomEnvelope.open($0, in: roomB) }?.body == "gate code?" && atB.forward == nil, "rooms: room B's Mac answers it and it stops there")
    }

    // Per-room grounding: after a switch the assistant only sees the new room's memory.
    do {
        let a = OrgMemory(admins: ["MacBook"])
        _ = a.upsertRule(title: "Bohol gate", body: "Bohol gate code is 1234.", by: "MacBook", now: t0)
        let assistant = ExecutiveAssistant(memory: a, llm: FakeLLM([]), selfName: "MacBook")
        check(assistant.memory.rules.count == 1, "rooms: assistant starts on room A")
        assistant.switchRoom(memory: OrgMemory(admins: ["MacBook"]), clearedAt: t0)
        check(assistant.memory.rules.isEmpty && assistant.clearedAt == t0, "rooms: assistant grounds only on the new room")
    }

    // Foreign packets in the outbox: capped and short-lived; own packets unaffected.
    do {
        let engine = RelayEngine(selfName: "iPhone 7597")
        let mine = engine.makeOutgoing(kind: .chat, body: "mine")
        engine.enqueue(mine, now: t0)
        for i in 0..<70 {
            let m = RelayEngine(selfName: "x\(i)").makeOutgoing(kind: .sealed, body: "")
            engine.enqueue(m, foreign: true, now: t0)
        }
        check(engine.outbox.filter { $0.foreign == true }.count == engine.maxForeign, "rooms: foreign outbox capped at 50")
        check(engine.outbox.contains { $0.message.id == mine.id }, "rooms: own message survives the foreign cap")
        engine.pruneOutbox(now: t0.addingTimeInterval(3700))
        check(!engine.outbox.contains { $0.foreign == true }, "rooms: foreign packets expire after an hour")
    }

    // Migration: data from before rooms moves into the Default room, admins and clear kept.
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("pasa-rooms-\(UUID().uuidString)")
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    do {
        let legacy = OrgMemory(fileURL: base.appendingPathComponent("org-memory.json"), admins: ["MacBook Air"])
        _ = legacy.upsertRule(title: "Gate code", body: "Gate code is 4471.", by: "MacBook Air", now: t0)
        check(legacy.save(), "migration setup: legacy memory saved")
        try? Data("[]".utf8).write(to: base.appendingPathComponent("timeline.json"))

        let store = RoomStore(baseURL: base, legacyFiles: ["org-memory.json", "timeline.json"], legacyAdmins: ["iPhone 7597"], legacyClearedAt: t0)
        check(store.rooms.count == 1 && store.active.isDefault, "migration: one Default room")
        check(store.active.admins == ["iPhone 7597"] && store.active.clearedAt == t0, "migration: admins and clear watermark kept for Default")
        let moved = OrgMemory(fileURL: store.fileURL("org-memory.json"), admins: [])
        check(moved.rule(titled: "Gate code") != nil, "migration: rules now live in the Default room")
        check(fm.fileExists(atPath: store.fileURL("timeline.json")!.path), "migration: timeline moved too")
        check(fm.fileExists(atPath: base.appendingPathComponent("org-memory.json.bak").path), "migration: original kept as .bak")

        let created = store.join(roomA)
        check(created.id == roomA.id && store.active.id == roomA.id, "rooms: join makes the room active")
        store.join(roomA)
        check(store.rooms.count == 2, "rooms: joining twice keeps one copy")
        let reloaded = RoomStore(baseURL: base, legacyFiles: ["org-memory.json"])
        check(reloaded.rooms.count == 2 && reloaded.active.id == roomA.id, "rooms: rooms.json reloads, no second migration")
        check(reloaded.room(withID: Room.makeDefault().id)?.admins == ["iPhone 7597"], "rooms: Default settings survive reload")
    }

    // Per-room memory isolation: a rule saved in one room is not in another.
    do {
        let store = RoomStore(baseURL: base)
        let a = OrgMemory(fileURL: store.fileURL("org-memory.json", roomID: roomA.id), admins: ["iPhone 7597"])
        _ = a.upsertRule(title: "Bohol gate", body: "Bohol gate code is 1234.", by: "iPhone 7597", now: t0)
        a.recordChat(from: "Kyle", text: "Bohol only", at: t0, device: "iPhone 7597")
        check(a.save(), "isolation setup")
        let b = OrgMemory(fileURL: store.fileURL("org-memory.json", roomID: roomB.id), admins: [])
        check(!b.rules.contains { $0.title == "Bohol gate" } && b.recentChat(limit: 10).isEmpty, "isolation: room B sees nothing from room A")
        let defaultRoom = OrgMemory(fileURL: store.fileURL("org-memory.json", roomID: Room.makeDefault().id), admins: [])
        check(!defaultRoom.rules.contains { $0.title == "Bohol gate" } && defaultRoom.rules.contains { $0.title == "Gate code" }, "isolation: Default keeps its own rules")
        let aAgain = OrgMemory(fileURL: store.fileURL("org-memory.json", roomID: roomA.id), admins: [])
        check(aAgain.rules.contains { $0.title == "Bohol gate" }, "isolation: room A memory persists on disk")
    }

    // Admins per room, keyed by device id; the creator is pinned.
    do {
        let store = RoomStore(baseURL: nil)
        store.join(roomA)
        store.join(roomB)
        store.update(roomA.id) { $0.admins = ["iPhone 14"] }
        let adminsA = store.room(withID: roomA.id)!.adminDevices(selfID: "MacBook")
        let adminsB = store.room(withID: roomB.id)!.adminDevices(selfID: "MacBook")
        check(adminsA.contains("iPhone 7597") && adminsA.contains("iPhone 14"), "admins: creator pinned plus ticked device in room A")
        check(!adminsB.contains("iPhone 7597") && !adminsB.contains("iPhone 14") && adminsB.contains("iPhone 12"), "admins: room B has its own admins")
        check(adminsA.contains("MacBook") && adminsB.contains("MacBook"), "admins: the AI Mac itself stays admin")
        let memA = OrgMemory(admins: adminsA)
        let memB = OrgMemory(admins: adminsB)
        _ = memA.upsertRule(title: "Shared title", body: "A", by: "iPhone 7597", now: t0)
        _ = memB.upsertRule(title: "Shared title", body: "B", by: "iPhone 12", now: t0)
        _ = memA.setLocked(title: "Shared title", locked: true, by: "iPhone 7597", now: t0)
        if case .denied = memB.setLocked(title: "Shared title", locked: true, by: "iPhone 7597", now: t0) {
            check(true, "admins: room A creator cannot lock in room B")
        } else { check(false, "admins: room A creator cannot lock in room B") }
        store.update(roomA.id) { $0.admins = [] }
        check(store.room(withID: roomA.id)!.adminDevices(selfID: "MacBook").contains("iPhone 7597"), "admins: creator cannot be unticked")
        check(Room.makeDefault().adminDevices(selfID: "MacBook") == AdminPolicy.devices(adminIDs: [], selfID: "MacBook"), "admins: Default has no pinned creator")
    }
}
