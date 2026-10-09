// MultiRoomTests.swift: multi-room AI Mac, discovery beacons, per-room admin (kick, close, cap,
// join requests, key rotation), Mac sleep and wake replay, migration. Deterministic: fixed
// clocks, no network. Random keys are fresh per run but every check is about who can open what.

import Foundation

/// A simulated device: its identity plus its own copy of the room record.
private struct SimDevice {
    var id: String
    var name: String
    var identity = DeviceIdentity.generate()
    var room: Room

    init(id: String, name: String, room: Room) {
        self.id = id
        self.name = name
        self.room = room
    }

    mutating func hear(_ blob: SignedBlob?, now: Date) -> RoomGovernor.Acceptance {
        guard let blob else { return .rejected("nil") }
        return RoomGovernor.accept(blob, into: &room, identity: identity, now: now)
    }

    func seal(_ text: String, now: Date) -> MeshMessage? {
        let m = MeshMessage(origin: id, kind: .chat, body: text, createdAt: now, v: MeshMessage.protocolVersion)
        return try? RoomEnvelope.seal(m, in: room)
    }
}

private func applied(_ a: RoomGovernor.Acceptance) -> Bool {
    if case .applied = a { return true }
    return false
}

private func tamper(_ blob: SignedBlob) -> SignedBlob {
    var copy = blob
    var bytes = [UInt8](copy.body)
    if let i = bytes.firstIndex(of: UInt8(ascii: "1")) { bytes[i] = UInt8(ascii: "9") } else { bytes[bytes.count / 2] ^= 1 }
    copy.body = Data(bytes)
    return copy
}

@MainActor
func runMultiRoomTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let fastRounds = 1000

    // Identity, signatures, fingerprints.
    do {
        let id = DeviceIdentity.generate()
        check(id.signKey.count == 32 && id.boxKey.count == 32, "multiroom: device has signing and agreement keys")
        let blob = id.sign(Data("hello".utf8), domain: "test")
        check(blob?.isValid == true, "multiroom: signature verifies")
        var bad = blob!
        bad.body = Data("hellp".utf8)
        check(!bad.isValid, "multiroom: changed body fails verification")
        var otherDomain = blob!
        otherDomain.domain = "beacon"
        check(!otherDomain.isValid, "multiroom: signature is bound to its domain")
        check(id.fingerprint.count == 14 && id.fingerprint.split(separator: "-").count == 3, "multiroom: fingerprint looks like XXXX-XXXX-XXXX")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pasa-id-\(UUID().uuidString).json")
        let a = DeviceIdentity.loadOrCreate(at: tmp)
        let b = DeviceIdentity.loadOrCreate(at: tmp)
        check(a == b, "multiroom: identity survives a restart")
        try? FileManager.default.removeItem(at: tmp)
    }

    // Key boxes: only the addressed member opens; wrong epoch or room fails.
    do {
        let a = DeviceIdentity.generate(), b = DeviceIdentity.generate()
        let key = RoomCrypto.randomKey()
        let box = KeyBox.seal(key, to: a.boxKey, room: "r1", epoch: 3)!
        check(KeyBox.open(box, secret: a.boxSecret, room: "r1", epoch: 3) == key, "multiroom: member opens its key box")
        check(KeyBox.open(box, secret: b.boxSecret, room: "r1", epoch: 3) == nil, "multiroom: another device cannot open the key box")
        check(KeyBox.open(box, secret: a.boxSecret, room: "r1", epoch: 4) == nil, "multiroom: key box is bound to its epoch")
        check(KeyBox.open(box, secret: a.boxSecret, room: "r2", epoch: 3) == nil, "multiroom: key box is bound to its room")
    }

    // Create: admin key, epoch 1 random key, creator is the first member.
    let base = Room.fromPasscode(name: "GROUP-1", passcode: "mangga hinog 42", creator: "Mac", now: t0, rounds: fastRounds)!
    var admin = SimDevice(id: "Mac", name: "Teacher", room: base)
    let created = RoomGovernor.setUp(&admin.room, identity: admin.identity, device: "Mac", name: "Teacher", now: t0)
    check(created != nil, "multiroom: room set up with an admin key")
    check(admin.room.epoch == 1 && admin.room.contentKey != nil && admin.room.contentKey != admin.room.key,
          "multiroom: new rooms start at epoch 1 with a key that is not the passcode key")
    check(RoomGovernor.isAdmin(admin.room, identity: admin.identity) && RoomGovernor.isCreatorAdmin(admin.room), "multiroom: creator is admin")
    check(admin.room.memberCount == 1 && admin.room.cap == RoomLimits.defaultCap && admin.room.isListed, "multiroom: 1 member, cap 12, Listed by default")
    check(admin.room.joinString.contains(".A"), "multiroom: join string carries the admin key")
    let qr = Room.parse(joinString: admin.room.joinString, now: t0)
    check(qr?.gov?.adminKey == admin.room.gov?.adminKey && qr?.gov?.pending == true, "multiroom: QR joiner pins the admin key and waits for admission")
    check(qr?.contentKey == nil, "multiroom: the QR code alone does not give the epoch key")
    check(Room.parse(joinString: admin.room.joinString + ".zz") == nil, "multiroom: unknown join string flag is rejected")

    // Passcode joiner: same base key, pending, cannot write until admitted.
    var ana = SimDevice(id: "iPhone 12", name: "Ana",
                        room: Room.fromPasscode(name: "group 1", passcode: "mangga hinog 42", creator: "", now: t0, rounds: fastRounds)!)
    ana.room.gov = RoomGov(pending: true)
    check(ana.room.id == admin.room.id, "multiroom: joiner derives the same room tag")
    check(!ana.room.canSend && ana.room.sendBlocker?.contains("Waiting") == true, "multiroom: pending joiner cannot send and is told why")
    let adminChat = admin.seal("hello group", now: t0)!
    check(adminChat.epoch == 1, "multiroom: content goes out at epoch 1")
    check(RoomEnvelope.open(adminChat, in: ana.room, now: t0) == nil, "multiroom: passcode alone cannot read epoch 1 traffic")
    check(RoomEnvelope.isAhead(adminChat, of: ana.room), "multiroom: joiner sees it is behind (asks for the manifest)")

    // TOFU: the first self-signed manifest that opens with the base key pins the admin.
    check(applied(ana.hear(admin.room.gov?.signed, now: t0)), "multiroom: joiner accepts the first manifest (trust on first use)")
    check(ana.room.gov?.adminKey == admin.room.gov?.adminKey && ana.room.isPending, "multiroom: admin pinned, still pending")
    check(RoomGovernor.wantsAdmission(ana.room, identity: ana.identity), "multiroom: joiner wants admission")

    // Join request -> admin admits -> joiner gets the epoch key.
    let request = RoomGovernor.joinRequest(room: ana.room, identity: ana.identity, device: ana.id, name: ana.name, now: t0)!
    let admitted = RoomGovernor.admit(request, room: &admin.room, identity: admin.identity, now: t0)
    guard case .admitted(let m2) = admitted else { check(false, "multiroom: admin admits the join request"); return }
    check(admin.room.memberCount == 2, "multiroom: roster has 2 members")
    if case .applied(let change) = ana.hear(m2, now: t0) {
        check(change.admitted, "multiroom: joiner sees it was admitted")
    } else { check(false, "multiroom: joiner accepts the admission manifest") }
    check(ana.room.canSend && ana.room.contentKey == admin.room.contentKey, "multiroom: admitted joiner holds the epoch key")
    check(RoomEnvelope.open(adminChat, in: ana.room, now: t0)?.body == "hello group", "multiroom: admitted joiner reads room chat")
    check(RoomGovernor.admit(request, room: &admin.room, identity: admin.identity, now: t0) == .already, "multiroom: repeated join request is not a second member")
    // A forged join request (signed by one key, listing another) is invalid.
    var forged = JoinRequest(room: ana.room.id, device: "x", name: "x", signKey: DeviceIdentity.generate().signKey, boxKey: ana.identity.boxKey, at: t0)
    let forgedBlob = ana.identity.sign(try! PasaJSON.encoder.encode(forged), domain: RoomGovernor.joinDomain)!
    check(RoomGovernor.admit(forgedBlob, room: &admin.room, identity: admin.identity, now: t0) == .invalid, "multiroom: join request must be signed by the key it lists")
    forged.signKey = ana.identity.signKey

    // Content sealed with the passcode key is refused once the room has a random epoch key.
    do {
        var old = admin.room
        old.gov = nil
        let sneaky = try! RoomEnvelope.seal(MeshMessage(origin: "x", kind: .chat, body: "hi", v: 2), in: old)
        check(RoomEnvelope.open(sneaky, in: admin.room, now: t0) == nil, "multiroom: passcode-key chat is refused at epoch 1")
        let control = try! RoomEnvelope.seal(MeshMessage(origin: "x", kind: .roomControl, body: "{}", v: 2), in: admin.room)
        check(control.epoch == nil && RoomEnvelope.open(control, in: ana.room, now: t0)?.kind == .roomControl,
              "multiroom: room control always uses the passcode key")
    }

    // Replay, tamper, forgery.
    do {
        let m1 = created!
        check(ana.hear(m1, now: t0) == .stale, "multiroom: an older manifest is ignored (replay)")
        check(ana.hear(m2, now: t0) == .stale, "multiroom: the same manifest twice is ignored")
        if case .rejected = ana.hear(tamper(m2), now: t0) { check(true, "multiroom: tampered manifest rejected") } else { check(false, "multiroom: tampered manifest rejected") }
        // A stranger signs a manifest for the same room with their own admin key.
        let stranger = DeviceIdentity.generate()
        var fake = admin.room.gov!.manifest!
        fake.seq = 99
        fake.adminKey = stranger.signKey
        fake.members = [RoomMember(device: "evil", name: "Evil", signKey: stranger.signKey, boxKey: stranger.boxKey, joinedAt: t0)]
        let fakeBlob = PasaSign.sign(fake, secret: stranger.signSecret, domain: RoomGovernor.manifestDomain)!
        if case .rejected = ana.hear(fakeBlob, now: t0) {} else { check(false, "multiroom: manifest with another admin key rejected") }
        // A member (not admin) signs a higher-seq manifest naming the real admin key.
        var mutiny = admin.room.gov!.manifest!
        mutiny.seq = 50
        mutiny.cap = 30
        let mutinyBlob = PasaSign.sign(mutiny, secret: ana.identity.signSecret, domain: RoomGovernor.manifestDomain)!
        var adminCopy = admin
        if case .rejected = adminCopy.hear(mutinyBlob, now: t0) {} else { check(false, "multiroom: a member cannot sign admin actions") }
        check(adminCopy.room.cap == RoomLimits.defaultCap, "multiroom: cap unchanged after a forged manifest")
        check(RoomGovernor.kick(admin.identity.signKey, room: &ana.room, identity: ana.identity, now: t0) == nil, "multiroom: a member cannot kick")
    }

    // Third member, then kick with key rotation.
    var ben = SimDevice(id: "iPhone 14", name: "Ben", room: base)
    ben.room.gov = RoomGov(pending: true)
    _ = ben.hear(admin.room.gov?.signed, now: t0)
    guard case .admitted(let m3) = RoomGovernor.admit(RoomGovernor.joinRequest(room: ben.room, identity: ben.identity, device: ben.id, name: ben.name, now: t0)!,
                                                      room: &admin.room, identity: admin.identity, now: t0) else {
        check(false, "multiroom: second joiner admitted"); return
    }
    _ = ben.hear(m3, now: t0)
    _ = ana.hear(m3, now: t0)
    check(ben.room.canSend && admin.room.memberCount == 3, "multiroom: 3 members")
    let beforeKick = ben.seal("before kick", now: t0)!
    let t1 = t0.addingTimeInterval(60)
    let kick = RoomGovernor.kick(ben.identity.signKey, room: &admin.room, identity: admin.identity, now: t1)
    check(kick != nil && admin.room.epoch == 2 && admin.room.memberCount == 2, "multiroom: kick removes the member and rotates to epoch 2")
    if case .applied(let change) = ana.hear(kick, now: t1) {
        check(change.rekeyed && !change.removed, "multiroom: remaining member gets the new key")
    } else { check(false, "multiroom: remaining member accepts the kick") }
    if case .applied(let change) = ben.hear(kick, now: t1) {
        check(change.removed, "multiroom: kicked device learns it was removed")
    } else { check(false, "multiroom: kicked device accepts the kick manifest") }
    check(ben.room.isRemoved && !ben.room.canSend && ben.room.contentKey == nil, "multiroom: kicked device cannot send")
    let afterKick = admin.seal("after kick", now: t1)!
    check(RoomEnvelope.open(afterKick, in: ana.room, now: t1)?.body == "after kick", "multiroom: remaining member reads the new epoch")
    check(RoomEnvelope.open(afterKick, in: ben.room, now: t1) == nil, "multiroom: kicked device cannot read the new epoch")
    check(ben.room.gov?.epochKeys["1"] != nil, "multiroom: (disclosed) the kicked device still holds the old key, so traffic from before the kick stays readable to it")
    check(RoomEnvelope.open(beforeKick, in: ana.room, now: t1.addingTimeInterval(30))?.body == "before kick", "multiroom: previous epoch accepted during the grace period")
    check(RoomEnvelope.open(beforeKick, in: ana.room, now: t1.addingTimeInterval(RoomLimits.previousEpochGrace + 5)) == nil, "multiroom: previous epoch refused after the grace period")
    let rejoin = RoomGovernor.joinRequest(room: ben.room, identity: ben.identity, device: ben.id, name: ben.name, now: t1)!
    check(RoomGovernor.admit(rejoin, room: &admin.room, identity: admin.identity, now: t1) == .refused("removed by an admin"), "multiroom: kicked key cannot rejoin with the passcode")
    check(!RoomGovernor.wantsAdmission(ben.room, identity: ben.identity), "multiroom: kicked device stops asking to join")
    check(RoomGovernor.kick(admin.identity.signKey, room: &admin.room, identity: admin.identity, now: t1) == nil, "multiroom: admin cannot kick itself")

    // Close and reopen.
    do {
        let t2 = t1.addingTimeInterval(10)
        let close = RoomGovernor.setClosed(true, room: &admin.room, identity: admin.identity, now: t2)
        check(close != nil && admin.room.isClosed, "multiroom: admin closes the room")
        if case .applied(let change) = ana.hear(close, now: t2) { check(change.closed == true, "multiroom: member sees the close") }
        check(!ana.room.canSend && ana.room.sendBlocker?.contains("closed") == true, "multiroom: closed room is read-only for members")
        var carl = SimDevice(id: "iPad", name: "Carl", room: base)
        carl.room.gov = RoomGov(pending: true)
        let carlReq = RoomGovernor.joinRequest(room: carl.room, identity: carl.identity, device: carl.id, name: carl.name, now: t2)!
        check(RoomGovernor.admit(carlReq, room: &admin.room, identity: admin.identity, now: t2) == .refused("room closed"), "multiroom: closed room refuses joins")
        check(RoomBeacon.make(for: admin.room, now: t2)?.decode(RoomBeacon.self)?.badge == "Closed", "multiroom: beacon shows Closed")
        check(RoomGovernor.setClosed(true, room: &admin.room, identity: admin.identity, now: t2) == nil, "multiroom: closing twice is a no-op")
        let reopen = RoomGovernor.setClosed(false, room: &admin.room, identity: admin.identity, now: t2)
        _ = ana.hear(reopen, now: t2)
        check(ana.room.canSend, "multiroom: reopened room is writable again")
    }

    // Member cap: clamp, Full beacon, join refused when full.
    do {
        let t3 = t1.addingTimeInterval(20)
        _ = RoomGovernor.setCap(1, room: &admin.room, identity: admin.identity, now: t3)
        check(admin.room.cap == RoomLimits.minCap, "multiroom: cap is at least 2")
        var carl = SimDevice(id: "iPad", name: "Carl", room: base)
        carl.room.gov = RoomGov(pending: true)
        _ = carl.hear(admin.room.gov?.signed, now: t3)
        check(carl.room.sendBlocker?.contains("full") == true, "multiroom: joiner of a full room is told it is full")
        check(!RoomGovernor.wantsAdmission(carl.room, identity: carl.identity), "multiroom: no join requests to a full room")
        let req = RoomGovernor.joinRequest(room: carl.room, identity: carl.identity, device: carl.id, name: carl.name, now: t3)!
        check(RoomGovernor.admit(req, room: &admin.room, identity: admin.identity, now: t3) == .refused("room full (2/2)"), "multiroom: join beyond the cap refused")
        check(RoomBeacon.make(for: admin.room, now: t3)?.decode(RoomBeacon.self)?.badge == "Full 2/2", "multiroom: beacon shows Full 2/2")
        _ = RoomGovernor.setCap(99, room: &admin.room, identity: admin.identity, now: t3)
        check(admin.room.cap == RoomLimits.maxCap, "multiroom: cap is at most 30")
        if case .admitted(let m) = RoomGovernor.admit(req, room: &admin.room, identity: admin.identity, now: t3) {
            _ = carl.hear(m, now: t3)
            check(carl.room.canSend && carl.room.contentKey == admin.room.contentKey, "multiroom: after raising the cap the joiner is admitted")
        } else { check(false, "multiroom: after raising the cap the joiner is admitted") }
        _ = RoomGovernor.setCap(RoomLimits.defaultCap, room: &admin.room, identity: admin.identity, now: t3)

        // Co-admin: only the creator promotes; a co-admin can admit and kick, not promote.
        let promote = RoomGovernor.setCoAdmin(ana.identity.signKey, on: true, room: &admin.room, identity: admin.identity, now: t3)
        _ = ana.hear(admin.room.gov?.signed, now: t3)
        check(promote != nil && RoomGovernor.isAdmin(ana.room, identity: ana.identity) && !RoomGovernor.isCreatorAdmin(ana.room), "multiroom: co-admin promoted")
        check(RoomGovernor.setCoAdmin(carl.identity.signKey, on: true, room: &ana.room, identity: ana.identity, now: t3) == nil, "multiroom: a co-admin cannot promote")
        var dan = SimDevice(id: "iPhone SE", name: "Dan", room: base)
        dan.room.gov = RoomGov(pending: true)
        _ = dan.hear(ana.room.gov?.signed, now: t3)
        let danReq = RoomGovernor.joinRequest(room: dan.room, identity: dan.identity, device: dan.id, name: dan.name, now: t3)!
        if case .admitted(let m) = RoomGovernor.admit(danReq, room: &ana.room, identity: ana.identity, now: t3) {
            check(applied(admin.hear(m, now: t3)), "multiroom: admin accepts a co-admin's manifest")
            _ = dan.hear(m, now: t3)
            check(dan.room.canSend, "multiroom: co-admin admitted a joiner while the creator was away")
        } else { check(false, "multiroom: co-admin admits") }
    }

    // Beacons: sign, verify, tamper, expiry, conflict, hidden rooms.
    do {
        let registry = BeaconRegistry()
        let blob = RoomBeacon.make(for: admin.room, now: t0)!
        let b = blob.decode(RoomBeacon.self)!
        check(b.label == "GROUP-1" && b.passcode && b.adminName == "Teacher" && b.proto == RoomBeacon.proto, "multiroom: beacon carries label, passcode flag, admin name, version")
        let text = String(decoding: blob.body, as: UTF8.self)
        check(!text.contains(RoomCrypto.base64url(admin.room.key)) && !text.contains("mangga") &&
              !text.contains(RoomCrypto.base64url(admin.room.contentKey!)), "multiroom: beacon never contains a key or the passcode")
        check(registry.ingest(blob, now: t0), "multiroom: valid beacon accepted")
        check(registry.nearby(now: t0.addingTimeInterval(30)).count == 1, "multiroom: beacon listed while fresh")
        check(registry.nearby(now: t0.addingTimeInterval(46)).isEmpty, "multiroom: beacon expires after 45 s")
        let fresh = BeaconRegistry()
        check(!fresh.ingest(tamper(blob), now: t0), "multiroom: tampered beacon rejected")
        var resigned = blob
        resigned = PasaSign.sign(b, secret: DeviceIdentity.generate().signSecret, domain: BeaconRegistry.domain)!
        check(!fresh.ingest(resigned, now: t0), "multiroom: beacon signed by a key other than its admin key rejected")
        var impostor = b
        let evil = DeviceIdentity.generate()
        impostor.adminKey = evil.signKey
        impostor.members = 1
        check(fresh.ingest(blob, now: t0), "multiroom: real beacon heard first")
        check(!fresh.ingest(PasaSign.sign(impostor, secret: evil.signSecret, domain: BeaconRegistry.domain)!, now: t0), "multiroom: second admin key for the same room not taken")
        check(fresh.nearby(now: t0).first?.conflict == true && fresh.nearby(now: t0).first?.beacon.adminKey == b.adminKey, "multiroom: clash flagged, first admin kept")
        var older = b
        older.seq = 1
        check(!fresh.ingest(PasaSign.sign(older, secret: admin.room.gov!.adminSecret!, domain: BeaconRegistry.domain)!, now: t0), "multiroom: older beacon ignored")
        _ = RoomGovernor.setListed(false, room: &admin.room, identity: admin.identity, now: t0.addingTimeInterval(100))
        check(RoomBeacon.make(for: admin.room) == nil, "multiroom: Hidden rooms send no beacon")
        _ = RoomGovernor.setListed(true, room: &admin.room, identity: admin.identity, now: t0.addingTimeInterval(101))
        check(RoomBeacon.make(for: ana.room) == nil, "multiroom: only the admin key holder sends beacons")
        // Wrong passcode check against a beacon tag.
        let typo = Room.fromPasscode(name: "GROUP-1", passcode: "mangga hinog 43", creator: "", rounds: fastRounds)!
        check(typo.id != b.room && ana.room.id == b.room, "multiroom: Nearby join can tell a wrong passcode from the beacon tag")
        // Beacon as a mesh message: clear, short ttl.
        let msg = MeshMessage(origin: "Mac", kind: .beacon, body: PasaJSON.string(blob)!, ttl: BeaconRegistry.ttl)
        let decoded = try! MeshCodec.decode(try! MeshCodec.encode(msg))
        check(decoded.kind == .beacon && decoded.ttl == 3 && PasaJSON.value(SignedBlob.self, from: decoded.body)?.isValid == true, "multiroom: beacon survives the wire")
    }

    // AI Mac status: awake, asleep, offline, not serving, pinned key.
    do {
        let mac = DeviceIdentity.generate()
        let tracker = AIStatusTracker()
        let awake = AIStatus(device: "Mac", state: .awake, model: "qwen3:8b", queue: 0, rooms: ["r1", "r2"], at: t0)
        check(tracker.ingest(AIStatusTracker.make(awake, identity: mac)!, now: t0) == .woke("Mac"), "multiroom: first awake status counts as a wake")
        check(tracker.availability(room: "r1", now: t0) == .awake, "multiroom: room served -> Awake")
        check(tracker.availability(room: "r9", now: t0) == .notServing, "multiroom: room not served -> Not in this room")
        check(tracker.availability(room: "r1", now: t0.addingTimeInterval(36)) == .offline, "multiroom: silent for 35 s -> Offline")
        var asleep = awake
        asleep.state = .asleep
        asleep.at = t0.addingTimeInterval(40)
        check(tracker.ingest(AIStatusTracker.make(asleep, identity: mac)!, now: t0.addingTimeInterval(40)) == .slept("Mac"), "multiroom: sleep notice")
        check(tracker.availability(room: "r1", now: t0.addingTimeInterval(4000)) == .asleep, "multiroom: Asleep sticks until the Mac is heard again")
        let impostor = DeviceIdentity.generate()
        var fake = awake
        fake.at = t0.addingTimeInterval(50)
        check(tracker.ingest(AIStatusTracker.make(fake, identity: impostor)!, now: t0.addingTimeInterval(50)) == nil &&
              tracker.availability(room: "r1", now: t0.addingTimeInterval(50)) == .asleep, "multiroom: status from another key for the same Mac ignored")
        var back = awake
        back.at = t0.addingTimeInterval(5000)
        check(tracker.ingest(AIStatusTracker.make(back, identity: mac)!, now: t0.addingTimeInterval(5000)) == .woke("Mac") &&
              tracker.wokeAt == t0.addingTimeInterval(5000), "multiroom: wake is detected and timed")
    }

    // Fair queue across rooms.
    do {
        let q = FairAskQueue<String>()
        var ids: [String: UUID] = [:]
        for i in 1...5 { let id = UUID(); ids["A\(i)"] = id; _ = q.enqueue(room: "A", askID: id, payload: "A\(i)", now: t0) }
        for name in ["B1", "C1", "B2"] { let id = UUID(); ids[name] = id; _ = q.enqueue(room: String(name.prefix(1)), askID: id, payload: name, now: t0) }
        var served: [String] = []
        while let job = q.next() { served.append(job.payload); q.finish(job.askID, answerID: UUID(), now: t0) }
        check(served == ["A1", "B1", "C1", "A2", "B2", "A3", "A4", "A5"], "multiroom: rooms take turns (round robin), FIFO inside a room")
        check(q.enqueue(room: "A", askID: ids["A1"]!, payload: "again", now: t0) == .alreadyAnswered(q.ledger[ids["A1"]!]?.answerID), "multiroom: an answered ask is never answered twice")
        let dup = UUID()
        _ = q.enqueue(room: "B", askID: dup, payload: "x", now: t0)
        check(q.enqueue(room: "B", askID: dup, payload: "x", now: t0) == .duplicate, "multiroom: a queued ask is not queued twice")
        let busy = FairAskQueue<Int>()
        for i in 0..<FairAskQueue<Int>.perRoomLimit { _ = busy.enqueue(room: "loud", askID: UUID(), payload: i, now: t0) }
        check(busy.enqueue(room: "loud", askID: UUID(), payload: 99, now: t0) == .roomFull, "multiroom: one room holds at most 20 waiting asks")
        if case .queued = busy.enqueue(room: "quiet", askID: UUID(), payload: 1, now: t0) {} else { check(false, "multiroom: other rooms still get in") }
        _ = busy.next()
        busy.finish(busy.inFlight!.askID, answerID: nil)
        check(busy.next()?.room == "quiet", "multiroom: a quiet room is served right after one loud ask")
        check(busy.next() == nil, "multiroom: one model call at a time")
    }

    // Sleep and wake: queue pauses, cut-off call is retried, phone backlog replays once.
    do {
        let q = FairAskQueue<String>()
        let first = UUID()
        _ = q.enqueue(room: "A", askID: first, payload: "q1", now: t0)
        let job = q.next()!
        q.willSleep()
        check(q.next() == nil, "multiroom: nothing is handed out while the Mac sleeps")
        check(q.wasCutBySleep(job), "multiroom: a call that straddled sleep is detected")
        q.requeueInFlight()
        q.didWake()
        check(q.next()?.askID == first, "multiroom: the cut-off ask is answered after wake")
        q.finish(first, answerID: UUID(), now: t0)

        // Phone backlog.
        var book = PendingAskBook()
        let ask = MeshMessage(origin: "iPhone 12", destination: .role("ai"), kind: .ask, body: "can I visit at 6 PM?", createdAt: t0, v: 2)
        book.add(ask, room: "A", now: t0)
        check(book.due(room: "A", aiAwake: false, wokeAt: nil, now: t0.addingTimeInterval(600)).isEmpty, "multiroom: no resend while the AI Mac is asleep")
        let woke = t0.addingTimeInterval(700)
        let due = book.due(room: "A", aiAwake: true, wokeAt: woke, now: woke)
        check(due.count == 1, "multiroom: backlog resent when the Mac wakes")
        let retry = PendingAskBook.retry(of: due[0].ask, hops: ["iPhone 12"], now: woke)
        check(retry.id != ask.id && retry.retryOf == ask.id && retry.askKey == ask.id, "multiroom: resend uses a new packet id and points at the original")
        book.markSent(ask.id, now: woke)
        check(book.due(room: "A", aiAwake: true, wokeAt: woke, now: woke.addingTimeInterval(10)).isEmpty, "multiroom: not resent again right away")
        check(book.due(room: "B", aiAwake: true, wokeAt: woke, now: woke).isEmpty, "multiroom: only the room's own asks are resent")

        // Mac side: original arrives late too; only one answer.
        let mac = FairAskQueue<MeshMessage>()
        check(mac.enqueue(room: "A", askID: retry.askKey, payload: retry, now: woke) == .queued(position: 1), "multiroom: resent ask queued")
        check(mac.enqueue(room: "A", askID: ask.askKey, payload: ask, now: woke) == .duplicate, "multiroom: original and resend are one ask")
        let answerID = UUID()
        let j = mac.next()!
        mac.finish(j.askID, answerID: answerID, now: woke)
        let again = PendingAskBook.retry(of: retry, hops: ["iPhone 12"], now: woke.addingTimeInterval(95))
        check(again.retryOf == ask.id, "multiroom: a resend of a resend still points at the original")
        check(mac.enqueue(room: "A", askID: again.askKey, payload: again, now: woke) == .alreadyAnswered(answerID), "multiroom: after wake a repeat gets the stored answer, not a second one")
        book.resolve(ask.id)
        check(book.items.isEmpty, "multiroom: answer clears the backlog")

        // Ledger survives a restart.
        let saved = mac.exportLedger()
        let restarted = FairAskQueue<MeshMessage>()
        restarted.importLedger(saved, now: woke)
        check(restarted.enqueue(room: "A", askID: ask.id, payload: ask, now: woke) == .alreadyAnswered(answerID), "multiroom: answered ledger survives an app restart")
        restarted.pruneLedger(now: woke.addingTimeInterval(86_401))
        check(restarted.ledger.isEmpty, "multiroom: ledger forgets after 24 h")
        var old = PendingAskBook()
        old.add(ask, room: "A", now: t0)
        old.prune(now: t0.addingTimeInterval(86_401))
        check(old.items.isEmpty, "multiroom: unanswered asks are dropped after 24 h")
        // Codable round trip (persisted with the timeline).
        let tl = PersistedTimeline(entries: [], outbox: [])
        var withAsks = tl
        withAsks.pendingAsks = book.items + [PendingAsk(ask: ask, room: "A", firstSentAt: t0, lastSentAt: t0, attempts: 1)]
        let data = try! JSONEncoder().encode(withAsks)
        check((try? JSONDecoder().decode(PersistedTimeline.self, from: data))?.pendingAsks?.count == 1, "multiroom: pending asks persist with the timeline")
        let legacy = try! JSONEncoder().encode(tl)
        check((try? JSONDecoder().decode(PersistedTimeline.self, from: legacy)) != nil, "multiroom: timelines from before still load")
    }

    // Migration of rooms from before admin keys.
    do {
        let oldRoom = Room.fromPasscode(name: "BOHOL-7", passcode: "tubig sa bohol 77", creator: "iPhone 7597", now: t0, rounds: fastRounds)!
        var creator = SimDevice(id: "iPhone 7597", name: "Kyle", room: oldRoom)
        var member = SimDevice(id: "Mac", name: "Site Office", room: oldRoom)
        member.room.creator = ""
        check(RoomGovernor.migrate(&member.room, selfID: member.id, identity: member.identity, name: member.name) == nil, "multiroom: only the creator device migrates")
        var def = Room.makeDefault()
        check(RoomGovernor.migrate(&def, selfID: "x", identity: member.identity, name: "x") == nil, "multiroom: Default room has no admin")
        let preChat = member.seal("old style", now: t0)!
        let mig = RoomGovernor.migrate(&creator.room, selfID: creator.id, identity: creator.identity, name: creator.name, now: t0)
        check(mig != nil && creator.room.epoch == 0 && !creator.room.isListed, "multiroom: migrated room keeps epoch 0 and stays Hidden")
        check(RoomGovernor.migrate(&creator.room, selfID: creator.id, identity: creator.identity, name: creator.name, now: t0) == nil, "multiroom: migration runs once")
        check(RoomEnvelope.open(preChat, in: creator.room, now: t0)?.body == "old style", "multiroom: existing members keep talking after migration")
        _ = member.hear(mig, now: t0)
        check(member.room.isPending && member.room.canSend && RoomGovernor.wantsAdmission(member.room, identity: member.identity),
              "multiroom: other members pin the admin, keep sending at epoch 0 and register")
        if case .admitted(let m) = RoomGovernor.admit(RoomGovernor.joinRequest(room: member.room, identity: member.identity, device: member.id, name: member.name, now: t0)!,
                                                      room: &creator.room, identity: creator.identity, now: t0) {
            _ = member.hear(m, now: t0)
            check(!member.room.isPending && creator.room.memberCount == 2, "multiroom: migrated member on the roster")
        } else { check(false, "multiroom: migrated member admitted") }
        // First kick on a migrated room moves it off the passcode key.
        var stranger = SimDevice(id: "x", name: "X", room: oldRoom)
        stranger.room.creator = ""
        let k = RoomGovernor.kick(member.identity.signKey, room: &creator.room, identity: creator.identity, now: t0)
        check(k != nil && creator.room.epoch == 1, "multiroom: first kick rotates a migrated room to a random key")
        check(RoomEnvelope.open(creator.seal("private now", now: t0)!, in: stranger.room, now: t0) == nil, "multiroom: passcode holders cannot read after the rotation")

        // RoomStore keeps governance across restarts.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pasa-rooms-\(UUID().uuidString)")
        let store = RoomStore(baseURL: dir, now: t0)
        store.join(creator.room)
        let reloaded = RoomStore(baseURL: dir, now: t0)
        check(reloaded.active.gov == creator.room.gov && reloaded.active.epoch == 1, "multiroom: admin key, manifest and epoch keys survive a restart")
        var qrCopy = creator.room
        qrCopy.gov = RoomGov(adminKey: DeviceIdentity.generate().signKey, pending: true)
        reloaded.join(qrCopy)
        check(reloaded.active.gov?.adminKey == creator.room.gov?.adminKey, "multiroom: joining again never replaces a pinned admin key")
        try? FileManager.default.removeItem(at: dir)
    }

    // Room control wire format.
    do {
        let c = RoomControl(type: .want, haveSeq: 4)
        check(RoomControl.decode(c.encoded()!) == c, "multiroom: room control round trip")
        let m = MeshMessage(origin: "a", kind: .ask, body: "x", v: 2)
        var r = m
        r.retryOf = UUID()
        check((try? MeshCodec.decode(MeshCodec.encode(r)))?.retryOf == r.retryOf, "multiroom: retryOf survives the wire")
    }
}

/// Multi-room assistant: "more" text is kept per room.
@MainActor
func runMultiRoomAssistantTests() async {
    let memA = OrgMemory(fileURL: nil, admins: ["Mac"])
    let memB = OrgMemory(fileURL: nil, admins: ["Mac"])
    _ = memA.upsertRule(title: "Room A rule", body: "A only", by: "Mac")
    _ = memB.upsertRule(title: "Room B rule", body: "B only", by: "Mac")
    let brain = ExecutiveAssistant(memory: memA, llm: FakeLLM([]), selfName: "Mac")
    brain.serve(room: "A", memory: memA, clearedAt: nil)
    check(brain.memory.rules.map(\.title) == ["Room A rule"], "multiroom assistant: grounds on room A")
    brain.serve(room: "B", memory: memB, clearedAt: nil)
    check(brain.memory.rules.map(\.title) == ["Room B rule"], "multiroom assistant: grounds on room B")
    check(brain.roomKey == "B", "multiroom assistant: knows which room it answers")
}
