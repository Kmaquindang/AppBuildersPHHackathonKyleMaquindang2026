// JoinCodeTests.swift: "Create your room" with a short code and a QR join link (owner, Oct 9, 2026,
// 10:17 PM PHT): code alphabet, link build and parse, expiry, code proofs, approval, rotation.

import Foundation

func runJoinCodeTests() {
    // Alphabet: no 0, O, 1, I.
    check(!JoinCode.alphabet.contains("0") && !JoinCode.alphabet.contains("O") && !JoinCode.alphabet.contains("1") && !JoinCode.alphabet.contains("I"),
          "code: alphabet has no 0 O 1 I")
    check(JoinCode.alphabet.count == 32 && Set(JoinCode.alphabet).count == 32, "code: 32 distinct symbols")
    var seen = Set<String>()
    for _ in 0..<200 {
        let c = JoinCode.generate()
        seen.insert(c)
        if !(c.count == 9 && c[c.index(c.startIndex, offsetBy: 4)] == "-" && JoinCode.isValid(c)) { check(false, "code: generated format \(c)"); break }
        if c.contains(where: { "0O1I".contains($0) }) { check(false, "code: generated code avoids 0 O 1 I: \(c)"); break }
    }
    check(seen.count > 190, "code: generated codes vary")
    check(JoinCode.normalize(" k7qm 3xrf ") == "K7QM3XRF" && JoinCode.normalize("K7QM-3XRF") == "K7QM3XRF", "code: typing is forgiving (case, spaces, dash)")
    check(JoinCode.normalize("K7QM-3XR0") == nil && JoinCode.normalize("KIQM-3XRF") == nil && JoinCode.normalize("K7QM3XR") == nil, "code: 0, I and wrong length are rejected")

    // Link build and parse.
    let exp = Date(timeIntervalSince1970: 1_791_600_000)
    let link = JoinLink(room: "bohol 7", code: "k7qm3xrf", expiresAt: exp)
    check(link.url == "libre://join?room=BOHOL-7&code=K7QM-3XRF&v=1&exp=1791600000", "link: build \(link.url)")
    check((try? JoinLink.parse(link.url).get()) == link, "link: round trip")
    check((try? JoinLink.parse("pasa://join?room=BOHOL-7&code=K7QM-3XRF&v=1&exp=1791600000").get()) == link, "link: old pasa:// links still parse")
    check(JoinLink.roomOnly("pasa://join?room=BOHOL-7&v=1") == "BOHOL-7" && JoinLink.roomOnly("libre://join?room=BOHOL-7&v=1") == "BOHOL-7", "link: room-only links in both schemes")
    check((try? JoinLink.parse("pasa://join?room=BOHOL-7&code=K7QM-3XRF&v=1").get())?.expiresAt == nil, "link: expiry is optional")
    check(JoinLink.parse("https://join?room=X&code=K7QM-3XRF&v=1") == .failure(.notPasa), "link: other schemes rejected")
    check(JoinLink.parse("pasa://join?room=X&code=K7QM-3XRF&v=2") == .failure(.unsupportedVersion), "link: unknown version rejected")
    check(JoinLink.parse("pasa://join?room=&code=K7QM-3XRF&v=1") == .failure(.badRoom), "link: empty room rejected")
    check(JoinLink.parse("pasa://join?room=default&code=K7QM-3XRF&v=1") == .failure(.badRoom), "link: Default is not a code room")
    check(JoinLink.parse("pasa://join?room=X&code=K0QM-3XRF&v=1") == .failure(.badCode), "link: bad code rejected")

    // Expiry.
    check(!link.isExpired(now: exp.addingTimeInterval(-1)) && link.isExpired(now: exp), "expiry: expired at the stamp")
    check(CodeExpiry.off.date(from: exp) == nil && CodeExpiry.hour.date(from: exp) == exp.addingTimeInterval(3600)
          && CodeExpiry.day.date(from: exp) == exp.addingTimeInterval(86400), "expiry: off, 1 hour, 1 day")
    check(link.expiryLine(now: exp.addingTimeInterval(-1800)) == "Code expires in 30 min" && link.expiryLine(now: exp) == "Code expired. Make a new code.", "expiry: share screen line")

    // Room identity: same name, same room, any code.
    let a = Room.fromCode(name: "Bohol 7", creator: "Mac")!, b = Room.fromCode(name: "BOHOL-7", creator: "")!
    check(a.id == b.id && a.usesCode && !a.usesPasscode, "code room: tag from the name only")
    check(Room.fromCode(name: "default", creator: "") == nil && Room.fromCode(name: "  ", creator: "") == nil, "code room: reserved and empty names")
    let passRoom = Room.fromPasscode(name: "BOHOL-7", passcode: "K7QM3XRF", creator: "", rounds: 10)!
    check(passRoom.id != a.id, "code room: never the same tag as a passcode room")

    // Admission with a code proof (low rounds for speed; the app uses 600,000).
    let t0 = Date(timeIntervalSince1970: 1_791_500_000)
    let adminID = DeviceIdentity.generate(), ana = DeviceIdentity.generate(), ben = DeviceIdentity.generate()
    let code1 = "K7QM-3XRF"
    let key1 = CodeRoom.codeKey(name: "BOHOL-7", code: code1, rounds: 10)!
    var adminRoom = Room.fromCode(name: "BOHOL-7", creator: "Mac")!
    let made = RoomGovernor.setUp(&adminRoom, identity: adminID, device: "Mac", name: "Teacher", now: t0, code: code1, codeKey: key1,
                                  codeExpiresAt: t0.addingTimeInterval(3600))
    check(made != nil && RoomGovernor.isAdmin(adminRoom, identity: adminID) && adminRoom.gov?.manifest?.role(of: adminID.signKey) == .creator,
          "code room: creator is the first admin in the signed manifest")
    check(adminRoom.gov?.joinCode == code1 && adminRoom.gov?.manifest?.codeEpoch == 1 && adminRoom.gov?.manifest?.codeCheck != nil, "code room: code stored on the creator, check in the manifest")

    func joiner(_ id: DeviceIdentity, code: String) -> Room {
        var r = Room.fromCode(name: "BOHOL-7", creator: "")!
        RoomGovernor.enterCode(CodeRoom.codeKey(name: "BOHOL-7", code: code, rounds: 10)!, room: &r, identity: id)
        return r
    }
    var anaRoom = joiner(ana, code: code1)
    // Joiner pins only an admin who knows the code.
    var wrong = joiner(ben, code: "ZZZZ-ZZZZ")
    if case .rejected(let why) = RoomGovernor.accept(adminRoom.gov!.signed!, into: &wrong, identity: ben, now: t0) {
        check(why.contains("code"), "code room: wrong code never pins the admin")
    } else { check(false, "code room: wrong code must not pin") }
    check(RoomGovernor.accept(adminRoom.gov!.signed!, into: &anaRoom, identity: ana, now: t0) != .rejected("the room code does not match"), "code room: right code pins the admin")
    let anaReq = RoomGovernor.joinRequest(room: anaRoom, identity: ana, device: "PHONE_ANA", name: "Ana", now: t0)!
    let benReq = RoomGovernor.joinRequest(room: wrong, identity: ben, device: "PHONE_BEN", name: "Ben", now: t0)!
    check(RoomGovernor.admit(benReq, room: &adminRoom, identity: adminID, now: t0) == .refused("wrong or expired room code"), "code room: wrong code refused")
    var noProof = Room.fromCode(name: "BOHOL-7", creator: "")!; noProof.gov = RoomGov(pending: true)
    let bare = RoomGovernor.joinRequest(room: noProof, identity: ben, device: "PHONE_BEN", name: "Ben", now: t0)!
    check(RoomGovernor.admit(bare, room: &adminRoom, identity: adminID, now: t0) == .refused("wrong or expired room code"), "code room: no proof refused")
    var late = adminRoom
    check(RoomGovernor.admit(anaReq, room: &late, identity: adminID, now: t0.addingTimeInterval(3601)) == .refused("wrong or expired room code"), "code room: expired code refused by the admin")
    if case .admitted(let m) = RoomGovernor.admit(anaReq, room: &adminRoom, identity: adminID, now: t0.addingTimeInterval(60)) {
        _ = RoomGovernor.accept(m, into: &anaRoom, identity: ana, now: t0.addingTimeInterval(60))
        check(anaRoom.canSend && !anaRoom.isPending, "code room: right code admitted and gets the content key")
    } else { check(false, "code room: right code admitted") }

    // Approval: vet says ok, nothing changes until the admin admits.
    let benRight = joiner(ben, code: code1)
    let benReq2 = RoomGovernor.joinRequest(room: benRight, identity: ben, device: "PHONE_BEN", name: "Ben", now: t0)!
    let approved = RoomGovernor.setApproval(true, room: &adminRoom, identity: adminID, now: t0.addingTimeInterval(61))
    check(approved != nil && adminRoom.gov?.manifest?.approval == true, "approval: toggle signed into the manifest")
    let seqBefore = adminRoom.gov?.seq
    if case .ok(let r) = RoomGovernor.vet(benReq2, room: adminRoom, identity: adminID, now: t0.addingTimeInterval(62)) {
        check(r.name == "Ben" && adminRoom.gov?.seq == seqBefore, "approval: vetting a valid request changes nothing")
    } else { check(false, "approval: valid request vets ok") }

    // Rotation: new code, old members out (must re-enter), admins stay, key rotates, old code dead.
    let epochBefore = adminRoom.epoch
    let code2 = "M8NP-4WQT"
    let key2 = CodeRoom.codeKey(name: "BOHOL-7", code: code2, rounds: 10)!
    let rotated = RoomGovernor.rotateCode(code2, codeKey: key2, expiresAt: nil, room: &adminRoom, identity: adminID, now: t0.addingTimeInterval(120))
    check(rotated != nil && adminRoom.gov?.joinCode == code2 && adminRoom.gov?.manifest?.codeEpoch == 2, "rotate: new code stored, epoch 2")
    check(adminRoom.gov?.manifest?.members.map(\.device) == ["Mac"] && adminRoom.epoch == epochBefore + 1, "rotate: only admins stay, content key rotates")
    if let rotated, case .applied(let change) = RoomGovernor.accept(rotated, into: &anaRoom, identity: ana, now: t0.addingTimeInterval(121)) {
        check(change.removed && change.codeChanged && !anaRoom.canSend, "rotate: old join must re-enter the code")
    } else { check(false, "rotate: member applies the new manifest") }
    check(RoomGovernor.admit(anaReq, room: &adminRoom, identity: adminID, now: t0.addingTimeInterval(122)) == .refused("wrong or expired room code"), "rotate: old code proof refused")
    RoomGovernor.enterCode(key2, room: &anaRoom, identity: ana)
    check(RoomGovernor.wantsAdmission(anaRoom, identity: ana), "rotate: entering the new code asks again")
    let anaReq2 = RoomGovernor.joinRequest(room: anaRoom, identity: ana, device: "PHONE_ANA", name: "Ana", now: t0)!
    if case .admitted = RoomGovernor.admit(anaReq2, room: &adminRoom, identity: adminID, now: t0.addingTimeInterval(130)) {
        check(true, "rotate: new code admits again")
    } else { check(false, "rotate: new code admits again") }
    var notCreator = anaRoom
    check(RoomGovernor.rotateCode(code1, codeKey: key1, expiresAt: nil, room: &notCreator, identity: ana) == nil, "rotate: only the creator can make a new code")
    let exp2 = t0.addingTimeInterval(86400)
    check(RoomGovernor.setCodeExpiry(exp2, room: &adminRoom, identity: adminID, now: t0.addingTimeInterval(140)) != nil && adminRoom.gov?.manifest?.codeExpiresAt == exp2, "expiry: changeable and signed")
}
