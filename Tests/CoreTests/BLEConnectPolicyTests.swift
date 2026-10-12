// BLEConnectPolicyTests.swift: connection cap, signal floor, strongest first, timeouts, backoff,
// Android status 133 quick retries, and a peer that changes radio address (BLEPeerBook).
import Foundation

func runBLEConnectPolicyTests() {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    // Cap and one-at-a-time.
    var p = BLEConnectPolicy(config: .init(maxLinks: 3, maxPending: 1))
    for (i, r) in [-60, -70, -50, -80].enumerated() { p.discovered("d\(i)", rssi: r, now: t0) }
    check(p.next(linked: 0, now: t0) == ["d2"], "ble connect: strongest signal first, one connect at a time")
    check(p.next(linked: 0, now: t0).isEmpty, "ble connect: no second connect while one is pending")
    p.connected("d2")
    check(p.next(linked: 1, now: t0) == ["d0"], "ble connect: next strongest after the first links")
    p.connected("d0")
    check(p.next(linked: 2, now: t0) == ["d1"], "ble connect: third link allowed under a cap of 3")
    p.connected("d1")
    check(p.next(linked: 3, now: t0).isEmpty, "ble connect: cap reached, no more connects")
    check(BLEConnectPolicy.Config.phone.maxLinks == 7 && BLEConnectPolicy.Config.hub.maxLinks == 12 && BLEConnectPolicy.Config.androidPhone.maxPending == 1,
          "ble connect: phones 7 links, AI Mac hub 12, Android one connect at a time")
    check(p.next(linked: 4, now: t0).isEmpty, "ble connect: links others opened to us count against the cap")

    // Signal floor, with more room for a device verified before.
    var f = BLEConnectPolicy()
    check(!f.discovered("weak", rssi: -92, now: t0), "ble connect: a device below -88 dBm is not worth a link")
    check(f.discovered("ok", rssi: -85, now: t0), "ble connect: -85 dBm is accepted")
    check(f.discovered("unknown", rssi: 127, now: t0), "ble connect: unknown signal (127) is let through")
    f.verified("weak")
    check(f.discovered("weak", rssi: -92, now: t0), "ble connect: a device verified this session may link down to -95 dBm")
    check(!f.discovered("weak2", rssi: -99, now: t0), "ble connect: below -95 dBm never")

    // Timeouts and backoff.
    var b = BLEConnectPolicy(config: .init(maxPending: 1, connectTimeout: 10))
    b.discovered("x", rssi: -60, now: t0)
    _ = b.next(linked: 0, now: t0)
    check(b.timedOut(now: t0.addingTimeInterval(5)).isEmpty, "ble connect: a connect under 10 s is not timed out")
    check(b.timedOut(now: t0.addingTimeInterval(10)) == ["x"], "ble connect: a connect past 10 s times out")
    check(b.backingOff("x", now: t0.addingTimeInterval(11)), "ble connect: a timed-out device backs off")
    check(!b.discovered("x", rssi: -60, now: t0.addingTimeInterval(11)), "ble connect: scan results during backoff are ignored")
    check(b.discovered("x", rssi: -60, now: t0.addingTimeInterval(13)), "ble connect: after 2 s backoff it may be tried again")
    let waits = (0..<6).map { _ in b.failed("y", .other, now: t0) }
    check(waits == [2, 4, 8, 16, 32, 60], "ble connect: backoff doubles from 2 s and stops at 60 s")

    // Android status 133: three quick retries, then normal backoff.
    var g = BLEConnectPolicy(config: .androidPhone)
    let q = (0..<5).map { _ in g.failed("pixel", .gattError133, now: t0) }
    check(q == [0.5, 1, 2, 2, 4], "ble connect: status 133 retries at 0.5, 1, 2 s, then backs off")
    g.connected("pixel")
    check(g.failed("pixel", .gattError133, now: t0) == 0.5, "ble connect: a successful link resets the retries")

    // Excluded (linked or tie-break dropped) devices are not reconnected.
    var e = BLEConnectPolicy()
    e.exclude("dup")
    check(!e.discovered("dup", rssi: -40, now: t0), "ble connect: a device dropped by the tie-break is not reconnected")
    e.include("dup")
    check(e.discovered("dup", rssi: -40, now: t0), "ble connect: it may come back once the other link closes")
    var s = BLEConnectPolicy()
    s.discovered("old", rssi: -60, now: t0)
    check(s.next(linked: 0, now: t0.addingTimeInterval(31)).isEmpty, "ble connect: a device not heard for 30 s is forgotten")

    // Same key on a new radio address: the newer link replaces the older one.
    func id(_ seed: UInt8) -> DeviceIdentity {
        DeviceIdentity(signSecret: Data((0..<32).map { UInt8(truncatingIfNeeded: Int($0) * 5 + Int(seed)) }), boxSecret: Data(repeating: seed, count: 32))
    }
    let me = id(40), phone = id(50)
    var book = BLEPeerBook(identity: me)
    func link(_ linkID: String) -> BLEPeerBook.ProofResult {
        let ch = book.opened(linkID, role: .central)
        var other = BLEPeerBook(identity: phone)
        let och = other.opened("o", role: .peripheral)
        guard case .sendProof = book.received(hello: BLEHello.make(identity: phone, name: "iPhone 12", nonce: och)!, on: linkID),
              case .sendProof(let pr) = other.received(hello: BLEHello.make(identity: me, name: "Pixel-A1", nonce: ch)!, on: "o") else { return .rejected("setup") }
        return book.received(proof: pr, on: linkID)
    }
    _ = link("c-AA:01")
    if case .verified(_, _, let newPeer, _, let replaced) = link("c-BB:02") {
        check(replaced == "c-AA:01" && !newPeer, "ble identity: an iPhone on a new MAC address is the same peer; the old link is replaced")
    } else { check(false, "ble identity: an iPhone on a new MAC address is the same peer; the old link is replaced") }
    check(book.linkIDs(forName: "iPhone 12") == ["c-BB:02"], "ble identity: one link per key after a MAC change")
}
