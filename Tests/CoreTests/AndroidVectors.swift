// AndroidVectors.swift: cross-language test vectors for the Android app (android/).
// - `PasaCoreTests --vectors <path>` writes vectors made by this Swift code (key derivation,
//   seal and open, BLE framing, message JSON, signed manifests, key boxes). The Kotlin JVM tests
//   (android/app/src/test) assert the same bytes.
// - runAndroidInteropTests() reads what the Kotlin code produced
//   (android/app/src/test/resources/kotlin_vectors.json) and checks Swift accepts it: a join
//   request signed in Kotlin, a packet sealed in Kotlin, frames cut in Kotlin.
// Synthetic data only (PATIENT_A style placeholders, made-up room names and codes).

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ s: String) -> Data {
    var out = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return out
}
private func bytes(_ n: Int, _ seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

enum AndroidVectorFixtures {
    static let adminIdentity = DeviceIdentity(signSecret: bytes(32, 1), boxSecret: bytes(32, 2))
    static let joinerIdentity = DeviceIdentity(signSecret: bytes(32, 3), boxSecret: bytes(32, 4))
    static let t0 = Date(timeIntervalSince1970: 1_792_000_000.123)
    static let roomName = "Bohol 7"
    static let code = "K7QM-3XRF"
    static let passcode = "tide lamp 42"
}

func writeAndroidVectors(to path: String) {
    typealias F = AndroidVectorFixtures
    var v: [String: Any] = [:]

    // 1. Names and key derivation.
    v["cleanLabel"] = ["  bohol  7 ": Room.cleanLabel("  bohol  7 "), "Café-ñ x": Room.cleanLabel("Café-ñ x"), "a b c d e f g h i j k l m n o p": Room.cleanLabel("a b c d e f g h i j k l m n o p")]
    v["normalizedName"] = RoomPasscode.normalizedName(F.roomName)
    v["pbkdf2_rfc"] = hex(PBKDF2SHA256.deriveSwift(password: Data("passwd".utf8), salt: Data("salt".utf8), rounds: 1, length: 64))
    v["pbkdf2_4096"] = hex(PBKDF2SHA256.deriveSwift(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 4096, length: 32))
    v["passcodeKey"] = hex(RoomPasscode.deriveKey(name: F.roomName, passcode: " " + F.passcode + " "))
    let codeKey = CodeRoom.codeKey(name: F.roomName, code: "k7qm 3xrf")!
    v["codeKey"] = hex(codeKey)
    v["codeNormalized"] = JoinCode.normalize("k7qm 3xrf")
    let base = CodeRoom.baseKey(name: F.roomName)
    v["codeBaseKey"] = hex(base)
    v["defaultKey"] = hex(RoomCrypto.defaultKey)
    v["defaultTag"] = RoomCrypto.tag(for: RoomCrypto.defaultKey)
    v["codeRoomTag"] = RoomCrypto.tag(for: base)
    v["sealingKeyDefault"] = hex(RoomCrypto.sealingKey(RoomCrypto.defaultKey).withUnsafeBytes { Data($0) })

    // 2. ChaCha20-Poly1305 with a fixed nonce (the app uses random nonces; layout is nonce|ct|tag).
    let nonce = bytes(12, 9)
    let plain = Data("PATIENT_A synthetic hello".utf8)
    let aad = Data("2|00000000-0000-0000-0000-000000000001|tag|Pixel-A1|*".utf8)
    let box = try! ChaChaPoly.seal(plain, using: RoomCrypto.sealingKey(base), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
    v["fixedSeal"] = ["key": hex(base), "nonce": hex(nonce), "plain": hex(plain), "aad": hex(aad), "combined": hex(box.combined)]

    // 3. Message JSON shapes and a real sealed Town Square packet.
    let town = Room.makeDefault(now: F.t0)
    var chat = MeshMessage(id: UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8")!, origin: "iPhone 12", kind: .chat,
                           body: "Wi-Fi off test from PATIENT_A placeholder", createdAt: F.t0, senderName: "Ana", v: 2)
    chat.hops = ["iPhone 12"]
    v["chatJSON"] = String(decoding: try! MeshCodec.encode(chat), as: UTF8.self)
    var ask = MeshMessage(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, origin: "Pixel-A1", destination: .role("ai"),
                          kind: .ask, body: "what is the site rule", createdAt: F.t0, v: 2)
    ask.senderName = "Ben"
    v["askJSON"] = String(decoding: try! MeshCodec.encode(ask), as: UTF8.self)
    var answer = MeshMessage(id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!, origin: "MacBook Air", destination: .peer("Pixel-A1"),
                             kind: .answer, body: "Wear a hard hat on site.", createdAt: F.t0, replyTo: ask.id, replyPath: ["Pixel-A1", "MacBook Air"], v: 2)
    answer.rulesUsed = ["[Rule: Hard hats v2]"]
    answer.checked = ["Hard hats"]
    answer.docRefs = [DocRef(title: "Site safety", page: 2, version: 1, excerpt: "Hard hats at all times.")]
    answer.proof = AIProof(mac: "Site Office", model: "qwen3:8b", internet: .offline, tokensPerSecond: 16.5, latencyMs: 6470)
    answer.noRule = false
    v["answerJSON"] = String(decoding: try! MeshCodec.encode(answer), as: UTF8.self)
    let sealedTown = try! RoomEnvelope.seal(chat, in: town)
    v["townSealedJSON"] = String(decoding: try! MeshCodec.encode(sealedTown), as: UTF8.self)
    v["townAAD"] = String(decoding: RoomEnvelope.aad(sealedTown, room: town.id), as: UTF8.self)
    // Streamed answer piece (issue #2), sealed in Town Square.
    var piece = MeshMessage(id: UUID(uuidString: "33333333-4444-4555-8666-777777777777")!, origin: "MacBook Air", destination: .peer("Pixel-A1"),
                            kind: .answerPart, body: " a hard hat on site", createdAt: F.t0, replyTo: ask.id, replyPath: ["Pixel-A1", "MacBook Air"], v: 2)
    piece.part = 1
    v["answerPartSealedJSON"] = String(decoding: try! MeshCodec.encode(try! RoomEnvelope.seal(piece, in: town)), as: UTF8.self)

    // 4. BLE frames.
    var frames: [[String: Any]] = []
    for (n, mtu, id) in [(0, 182, UInt32(1)), (171, 182, 2), (172, 182, 3), (1000, 20, 0xDEADBEEF), (600, 512, 7)] {
        let data = bytes(n, 5)
        frames.append(["data": hex(data), "mtu": mtu, "id": Int(id), "frames": BLEChunker.frames(data, messageID: id, mtu: mtu)!.map(hex)])
    }
    v["frames"] = frames
    v["hello"] = hex(BLEFrame(type: .hello, messageID: 0, index: 0, count: 1, payload: Data("iPhone 14".utf8)).encoded())
    // 4b. Signed Bluetooth hello and proof (BLEHandshake.swift). CryptoKit signatures are not
    // deterministic, so Kotlin verifies these rather than comparing bytes.
    let helloNonce = bytes(16, 7)
    let swiftHello = BLEHello.make(identity: F.adminIdentity, name: "MacBook Air", nonce: helloNonce, hub: true)!
    v["signedHello"] = hex(swiftHello)
    v["adminSignKey"] = hex(F.adminIdentity.signKey)
    v["helloNonce"] = hex(helloNonce)
    // The Mac's proof over the joiner's challenge (joiner is the Kotlin side in the tests).
    let joinerNonce = bytes(16, 8)
    let joinerHello = BLEHello.open(BLEHello.make(identity: F.joinerIdentity, name: "Pixel-A1", nonce: joinerNonce)!)!
    v["joinerNonce"] = hex(joinerNonce)
    v["proofForJoiner"] = hex(BLEHello.proof(identity: F.adminIdentity, peer: joinerHello)!)
    v["keyGreaterAdminJoiner"] = BLEHello.keyGreater(F.adminIdentity.signKey, F.joinerIdentity.signKey)

    // 5. Code room governance: admin sets up, joiner asks, admin admits, then admin chats.
    var adminRoom = Room.fromCode(name: F.roomName, creator: "MacBook Air", now: F.t0)!
    _ = RoomGovernor.setUp(&adminRoom, identity: F.adminIdentity, device: "MacBook Air", name: "Kyle", now: F.t0,
                           code: F.code, codeKey: codeKey, codeExpiresAt: nil, approval: false)
    var joinerRoom = Room.fromCode(name: F.roomName, creator: "", now: F.t0)!
    RoomGovernor.enterCode(codeKey, room: &joinerRoom, identity: F.joinerIdentity)
    let request = RoomGovernor.joinRequest(room: joinerRoom, identity: F.joinerIdentity, device: "Pixel-A1", name: "Ben", now: F.t0)!
    v["joinerSignSecret"] = hex(F.joinerIdentity.signSecret)
    v["joinerBoxSecret"] = hex(F.joinerIdentity.boxSecret)
    v["joinerSignKey"] = hex(F.joinerIdentity.signKey)
    v["joinerBoxKey"] = hex(F.joinerIdentity.boxKey)
    v["joinProof"] = hex(CodeRoom.proof(codeKey: codeKey, room: joinerRoom.id, signKey: F.joinerIdentity.signKey))
    v["joinRequestBlob"] = String(decoding: try! PasaJSON.encoder.encode(request), as: UTF8.self)
    guard case .admitted(let manifest) = RoomGovernor.admit(request, room: &adminRoom, identity: F.adminIdentity, now: F.t0) else {
        print("vector: admit failed"); return
    }
    v["manifestBlob"] = String(decoding: try! PasaJSON.encoder.encode(manifest), as: UTF8.self)
    v["manifestEpoch"] = adminRoom.epoch
    v["epochKey"] = hex(adminRoom.contentKey!)
    v["adminKey"] = hex(adminRoom.gov!.adminKey!)
    let control = RoomControl(type: .manifest, blob: manifest).encoded()!
    let controlMsg = MeshMessage(id: UUID(uuidString: "33333333-4444-4555-8666-777777777777")!, origin: "MacBook Air", kind: .roomControl,
                                 body: control, createdAt: F.t0, v: 2)
    v["manifestPacketJSON"] = String(decoding: try! MeshCodec.encode(try! RoomEnvelope.seal(controlMsg, in: adminRoom)), as: UTF8.self)
    var roomChat = MeshMessage(id: UUID(uuidString: "44444444-5555-4666-8777-888888888888")!, origin: "MacBook Air", kind: .chat,
                               body: "Welcome, Ben", createdAt: F.t0, senderName: "Kyle", v: 2)
    roomChat.hops = ["MacBook Air"]
    v["epochSealedJSON"] = String(decoding: try! MeshCodec.encode(try! RoomEnvelope.seal(roomChat, in: adminRoom)), as: UTF8.self)

    // 6. Sync payload with library titles and a task (what a phone gets on link).
    let task = TaskItem(id: UUID(uuidString: "55555555-6666-4777-8888-999999999999")!, title: "Order cement", assignee: "Ben",
                        due: "Friday", createdBy: "MacBook Air", createdAt: F.t0)
    v["taskJSON"] = MeshPayload.encode(task)!
    var mm = MemoryManifest(ruleIDs: [], taskIDs: [task.id], resetAt: nil, clearedAt: nil)
    mm.library = [LibraryListing(title: "Site safety", version: 1, pages: 4, visibility: .everyone)]
    v["syncManifestJSON"] = SyncPayload(manifest: mm).encoded()!
    let rule = RuleEntry(id: UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa")!, title: "Hard hats", body: "Wear one on site.",
                         addedBy: "MacBook Air", createdAt: F.t0, version: 2)
    v["ruleJSON"] = MeshPayload.encode(rule)!

    let data = try! JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(v.count) vectors to \(path)")
}

/// Checks the bytes the Kotlin code produced (if the fixture is present).
func runAndroidInteropTests() {
    typealias F = AndroidVectorFixtures
    let path = "android/app/src/test/resources/kotlin_vectors.json"
    guard let data = FileManager.default.contents(atPath: path),
          let k = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        print("  info: no Kotlin vectors at \(path), Android interop checks skipped")
        return
    }
    // Join request signed by Kotlin (Ed25519), proof made by Kotlin, accepted by a Swift admin.
    let codeKey = CodeRoom.codeKey(name: F.roomName, code: F.code)!
    var adminRoom = Room.fromCode(name: F.roomName, creator: "MacBook Air", now: F.t0)!
    _ = RoomGovernor.setUp(&adminRoom, identity: F.adminIdentity, device: "MacBook Air", name: "Kyle", now: F.t0,
                           code: F.code, codeKey: codeKey, codeExpiresAt: nil, approval: false)
    if let text = k["joinRequestBlob"] as? String, let blob = try? PasaJSON.decoder.decode(SignedBlob.self, from: Data(text.utf8)) {
        check(blob.isValid, "android interop: Kotlin Ed25519 signature verifies in Swift")
        check(blob.decode(JoinRequest.self)?.device == "Pixel-A1", "android interop: Kotlin join request decodes in Swift")
        if case .admitted(let m) = RoomGovernor.admit(blob, room: &adminRoom, identity: F.adminIdentity, now: F.t0) {
            let decoded = m.decode(RoomManifest.self)
            check(decoded?.members.contains { $0.device == "Pixel-A1" } == true, "android interop: Swift admin admits a Kotlin join request with a Kotlin code proof")
            check(decoded?.boxes[RoomCrypto.base64url(blob.signer)] != nil, "android interop: admitted Kotlin device gets a key box")
        } else {
            check(false, "android interop: Swift admin admits a Kotlin join request with a Kotlin code proof")
        }
    } else {
        check(false, "android interop: Kotlin join request present")
    }
    // Packet sealed by Kotlin in Town Square opens in Swift.
    if let text = k["townSealedJSON"] as? String, let outer = try? MeshCodec.decode(Data(text.utf8)) {
        let inner = RoomEnvelope.open(outer, in: Room.makeDefault())
        check(inner?.body == "Hello from Android, PATIENT_A placeholder", "android interop: Kotlin-sealed Town Square packet opens in Swift")
        check(inner?.senderName == "Ben" && inner?.kind == .chat, "android interop: Kotlin inner message fields decode in Swift")
    } else {
        check(false, "android interop: Kotlin sealed packet decodes as a MeshMessage")
    }
    // Streamed answer piece sealed by Kotlin (issue #2): opens in Swift with its kind and order.
    if let text = k["answerPartSealedJSON"] as? String, let outer = try? MeshCodec.decode(Data(text.utf8)) {
        let inner = RoomEnvelope.open(outer, in: Room.makeDefault())
        check(inner?.kind == .answerPart && inner?.part == 2 && inner?.body == " and boots",
              "android interop: Kotlin-sealed answer part opens in Swift with kind, part and text")
        check(inner?.replyTo == UUID(uuidString: "7B7B7B7B-1111-4222-8333-444444444444"), "android interop: Kotlin answer part names its ask")
    } else {
        check(false, "android interop: Kotlin answer part present")
    }
    // Ask sealed by Kotlin with the epoch key: opens on the admin Mac.
    if let text = k["epochAskJSON"] as? String, let outer = try? MeshCodec.decode(Data(text.utf8)),
       let epochKeyHex = k["epochKeyUsed"] as? String {
        var room = adminRoom
        var gov = room.gov ?? RoomGov()
        gov.epochKeys[String(room.epoch)] = unhex(epochKeyHex)
        room.gov = gov
        let inner = RoomEnvelope.open(outer, in: room)
        check(inner?.kind == .ask && inner?.destination == .role("ai"), "android interop: Kotlin @libre ask (epoch key) opens in Swift as an ask to the AI role")
    }
    // Signed hello and proof made in Kotlin verify in Swift.
    if let helloHex = k["signedHello"] as? String, let proofHex = k["proofForAdmin"] as? String, let nonceHex = k["adminNonce"] as? String {
        let h = BLEHello.open(unhex(helloHex))
        check(h?.name == "Pixel-A1" && h?.signKey == F.joinerIdentity.signKey, "android interop: Kotlin signed Bluetooth hello verifies in Swift")
        if let h {
            check(BLEHello.checkProof(unhex(proofHex), peer: h, myChallenge: unhex(nonceHex), myKey: F.adminIdentity.signKey),
                  "android interop: Kotlin proof over the Mac's challenge verifies in Swift")
        }
    } else {
        check(false, "android interop: Kotlin signed hello present")
    }
    // Frames cut by Kotlin reassemble in Swift.
    if let frames = k["frames"] as? [String], let expect = k["framesData"] as? String {
        var r = BLEReassembler()
        var out: Data?
        for f in frames { if let c = r.add(unhex(f), link: "android") { out = c.data } }
        check(out == unhex(expect), "android interop: Kotlin BLE frames reassemble in Swift")
    }
}
