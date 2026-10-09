// PasscodeMediaTests.swift: Wi-Fi style rooms (name + passcode, PBKDF2) and media chunking.

import Foundation

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

@MainActor
func runPasscodeTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // RFC 7914 section 11 PBKDF2-HMAC-SHA256 vectors (also what Python's hashlib gives).
    let rfc1 = "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
    let rfc2 = "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d"
    check(hex(PBKDF2SHA256.deriveSwift(password: Data("passwd".utf8), salt: Data("salt".utf8), rounds: 1, length: 64)) == rfc1,
          "pbkdf2: pure Swift matches RFC 7914 vector 1")
    check(hex(PBKDF2SHA256.deriveSwift(password: Data("Password".utf8), salt: Data("NaCl".utf8), rounds: 80_000, length: 64)) == rfc2,
          "pbkdf2: pure Swift matches RFC 7914 vector 2 (80,000 rounds)")
    check(hex(PBKDF2SHA256.derive(password: Data("passwd".utf8), salt: Data("salt".utf8), rounds: 1, length: 64)) == rfc1,
          "pbkdf2: platform implementation matches RFC 7914 vector 1")
    #if canImport(CommonCrypto)
    check(PBKDF2SHA256.deriveCommonCrypto(password: Data("Password".utf8), salt: Data("NaCl".utf8), rounds: 80_000, length: 64).map(hex) == rfc2,
          "pbkdf2: CommonCrypto matches RFC 7914 vector 2")
    check(PBKDF2SHA256.deriveCommonCrypto(password: Data("é pass".utf8), salt: Data("x".utf8), rounds: 777, length: 32)
          == PBKDF2SHA256.deriveSwift(password: Data("é pass".utf8), salt: Data("x".utf8), rounds: 777, length: 32),
          "pbkdf2: CommonCrypto and pure Swift agree")
    #endif

    // App vector at production rounds, computed independently with Python hashlib:
    // pbkdf2_hmac('sha256', b'tubig-sa-bohol', b'pasa-room-passcode-v1|bohol-7', 600000, 32)
    let appVector = "bc42143e32be8657bb1f8835b3bca3fa13491c9ce12c3bf062f81e2a391ffc40"
    check(RoomPasscode.rounds == 600_000, "passcode: 600,000 PBKDF2 rounds")
    let started = Date()
    let prodKey = RoomPasscode.deriveKey(name: "Bohol 7", passcode: "tubig-sa-bohol")
    let elapsed = Date().timeIntervalSince(started)
    check(hex(prodKey) == appVector, "passcode: room key matches the independent app vector (same on every platform)")
    print("  info: room key derivation at 600,000 rounds took \(String(format: "%.2f", elapsed)) s on this machine")
    check(hex(RoomPasscode.deriveKey(name: "BOHOL-7", passcode: "tubig-sa-bohol", rounds: 1000)) == "ea2f30a00acd4ba44400dc76ebf7f7c5c82026057c0fca968510529e4d7ba844",
          "passcode: low-round vector matches Python")

    // Name normalization: case, spaces and trim do not change the room; the passcode does.
    let fast = 1000
    let k1 = RoomPasscode.deriveKey(name: "  bohol 7 ", passcode: "tubig-sa-bohol ", rounds: fast)
    let k2 = RoomPasscode.deriveKey(name: "BOHOL-7", passcode: "tubig-sa-bohol", rounds: fast)
    check(k1 == k2 && k1.count == 32, "passcode: name normalized (lowercase, trimmed, spaces to -), passcode trimmed")
    check(RoomPasscode.deriveKey(name: "BOHOL-7", passcode: "Tubig-sa-bohol", rounds: fast) != k2, "passcode: case matters in the passcode")
    check(RoomPasscode.deriveKey(name: "CEBU-2", passcode: "tubig-sa-bohol", rounds: fast) != k2, "passcode: same passcode, other room name, other key (name is the salt)")
    check(RoomPasscode.normalizedName("Bohol 7") == "bohol-7", "passcode: normalized name is bohol-7")

    // Rooms from a passcode.
    guard let created = Room.fromPasscode(name: "Bohol 7", passcode: "tubig-sa-bohol", creator: "iPhone 7597", now: t0, rounds: fast),
          let joined = Room.fromPasscode(name: "bohol-7", passcode: "tubig-sa-bohol", creator: "", now: t0, rounds: fast) else {
        check(false, "passcode: rooms created"); return
    }
    check(created.id == joined.id && created.key == joined.key, "passcode: typing name and passcode joins the same room (same key and tag)")
    check(created.label == "BOHOL-7" && created.usesPasscode && created.creator == "iPhone 7597", "passcode: creator pinned, label BOHOL-7")
    check(Room.fromPasscode(name: "Bohol 7", passcode: "12345", creator: "x", rounds: fast) == nil, "passcode: shorter than 6 is refused")
    check(Room.fromPasscode(name: "   ", passcode: "longenough", creator: "x", rounds: fast) == nil, "passcode: empty name is refused")
    check(Room.fromPasscode(name: "default", passcode: "longenough", creator: "x", rounds: fast) == nil, "passcode: the name DEFAULT is reserved")
    check(created.checkCode.count == 4 && created.checkCode == joined.checkCode, "passcode: check code matches on both devices")
    if let other = Room.fromPasscode(name: "Bohol 7", passcode: "tubig-sa-cebu", creator: "", rounds: fast) {
        check(other.id != created.id && other.checkCode != created.checkCode || other.id != created.id, "passcode: a typo lands in a different room")
    }

    // Join string: carries the derived key and a passcode flag, never the passcode.
    let js = created.joinString
    check(js.hasSuffix(".p") && !js.contains("tubig"), "passcode: join string marks passcode rooms and never contains the passcode")
    let parsed = Room.parse(joinString: js, now: t0)
    check(parsed?.id == created.id && parsed?.usesPasscode == true && parsed?.creator == "iPhone 7597", "passcode: join string round trip keeps key, flag and creator")
    let legacy = Room.create(label: "OLD-1", creator: "Mac", now: t0)
    check(!legacy.usesPasscode && !legacy.joinString.hasSuffix(".p") && Room.parse(joinString: legacy.joinString)?.key == legacy.key,
          "passcode: random-key rooms keep their 4-part join string")
    check(Room.parse(joinString: legacy.joinString + ".x") == nil, "passcode: unknown 5th part is rejected")

    // Saved rooms from before this build (no keySource) still load.
    do {
        let old = #"{"rooms":[{"label":"OLD-1","key":"\#(legacy.key.base64EncodedString())","creator":"Mac","createdAt":"2027-01-15T08:00:00Z","admins":[]}],"activeID":"\#(legacy.id)"}"#
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pasa-pass-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try? Data(old.utf8).write(to: base.appendingPathComponent("rooms.json"))
        let store = RoomStore(baseURL: base)
        check(store.active.id == legacy.id && store.active.keySource == nil && !store.active.usesPasscode, "migration: old random-key room loads unchanged")
        store.join(joined)
        check(store.active.creator.isEmpty, "passcode: a typed join does not know the creator")
        store.join(created)   // later the QR / join string arrives
        check(store.rooms.count == 2 && store.active.creator == "iPhone 7597", "passcode: scanning later pins the creator, one copy kept")
        let reloaded = RoomStore(baseURL: base)
        check(reloaded.room(withID: created.id)?.usesPasscode == true, "passcode: keySource persists")
    }

    // Sealing works the same for passcode rooms (HKDF downstream unchanged).
    do {
        let engine = RelayEngine(selfName: "iPhone 12")
        let m = engine.makeOutgoing(kind: .chat, body: "hello")
        let outer = try? RoomEnvelope.seal(m, in: created)
        check(outer.flatMap { RoomEnvelope.open($0, in: joined) }?.body == "hello", "passcode: a device that typed the passcode reads the creator's messages")
    }

    // Strength hints.
    check(RoomPasscode.strength("abc12") == .tooShort, "strength: 5 chars too short")
    check(RoomPasscode.strength("123456") == .weak && RoomPasscode.strength("password") == .weak, "strength: common passcodes weak")
    check(RoomPasscode.strength("aaaaaaaa") == .weak, "strength: repeated characters weak")
    check(RoomPasscode.strength("4471") == .tooShort && RoomPasscode.strength("447129") == .weak, "strength: short digit codes weak")
    check(RoomPasscode.strength("Bohol7site") == .fair, "strength: 10 mixed chars fair")
    check(RoomPasscode.strength("tubig sa bohol 77") == .strong, "strength: words plus digits strong")
    check(RoomPasscode.hint("abc").contains("6"), "strength: hint names the minimum")
}

@MainActor
func runMediaTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var bytes = [UInt8](repeating: 0, count: 50_000)
    for i in bytes.indices { bytes[i] = UInt8((i * 31 + 7) % 251) }
    let photo = Data(bytes)

    // Manifest and chunking.
    let manifest = MediaChunker.manifest(for: photo, kind: .image, mime: "image/jpeg", width: 1024, height: 768)
    check(manifest.isValid && manifest.chunkCount == 5 && manifest.chunkSize == 12 * 1024, "media: 50 KB photo is 5 chunks of 12 KB")
    check(manifest.fileExtension == "jpg" && manifest.displayLine == "Photo", "media: photo manifest basics")
    let chunks = MediaChunker.chunks(of: photo, manifest: manifest)
    check(chunks.count == 5 && chunks.map(\.data.count).reduce(0, +) == photo.count, "media: chunks cover the file exactly")
    check(MediaManifest.decode(manifest.encoded() ?? "") == manifest, "media: manifest round trip")
    var bad = manifest
    bad.chunkCount = 99
    check(MediaManifest.decode(bad.encoded() ?? "") == nil, "media: manifest with wrong chunk count rejected")
    var huge = manifest
    huge.byteCount = 5_000_000
    check(!huge.isValid, "media: oversize media rejected")
    let voice = MediaChunker.manifest(for: Data(repeating: 1, count: 90_000), kind: .audio, mime: "audio/mp4", durationSeconds: 29.6)
    check(voice.displayLine == "Voice note 0:30" && voice.fileExtension == "m4a", "media: voice note line shows duration")

    // Assembly out of order, duplicates, before the manifest.
    do {
        let asm = MediaAssembler()
        var outcomes: [MediaAssembler.Outcome] = []
        for i in [3, 0, 4, 0, 1] { outcomes.append(asm.add(chunks[i], now: t0)) }
        check(outcomes[3] == .ignored, "media: duplicate chunk ignored")
        check(asm.progress(manifest.mediaId) == 0.8 && asm.missing(manifest.mediaId) == [2], "media: progress and missing list before the manifest")
        asm.expect(manifest, now: t0)
        check(asm.manifest(manifest.mediaId) == manifest, "media: manifest attached to an early transfer")
        check(asm.add(chunks[2], now: t0) == .complete(photo), "media: reassembled with SHA-256 check")
        check(!asm.isPending(manifest.mediaId), "media: finished transfer leaves the pending list")
    }

    // Integrity: a tampered chunk makes the whole file fail, then it is asked again.
    do {
        let asm = MediaAssembler()
        asm.expect(manifest, now: t0)
        var tampered = chunks[1]
        tampered.data[0] ^= 0xFF
        for (i, c) in chunks.enumerated() { _ = asm.add(i == 1 ? tampered : c, now: t0) }
        check(asm.progress(manifest.mediaId) == 0 && asm.isPending(manifest.mediaId), "media: corrupt file discarded, transfer kept for re-request")
        var lie = chunks[0]
        lie.sha256 = String(repeating: "a", count: 64)
        check(asm.add(lie, now: t0) == .ignored, "media: chunk with another file hash ignored")
        var outOfRange = chunks[0]
        outOfRange.index = 9
        check(asm.add(outOfRange, now: t0) == .ignored, "media: chunk index out of range ignored")
    }

    // NACK: stalled transfers ask for exactly the missing chunks, with backoff and a cap.
    do {
        let asm = MediaAssembler()
        asm.expect(manifest, now: t0)
        _ = asm.add(chunks[0], now: t0)
        _ = asm.add(chunks[2], now: t0)
        check(asm.dueForNack(now: t0.addingTimeInterval(2)).isEmpty, "nack: not before the stall timeout")
        let due = asm.dueForNack(now: t0.addingTimeInterval(7))
        check(due == [MediaNack(mediaId: manifest.mediaId, missing: [1, 3, 4])], "nack: asks for the missing chunks only")
        check(asm.dueForNack(now: t0.addingTimeInterval(8)).isEmpty, "nack: waits again after asking")
        check(asm.dueForNack(now: t0.addingTimeInterval(8), force: true).count == 1, "nack: a new link asks right away")
        var t = t0.addingTimeInterval(8)
        for _ in 0..<10 { t = t.addingTimeInterval(7); _ = asm.dueForNack(now: t) }
        check(asm.dueForNack(now: t.addingTimeInterval(7)).isEmpty, "nack: gives up after the retry cap")
        check(asm.part(manifest.mediaId, index: 2)?.data == chunks[2].data, "nack: partial holders can serve chunks they have")
        let wire = MediaNack.decode(MediaNack(mediaId: manifest.mediaId, missing: [4, 1, 1, -3, 500]).encoded()!)
        check(wire?.missing == [1, 4], "nack: decoded list is cleaned and sorted")
        asm.prune(now: t.addingTimeInterval(4000))
        check(!asm.isPending(manifest.mediaId), "media: stale transfers pruned")
    }

    // Pending transfers are capped (memory safety).
    do {
        let asm = MediaAssembler()
        for i in 0..<(MediaLimits.maxPending + 5) {
            let m = MediaChunker.manifest(for: Data(repeating: UInt8(i), count: 2000), kind: .image, mime: "image/jpeg")
            asm.expect(m, now: t0.addingTimeInterval(Double(i)))
        }
        check(asm.pendingIDs.count == MediaLimits.maxPending, "media: at most 24 unfinished transfers kept")
    }

    // Chunks travel sealed, relayed, deduped per chunk packet, and opened by room members only.
    do {
        let room = Room.create(label: "BOHOL-7", creator: "iPhone 7597", now: t0)
        let other = Room.create(label: "CEBU-2", creator: "x", now: t0)
        let sender = RelayEngine(selfName: "iPhone 12")
        let packets = chunks.map { c -> MeshMessage in
            try! RoomEnvelope.seal(sender.makeOutgoing(kind: .chunk, body: c.encoded()!), in: room)
        }
        check(Set(packets.map(\.id)).count == 5, "media: every chunk is its own packet id (dedupe per chunk)")
        let wire = packets.map { (try? MeshCodec.encode($0))?.count ?? 0 }
        check(wire.allSatisfy { $0 < 24_000 }, "media: each chunk packet stays under 24 KB on the wire")
        let relay = RelayEngine(selfName: "iPhone 14")
        let forwarded = packets.compactMap { relay.handleIncoming($0, from: "iPhone 12").forward }
        check(forwarded.count == 5 && relay.handleIncoming(packets[0], from: "iPhone 12").isDuplicate, "media: chunks relay with ttl and dedupe like messages")
        let mac = RelayEngine(selfName: "Mac")
        let asm = MediaAssembler()
        var result: MediaAssembler.Outcome = .ignored
        for p in forwarded.reversed() {
            guard let d = mac.handleIncoming(p, from: "iPhone 14").deliver, let inner = RoomEnvelope.open(d, in: room),
                  inner.kind == .chunk, let c = MediaChunk.decode(inner.body) else { continue }
            result = asm.add(c, now: t0)
        }
        check(result == .complete(photo), "media: 2-hop sealed chunks reassemble at the Mac")
        check(RoomEnvelope.open(packets[0], in: other) == nil, "media: another room cannot open the chunks")
        let plainWire = String(decoding: (try? MeshCodec.encode(packets[0])) ?? Data(), as: UTF8.self)
        check(!plainWire.contains(manifest.mediaId.uuidString), "media: media id is inside the sealed part")
    }

    // Cache: LRU eviction under a size cap, survives reload.
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pasa-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MediaStore(directory: dir, capBytes: 25_000)
        let a = UUID(), b = UUID(), c = UUID()
        check(store.put(a, data: Data(repeating: 1, count: 10_000), ext: "jpg", now: t0), "cache: put a")
        check(store.put(b, data: Data(repeating: 2, count: 10_000), ext: "m4a", now: t0.addingTimeInterval(1)), "cache: put b")
        _ = store.data(a, now: t0.addingTimeInterval(2))   // a is now the most recent
        check(store.put(c, data: Data(repeating: 3, count: 10_000), ext: "jpg", now: t0.addingTimeInterval(3)), "cache: put c")
        check(store.has(a) && !store.has(b) && store.has(c) && store.totalBytes == 20_000, "cache: least recently used file evicted")
        check(!store.put(UUID(), data: Data(repeating: 9, count: 30_000), ext: "jpg"), "cache: a file larger than the cap is refused")
        check(store.url(c)?.pathExtension == "jpg", "cache: file keeps its extension")
        let reloaded = MediaStore(directory: dir, capBytes: 25_000)
        check(reloaded.has(a) && reloaded.has(c) && !reloaded.has(b) && reloaded.data(c) == Data(repeating: 3, count: 10_000), "cache: index reloads from disk")
        check(MediaLimits.phoneCacheBytes == 200 * 1024 * 1024, "cache: phones cap media at 200 MB")
    }

    // Transcripts and voice asks.
    do {
        let t = TranscriptPayload(text: "At Pasa remind Ana to order cement Friday", locale: "en-US")
        check(TranscriptPayload.decode(t.encoded()!) == t, "transcript: round trip")
        check(TranscriptPayload(text: "", locale: "fil-PH", note: "No on-device model").displayLine == "No on-device model", "transcript: note shown when no text")
        check(VoiceAsk.extract("At Pasa, remind Ana to order cement Friday.") == "remind Ana to order cement Friday.", "voice ask: 'At Pasa,' routes to the AI")
        check(VoiceAsk.extract("@Pasa can I visit the site at 6 PM?") == "can I visit the site at 6 PM?", "voice ask: '@Pasa'")
        check(VoiceAsk.extract("Pasa, what did I miss?") == "what did I miss?", "voice ask: 'Pasa,'")
        check(VoiceAsk.extract("hey pasa my tasks") == "my tasks", "voice ask: 'hey pasa'")
        check(VoiceAsk.extract("Pasa lang ang message sa lahat") == nil, "voice ask: plain Tagalog 'Pasa lang' is not a call")
        check(VoiceAsk.extract("At pasalubong time we leave") == nil, "voice ask: 'at pasalubong' is not a call")
        check(VoiceAsk.extract("At Pasa.") == nil, "voice ask: a call with no question is ignored")
        check(VoiceAsk.extract("The truck is at the gate") == nil, "voice ask: ordinary voice note stays chat")
    }

    // Backfill carries media manifests (phones then NACK for the bytes).
    do {
        let engine = RelayEngine(selfName: "Mac")
        let media = engine.makeOutgoing(kind: .media, body: manifest.encoded()!, now: t0)
        let chunk = engine.makeOutgoing(kind: .chunk, body: chunks[0].encoded()!, now: t0)
        let entries = [ChatEntry(id: media.id, message: media, direction: .sent, receivedAt: t0),
                       ChatEntry(id: chunk.id, message: chunk, direction: .sent, receivedAt: t0)]
        let picked = Backfill.select(from: entries, for: "iPhone 12", request: SyncRequest(newest: nil, knownIDs: []))
        check(picked.map(\.id) == [media.id], "backfill: media manifest included, raw chunks never")
        check(MeshPayload.displayText(for: media) == "Photo", "timeline: media line")
        var entry = entries[0]
        entry.transcript = "hello"
        let saved = try? TimelineStore.encode(PersistedTimeline(entries: [entry]), limit: 10)
        check(saved.flatMap { try? TimelineStore.decode($0, limit: 10) }?.entries.first?.transcript == "hello", "timeline: transcript persists")
    }
}
