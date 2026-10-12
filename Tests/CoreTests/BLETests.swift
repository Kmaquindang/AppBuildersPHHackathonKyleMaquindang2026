// BLETests.swift: Bluetooth link framing, chunking, reassembly, MTU edge cases, link choice,
// and duplicate suppression when one packet arrives over both Wi-Fi and Bluetooth.

import Foundation

private func bytes(_ n: Int, seed: UInt8 = 7) -> Data {
    Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// Sends `data` through chunk + reassemble at `mtu`, in the order given by `order` (indexes).
private func roundTrip(_ data: Data, mtu: Int, id: UInt32 = 1, order: (([Data]) -> [Data])? = nil) -> (frames: [Data], out: Data?) {
    guard let frames = BLEChunker.frames(data, messageID: id, mtu: mtu) else { return ([], nil) }
    var r = BLEReassembler()
    var out: Data?
    for f in (order?(frames) ?? frames) {
        if let c = r.add(f, link: "L") { out = c.data }
    }
    return (frames, out)
}

func runBLETests() {
    // 1. Frame header round trip.
    do {
        let f = BLEFrame(type: .data, messageID: 0xDEADBEEF, index: 3, count: 9, payload: Data([1, 2, 3]))
        let e = f.encoded()
        check(e.count == BLEFrame.headerSize + 3, "ble frame: header is 11 bytes plus payload")
        check(BLEFrame.decode(e) == f, "ble frame: encode then decode gives the same frame")
        check(e[0] == 0x4C && e[1] == 2, "ble frame: magic L and version 2 (signed hello)")
        let hello = BLEFrame(type: .hello, messageID: 0, index: 0, count: 1, payload: Data("iPhone 14".utf8))
        check(BLEFrame.decode(hello.encoded())?.type == .hello, "ble frame: hello type survives")
    }

    // 2. Malformed frames are refused.
    do {
        let good = BLEFrame(type: .data, messageID: 1, index: 0, count: 2, payload: Data([9])).encoded()
        var badMagic = good; badMagic[0] = 0x00
        var badVersion = good; badVersion[1] = 1
        var badType = good; badType[2] = 77
        var zeroCount = good; zeroCount[9] = 0; zeroCount[10] = 0
        var indexPast = good; indexPast[8] = 2
        check(BLEFrame.decode(badMagic) == nil, "ble frame: wrong magic refused")
        check(BLEFrame.decode(badVersion) == nil, "ble frame: old version 1 (unsigned hello) refused")
        check(BLEFrame.decode(badType) == nil, "ble frame: unknown type refused")
        check(BLEFrame.decode(zeroCount) == nil, "ble frame: zero chunk count refused")
        check(BLEFrame.decode(indexPast) == nil, "ble frame: index past count refused")
        check(BLEFrame.decode(Data(good.prefix(10))) == nil, "ble frame: shorter than the header refused")
        check(BLEFrame.decode(Data()) == nil, "ble frame: empty refused")
        var r = BLEReassembler()
        check(r.add(badMagic, link: "L") == nil && r.droppedCount == 1, "ble reassembler: counts a dropped malformed frame")
    }

    // 3. Chunk sizes and MTU edge cases.
    do {
        check(BLEChunker.payloadSize(mtu: 20) == 9, "ble mtu: minimum 20 leaves 9 payload bytes")
        check(BLEChunker.payloadSize(mtu: 5) == 9, "ble mtu: an MTU below 20 is treated as 20")
        check(BLEChunker.payloadSize(mtu: 182) == 171, "ble mtu: iOS-typical 182 leaves 171")
        check(BLEChunker.payloadSize(mtu: 512) == 501, "ble mtu: 512 leaves 501")

        let exact = bytes(171)
        let one = roundTrip(exact, mtu: 182)
        check(one.frames.count == 1 && one.out == exact, "ble mtu: payload exactly one frame long is one frame")
        let plusOne = roundTrip(bytes(172), mtu: 182)
        check(plusOne.frames.count == 2 && plusOne.out == bytes(172), "ble mtu: one byte over the boundary makes two frames")
        check(plusOne.frames[1].count == BLEFrame.headerSize + 1, "ble mtu: the last frame carries only the leftover byte")
        let empty = roundTrip(Data(), mtu: 182)
        check(empty.frames.count == 1 && empty.out == Data(), "ble mtu: empty message is one empty frame")
        let tiny = roundTrip(bytes(1000), mtu: 20)
        check(tiny.frames.count == 112 && tiny.out == bytes(1000), "ble mtu: 1000 bytes at MTU 20 is 112 frames and reassembles")
        check(tiny.frames.allSatisfy { $0.count <= 20 }, "ble mtu: no frame exceeds the MTU")
        let big = roundTrip(bytes(17_000), mtu: 512)
        check(big.frames.allSatisfy { $0.count <= 512 } && big.out == bytes(17_000), "ble mtu: a sealed media chunk (17 KB) fits frames of 512 and reassembles")
        check(BLEChunker.frames(bytes(BLEChunker.maxMessageBytes + 1), messageID: 1, mtu: 512) == nil, "ble chunker: refuses messages over the BLE size cap")
        check(BLEChunker.frames(bytes(BLEChunker.maxMessageBytes), messageID: 1, mtu: 512) != nil, "ble chunker: accepts a message exactly at the cap")
    }

    // 4. Reassembly order, duplicates, interleaving.
    do {
        let data = bytes(2_000)
        let rev = roundTrip(data, mtu: 100, order: { $0.reversed() })
        check(rev.out == data, "ble reassembly: frames in reverse order")
        let dup = roundTrip(data, mtu: 100, order: { f in f.flatMap { [$0, $0] } })
        check(dup.out == data, "ble reassembly: every frame twice still gives the message once")

        // Two messages interleaved on one link.
        let a = bytes(700, seed: 1), b = bytes(900, seed: 2)
        let fa = BLEChunker.frames(a, messageID: 10, mtu: 64)!, fb = BLEChunker.frames(b, messageID: 11, mtu: 64)!
        var r = BLEReassembler()
        var done: [UInt32: Data] = [:]
        for i in 0..<max(fa.count, fb.count) {
            if i < fa.count, let c = r.add(fa[i], link: "L") { done[c.messageID] = c.data }
            if i < fb.count, let c = r.add(fb[i], link: "L") { done[c.messageID] = c.data }
        }
        check(done[10] == a && done[11] == b, "ble reassembly: two interleaved messages both reassemble")

        // Same id on two links does not mix.
        let x = bytes(300, seed: 3), y = bytes(300, seed: 4)
        let fx = BLEChunker.frames(x, messageID: 5, mtu: 64)!, fy = BLEChunker.frames(y, messageID: 5, mtu: 64)!
        var r2 = BLEReassembler()
        var got: [String: Data] = [:]
        for i in 0..<fx.count {
            if let c = r2.add(fx[i], link: "phone-a") { got["a"] = c.data }
            if let c = r2.add(fy[i], link: "phone-b") { got["b"] = c.data }
        }
        check(got["a"] == x && got["b"] == y, "ble reassembly: same message id on two links stays separate")

        // A re-sent frame of an already finished message does not deliver it again.
        var r3 = BLEReassembler()
        let f3 = BLEChunker.frames(bytes(50), messageID: 9, mtu: 30)!
        var deliveries = 0
        for f in f3 + [f3[0], f3.last!] { if r3.add(f, link: "L") != nil { deliveries += 1 } }
        check(deliveries == 1, "ble reassembly: late copies of a finished message are ignored")
    }

    // 5. Timeouts, reset, memory cap, reused ids.
    do {
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        let f = BLEChunker.frames(bytes(500), messageID: 3, mtu: 64)!
        var r = BLEReassembler()
        _ = r.add(f[0], link: "L", now: t0)
        check(r.pendingCount(link: "L") == 1, "ble reassembly: a partial message is held")
        _ = r.add(f[1], link: "L", now: t0 + BLEReassembler.timeout + 1)
        check(r.pendingCount(link: "L") == 1 && r.droppedCount >= 1, "ble reassembly: a stalled partial is dropped after the timeout")
        var gotLate = false
        for g in f.dropFirst(2) { if r.add(g, link: "L", now: t0 + BLEReassembler.timeout + 2) != nil { gotLate = true } }
        check(!gotLate, "ble reassembly: missing first frame after a timeout means no delivery (never a corrupt message)")
        r.reset(link: "L")
        check(r.pendingCount(link: "L") == 0, "ble reassembly: reset forgets a disconnected link")

        var cap = BLEReassembler()
        for id in 0..<6 {
            let fr = BLEChunker.frames(bytes(BLEChunker.maxMessageBytes), messageID: UInt32(100 + id), mtu: 512)!
            for g in fr.dropLast() { _ = cap.add(g, link: "L", now: t0 + Double(id)) }
        }
        check(cap.pendingCount(link: "L") <= 2, "ble reassembly: buffered bytes per link are capped")

        // Reused id with a different count restarts the message instead of mixing bytes.
        var reuse = BLEReassembler()
        let old = BLEChunker.frames(bytes(300, seed: 8), messageID: 42, mtu: 64)!
        let new = BLEChunker.frames(bytes(100, seed: 9), messageID: 42, mtu: 64)!
        _ = reuse.add(old[0], link: "L")
        var out: Data?
        for g in new { if let c = reuse.add(g, link: "L") { out = c.data } }
        check(out == bytes(100, seed: 9), "ble reassembly: a reused id with a new count gives the new message only")
    }

    // 6. Link choice: Wi-Fi preferred, Bluetooth for the rest.
    do {
        let p = LinkRouter.plan(wifi: ["Mac", "iPhone 14"], bluetooth: ["iPhone 14", "iPhone 12"], blocked: [], excluding: [], bytes: 400)
        check(p.wifi == ["Mac", "iPhone 14"] && p.bluetooth == ["iPhone 12"], "link router: a peer on both links goes over Wi-Fi only")
        check(p.all == ["Mac", "iPhone 12", "iPhone 14"], "link router: each peer gets exactly one copy")
        let off = LinkRouter.plan(wifi: [], bluetooth: ["iPhone 14", "Mac"], blocked: ["Mac"], excluding: ["iPhone 9"], bytes: 400)
        check(off.wifi.isEmpty && off.bluetooth == ["iPhone 14"], "link router: Wi-Fi off, Bluetooth carries; blocked peers skipped")
        let ex = LinkRouter.plan(wifi: [], bluetooth: ["A", "B"], blocked: [], excluding: ["A"], bytes: 10)
        check(ex.bluetooth == ["B"], "link router: excluded (already on the path) peers skipped")
        let big = LinkRouter.plan(wifi: ["Mac"], bluetooth: ["iPhone 12"], blocked: [], excluding: [], bytes: 300_000, bluetoothLimit: 256 * 1024)
        check(big.wifi == ["Mac"] && big.bluetooth.isEmpty && big.tooBigForBluetooth == ["iPhone 12"], "link router: a packet over the BLE cap is not sent over Bluetooth")
        check(LinkRouter.merged("disconnected", "connected") == "connected", "link router: connected on either link means connected")
        check(LinkRouter.merged(nil, "connecting") == "connecting" && LinkRouter.merged(nil, nil) == nil, "link router: merged state with one or no link")
        check(LinkKind.bluetooth.via == "via Bluetooth", "link kind: Details label")
    }

    // 7. Duplicate suppression across two transports, with real encode + BLE framing.
    do {
        let a = RelayEngine(selfName: "Mac")
        let b = RelayEngine(selfName: "iPhone 14")
        let m = MeshMessage(origin: "iPhone 12", kind: .chat, body: "Wi-Fi off test, PATIENT_A synthetic")
        let wire = try MeshCodec.encode(m)
        // Copy 1 over Bluetooth (chunked at a small MTU), copy 2 over Wi-Fi.
        var r = BLEReassembler()
        var overBLE: Data?
        for f in BLEChunker.frames(wire, messageID: 77, mtu: 23)! { if let c = r.add(f, link: "ble-1") { overBLE = c.data } }
        check(overBLE == wire, "two links: Bluetooth copy reassembles byte for byte")
        let viaBLE = a.handleIncoming(try MeshCodec.decode(overBLE!), from: "iPhone 12")
        let viaWiFi = a.handleIncoming(try MeshCodec.decode(wire), from: "iPhone 12")
        check(viaBLE.deliver != nil && !viaBLE.isDuplicate, "two links: first copy (Bluetooth) delivered")
        check(viaWiFi.isDuplicate && viaWiFi.deliver == nil && viaWiFi.forward == nil, "two links: same packet over Wi-Fi is suppressed")
        // The forward hops on over the other link type and is still suppressed at the next device.
        let fwd = try MeshCodec.encode(viaBLE.forward!)
        let atB1 = b.handleIncoming(try MeshCodec.decode(fwd), from: "Mac")
        let atB2 = b.handleIncoming(m, from: "iPhone 12")
        check(atB1.deliver?.hops == ["iPhone 12", "Mac", "iPhone 14"], "two links: Bluetooth hop is recorded like any other hop")
        check(atB2.isDuplicate, "two links: direct copy after the relayed one is suppressed")
    } catch {
        check(false, "two links test threw \(error)")
    }

    // 8. Mesh sim: B and C share no Wi-Fi; a message from C reaches B through A over Bluetooth.
    do {
        let sim = SimMesh(nodes: ["A", "B", "C"], links: [("A", "B"), ("A", "C")])
        // A-B linked twice (Wi-Fi and Bluetooth): simulate by sending the same flood twice.
        let m = MeshMessage(origin: "C", kind: .chat, body: "hop over Bluetooth")
        sim.send(m, from: "C")
        sim.send(m, from: "C")
        check(sim.inbox["B"]?.filter { $0.id == m.id }.count == 1, "mesh sim: relayed message arrives once although sent twice")
        check(sim.inbox["A"]?.filter { $0.id == m.id }.count == 1, "mesh sim: relay delivers once too")
    }

    // 9. Probe arithmetic.
    do {
        let p = BLEProbeResult(bytes: 4096, mtu: 182, roundTripMs: 1000)
        check(abs(p.bytesPerSecond - 4096) < 0.01, "ble probe: bytes per second")
        check(abs(p.seconds(for: 8192) - 2) < 0.01, "ble probe: time estimate")
        check(BLEProbeResult(bytes: 1, mtu: 20, roundTripMs: 0).seconds(for: 10) == .infinity, "ble probe: zero time is not divided")
    }
}
