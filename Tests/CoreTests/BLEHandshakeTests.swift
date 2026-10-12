// BLEHandshakeTests.swift: signed Bluetooth hello, proof, link book (keys, tie-break, blocking).
// Synthetic devices only.
import Foundation

func runBLEHandshakeTests() {
    func id(_ seed: UInt8) -> DeviceIdentity {
        DeviceIdentity(signSecret: Data((0..<32).map { UInt8(truncatingIfNeeded: Int($0) * 7 + Int(seed)) }),
                       boxSecret: Data(repeating: seed, count: 32))
    }
    let a = id(11), b = id(22), c = id(33)
    let nonceA = Data(repeating: 0xA1, count: 16), nonceB = Data(repeating: 0xB2, count: 16)

    // Hello format and signature.
    let helloA = BLEHello.make(identity: a, name: "iPhone 12", nonce: nonceA)!
    let opened = BLEHello.open(helloA)
    check(opened?.name == "iPhone 12" && opened?.signKey == a.signKey && opened?.nonce == nonceA && opened?.isHub == false,
          "ble hello: fields survive a round trip")
    check(helloA.count == 51 + 9 + 64 && helloA[0] == 2, "ble hello: version 2 layout (51 header bytes + name + 64 signature)")
    var tampered = helloA; tampered[52] ^= 1
    check(BLEHello.open(tampered) == nil, "ble hello: a changed name byte breaks the signature")
    var swapped = helloA; swapped.replaceSubrange(1..<33, with: b.signKey)
    check(BLEHello.open(swapped) == nil, "ble hello: another key cannot take over a signed hello")
    check(BLEHello.make(identity: a, name: "", nonce: nonceA) == nil, "ble hello: empty name refused")
    check(BLEHello.make(identity: a, name: String(repeating: "x", count: 65), nonce: nonceA) == nil, "ble hello: name over 64 bytes refused")
    check(BLEHello.open(Data("iPhone 14".utf8)) == nil, "ble hello: an old unsigned name hello is refused")
    check(BLEHello.open(BLEHello.make(identity: c, name: "Site Office", nonce: nonceA, hub: true)!)?.isHub == true, "ble hello: hub flag survives")

    // Proof binds the fresh challenge and both keys.
    let hA = BLEHello.open(helloA)!
    let hB = BLEHello.open(BLEHello.make(identity: b, name: "iPhone 14", nonce: nonceB)!)!
    let proofB = BLEHello.proof(identity: b, peer: hA)!
    check(BLEHello.checkProof(proofB, peer: hB, myChallenge: nonceA, myKey: a.signKey), "ble proof: B signs A's challenge and A accepts")
    check(!BLEHello.checkProof(proofB, peer: hB, myChallenge: Data(repeating: 0, count: 16), myKey: a.signKey), "ble proof: a proof for another challenge (replay) fails")
    check(!BLEHello.checkProof(proofB, peer: hB, myChallenge: nonceA, myKey: c.signKey), "ble proof: a proof made for another device fails")

    // Full handshake in two books (one link each way), verified on both sides.
    var bookA = BLEPeerBook(identity: a), bookB = BLEPeerBook(identity: b)
    let chA = bookA.opened("c-1", role: .central, challenge: nonceA)
    let chB = bookB.opened("p-1", role: .peripheral, challenge: nonceB)
    let helloFromA = BLEHello.make(identity: a, name: "iPhone 12", nonce: chA)!
    let helloFromB = BLEHello.make(identity: b, name: "iPhone 14", nonce: chB)!
    guard case .sendProof(let pA) = bookA.received(hello: helloFromB, on: "c-1"),
          case .sendProof(let pB) = bookB.received(hello: helloFromA, on: "p-1") else { check(false, "ble book: hellos accepted"); return }
    check(!bookA.isVerified("c-1"), "ble book: a hello alone does not verify a link")
    if case .verified(let name, _, let newPeer, let drop, _) = bookA.received(proof: pB, on: "c-1") {
        check(name == "iPhone 14" && newPeer && drop == nil, "ble book: A verifies B by key, names it from the signed hello")
    } else { check(false, "ble book: A verifies B by key, names it from the signed hello") }
    if case .verified(let name, _, _, _, _) = bookB.received(proof: pA, on: "p-1") {
        check(name == "iPhone 12", "ble book: B verifies A")
    } else { check(false, "ble book: B verifies A") }
    check(bookA.linkedNames == ["iPhone 14"] && bookA.linkIDs(forName: "iPhone 14") == ["c-1"], "ble book: linked names come from verified links only")

    // Replay: C replays B's hello on a new link; C cannot sign A's new challenge.
    _ = bookA.opened("c-2", role: .central, challenge: Data(repeating: 0x33, count: 16))
    if case .rejected = bookA.received(hello: helloFromB, on: "c-2") {
        check(true, "ble book: a replayed hello of a linked key under the same name is held to the proof")
    } else {
        // Accepted as hello, but the proof must fail.
        let fake = BLEHello.proof(identity: c, peer: BLEHello.open(BLEHello.make(identity: a, name: "iPhone 12", nonce: Data(repeating: 0x33, count: 16))!)!)!
        if case .rejected = bookA.received(proof: fake, on: "c-2") { check(true, "ble book: a replayed hello of a linked key under the same name is held to the proof") }
        else { check(false, "ble book: a replayed hello of a linked key under the same name is held to the proof") }
    }
    check(bookA.linkIDs(forName: "iPhone 14") == ["c-1"], "ble book: replay attempt adds no link")

    // Name collision: C claims B's name with its own key while B is linked.
    _ = bookA.opened("c-3", role: .central)
    let spoof = BLEHello.make(identity: c, name: "iPhone 14", nonce: nonceB)!
    if case .rejected(let why) = bookA.received(hello: spoof, on: "c-3") {
        check(why.contains("another key"), "ble book: a second key claiming a linked name is refused")
    } else { check(false, "ble book: a second key claiming a linked name is refused") }

    // Tie-break by key: both sides hold a central and a peripheral link; only the greater key drops.
    func pair(_ me: DeviceIdentity, _ peer: DeviceIdentity) -> [String] {
        var book = BLEPeerBook(identity: me)
        var drops: [String] = []
        for (link, role) in [("c-x", BLEPeerBook.Role.central), ("p-x", .peripheral)] {
            let ch = book.opened(link, role: role)
            var peerBook = BLEPeerBook(identity: peer)
            let peerCh = peerBook.opened("other", role: role == .central ? .peripheral : .central)
            guard case .sendProof = book.received(hello: BLEHello.make(identity: peer, name: "peer", nonce: peerCh)!, on: link),
                  case .sendProof(let peerProof) = peerBook.received(hello: BLEHello.make(identity: me, name: "me", nonce: ch)!, on: "other") else { return ["fail"] }
            if case .verified(_, _, _, let d, _) = book.received(proof: peerProof, on: link), let d { drops.append(d) }
        }
        return drops
    }
    let greater = BLEHello.keyGreater(a.signKey, b.signKey) ? a : b
    let lesser = greater == a ? b : a
    check(pair(greater, lesser) == ["c-x"], "ble tie-break: the device with the greater key drops its own scanner link")
    check(pair(lesser, greater).isEmpty, "ble tie-break: the device with the smaller key keeps both")
    check(BLEHello.keyGreater(Data([2, 0]), Data([1, 255])) && !BLEHello.keyGreater(Data([1, 255]), Data([2, 0])), "ble tie-break: unsigned byte order")

    // Blocking follows the key.
    let toClose = bookA.setBlocked(["iPhone 14"])
    check(toClose.contains("c-1") && bookA.linkedNames.isEmpty, "ble block: blocking a name closes its link")
    let keyB = BLEHello.keyID(b.signKey)
    check(bookA.isBlocked(keyID: keyB, name: "Renamed phone"), "ble block: the same key under a new name stays blocked")
    _ = bookA.opened("c-9", role: .central)
    if case .rejected(let why) = bookA.received(hello: BLEHello.make(identity: b, name: "Renamed phone", nonce: nonceB)!, on: "c-9") {
        check(why == "blocked", "ble block: a blocked key's new hello is refused")
    } else { check(false, "ble block: a blocked key's new hello is refused") }

    // Close reporting.
    var bk = BLEPeerBook(identity: a)
    let ch = bk.opened("c-5", role: .central)
    var other = BLEPeerBook(identity: b)
    let och = other.opened("p-5", role: .peripheral)
    if case .sendProof = bk.received(hello: BLEHello.make(identity: b, name: "iPhone 14", nonce: och)!, on: "c-5"),
       case .sendProof(let pr) = other.received(hello: BLEHello.make(identity: a, name: "iPhone 12", nonce: ch)!, on: "p-5") {
        _ = bk.received(proof: pr, on: "c-5")
    }
    let gone = bk.closed("c-5")
    check(gone?.name == "iPhone 14" && gone?.stillLinked == false, "ble book: closing the last link reports the peer gone")
    check(bk.closed("never") == nil, "ble book: closing an unknown link is a no-op")
    // Data from an unverified link: the transport checks isVerified before delivering.
    _ = bk.opened("c-6", role: .central)
    check(!bk.isVerified("c-6") && bk.peer(on: "c-6") == nil, "ble book: an unverified link has no peer, so its data is dropped")
}
