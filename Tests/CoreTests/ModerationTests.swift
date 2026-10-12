// ModerationTests.swift: Town Square hide records (issue #9). Same cases as ModerationTest.kt.
import Foundation

func runModerationTests() {
    func id(_ seed: UInt8) -> DeviceIdentity {
        DeviceIdentity(signSecret: Data((0..<32).map { UInt8(truncatingIfNeeded: Int($0) * 5 + Int(seed)) }),
                       boxSecret: Data(repeating: seed, count: 32))
    }
    let mac = id(41), stranger = id(42), roomAdmin = id(43)
    let town = Room.makeDefault().id
    let msg = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let hide = ModerationState.make(message: msg, room: town, at: t0, identity: mac)!

    var phone = ModerationState()
    check(phone.apply(hide, room: town, adminKeys: []) == nil && !phone.isHidden(msg), "moderation: an untrusted Mac's hide is ignored")
    let strangerHide = ModerationState.make(message: msg, room: town, at: t0, identity: stranger)!
    phone.setTrusted(mac: mac.signKey, true)
    check(phone.apply(strangerHide, room: town, adminKeys: []) == nil, "moderation: another Mac's hide is ignored after trusting one")
    check(phone.apply(hide, room: town, adminKeys: []) == msg && phone.isHidden(msg), "moderation: the trusted Mac's hide applies")
    check(phone.apply(hide, room: town, adminKeys: []) == nil && phone.records.count == 1, "moderation: a repeated hide is not news")

    // A code room admin this phone joined is trusted without the opt-in.
    var other = ModerationState()
    let adminHide = ModerationState.make(message: msg, room: town, at: t0, identity: roomAdmin)!
    check(other.apply(adminHide, room: town, adminKeys: [roomAdmin.signKey]) == msg, "moderation: a joined room's admin key is trusted")

    // Wrong room, tampering and a different signing domain are refused.
    check(phone.accepts(ModerationState.make(message: UUID(), room: "a229470a9c620b6a00", at: t0, identity: mac)!, room: town, adminKeys: []) == nil,
          "moderation: a hide for another room is refused")
    var tampered = hide; tampered.body = (try? PasaJSON.encoder.encode(HideRecord(room: town, message: UUID(), at: t0))) ?? Data()
    check(phone.accepts(tampered, room: town, adminKeys: []) == nil, "moderation: a changed record breaks the signature")
    let beacon = mac.sign(hide.body, domain: AIStatusTracker.domain)!
    check(phone.accepts(beacon, room: town, adminKeys: []) == nil, "moderation: a blob signed for another purpose is refused")

    // The Mac's own hides apply on the Mac; turning trust off stops new hides.
    var macState = ModerationState()
    check(macState.apply(hide, room: town, adminKeys: [], ownKey: mac.signKey) == msg, "moderation: the Mac applies its own hide")
    phone.setTrusted(mac: mac.signKey, false)
    check(!phone.trusts(mac: mac.signKey) && phone.apply(ModerationState.make(message: UUID(), room: town, identity: mac)!, room: town, adminKeys: []) == nil,
          "moderation: no new hides after trust is turned off")

    // Saved and loaded.
    let saved = (try? JSONEncoder().encode(phone)).flatMap { try? JSONDecoder().decode(ModerationState.self, from: $0) }
    check(saved == phone && saved?.isHidden(msg) == true, "moderation: state survives a save and load")

    // Wire: the new kind round-trips and rides the urgent lane.
    let m = MeshMessage(origin: "Mac-1", kind: .moderation, body: PasaJSON.string(hide) ?? "")
    check((try? MeshCodec.decode(MeshCodec.encode(m)))?.kind == .moderation && BLELane.of(kind: .moderation, bytes: 400) == .urgent,
          "moderation wire: kind round-trips, urgent lane")
}
