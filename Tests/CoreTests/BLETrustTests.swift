// BLETrustTests.swift: trust on first use for Bluetooth device keys (issue #12). Same cases as
// the trust tests in BleHandshakeTest.kt. Synthetic devices only.
import Foundation

func runBLETrustTests() {
    func id(_ seed: UInt8) -> DeviceIdentity {
        DeviceIdentity(signSecret: Data((0..<32).map { UInt8(truncatingIfNeeded: Int($0) * 7 + Int(seed)) }),
                       boxSecret: Data(repeating: seed, count: 32))
    }
    let me = id(11), phone = id(22), impostor = id(33)
    /// Runs one link's hello and proof from `peer` (named `name`) into `book`. Returns the result.
    func link(_ book: inout BLEPeerBook, _ linkID: String, peer: DeviceIdentity, name: String) -> BLEPeerBook.ProofResult {
        let challenge = book.opened(linkID, role: .peripheral)
        guard case .sendProof = book.received(hello: BLEHello.make(identity: peer, name: name, nonce: Data(repeating: 7, count: 16))!, on: linkID) else {
            return .rejected("hello refused")
        }
        let theirs = BLEHello.open(BLEHello.make(identity: me, name: "Me", nonce: challenge)!)!
        return book.received(proof: BLEHello.proof(identity: peer, peer: theirs)!, on: linkID)
    }

    var book = BLEPeerBook(identity: me)
    if case .verified = link(&book, "p-1", peer: phone, name: "iPhone 14") {} else { check(false, "ble trust: first link verifies") }
    check(book.trust.check(name: "iPhone 14", keyID: BLEHello.keyID(phone.signKey)) == .trusted, "ble trust: first key remembered")
    _ = book.closed("p-1")

    // The same device comes back later: accepted.
    if case .verified = link(&book, "p-2", peer: phone, name: "iPhone 14") {} else { check(false, "ble trust: same key accepted again") }
    _ = book.closed("p-2")

    // Another key with that name, even with nobody linked: refused and flagged.
    let r = book.received(hello: BLEHello.make(identity: impostor, name: "iPhone 14", nonce: Data(repeating: 9, count: 16))!,
                          on: { _ = book.opened("p-3", role: .peripheral); return "p-3" }())
    check(r == .rejected("key changed for iPhone 14"), "ble trust: changed key refused while the old one is gone")
    check(book.trust.conflicts["iPhone 14"] == BLEHello.keyID(impostor.signKey), "ble trust: conflict listed for the connection sheet")
    _ = book.closed("p-3")

    // The person trusts the new key: the next link is accepted and remembered.
    book.trust.reset(name: "iPhone 14")
    if case .verified = link(&book, "p-4", peer: impostor, name: "iPhone 14") {} else { check(false, "ble trust: new key accepted after reset") }
    check(book.trust.conflicts.isEmpty && book.trust.check(name: "iPhone 14", keyID: BLEHello.keyID(impostor.signKey)) == .trusted,
          "ble trust: reset clears the conflict and trusts the new key")

    // Saved and loaded (ble-trust.json).
    let data = try? JSONEncoder().encode(book.trust)
    let loaded = data.flatMap { try? JSONDecoder().decode(BLETrustStore.self, from: $0) }
    check(loaded == book.trust, "ble trust: store survives a save and load")
    var fresh = BLEPeerBook(identity: me)
    fresh.trust = loaded ?? BLETrustStore()
    _ = fresh.opened("p-5", role: .peripheral)
    check(fresh.received(hello: BLEHello.make(identity: phone, name: "iPhone 14", nonce: Data(repeating: 1, count: 16))!, on: "p-5")
          == .rejected("key changed for iPhone 14"), "ble trust: a restart keeps refusing the old key")
    var store = BLETrustStore()
    check(store.flag(name: "X", keyID: "k2") && !store.flag(name: "X", keyID: "k2"), "ble trust: the same conflict is news once")
}
