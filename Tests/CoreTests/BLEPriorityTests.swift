// BLEPriorityTests.swift: lanes, frame-level priority, media held for Wi-Fi on Bluetooth-only links.
import Foundation

func runBLEPriorityTests() {
    // Lanes by kind.
    check(BLELane.of(kind: .chat, bytes: 900) == .urgent && BLELane.of(kind: .ask, bytes: 10) == .urgent && BLELane.of(kind: .answer, bytes: 3000) == .urgent,
          "ble lane: chat, asks and answers are urgent")
    check(BLELane.of(kind: .task, bytes: 1) == .urgent && BLELane.of(kind: .rule, bytes: 1) == .urgent, "ble lane: tasks and rules are urgent")
    check(BLELane.of(kind: .sync, bytes: 50_000) == .bulk && BLELane.of(kind: .transcript, bytes: 1) == .bulk, "ble lane: backfill and transcripts are bulk")
    check(BLELane.of(kind: .chunk, bytes: 17_000) == .media && BLELane.of(kind: .media, bytes: 600) == .media, "ble lane: photo and voice pieces are media")
    check(BLELane.of(kind: .sealed, bytes: 2_000) == .urgent && BLELane.of(kind: nil, bytes: 17_000) == .media, "ble lane: unknown sealed packets go by size (over 8 KB is media)")

    // Frame-level priority: a text queued behind a photo leaves first.
    var q = BLESendQueue()
    let photo = (0..<50).map { Data([0xEE, UInt8($0)]) }
    check(q.push(photo, lane: .media), "ble queue: photo frames accepted")
    _ = q.pop(); _ = q.pop()   // two photo frames already on air
    q.push([Data([0x01]), Data([0x02])], lane: .urgent)
    q.push([Data([0x0C])], lane: .control)
    check(q.pop() == Data([0x0C]), "ble queue: control (hello, proof) goes first")
    check(q.pop() == Data([0x01]) && q.pop() == Data([0x02]), "ble queue: the text jumps ahead of the photo's remaining frames")
    check(q.pop() == Data([0xEE, 2]), "ble queue: the photo resumes where it stopped")
    check(q.count == 47 && q.count(.media) == 47, "ble queue: counts per lane")
    q.push([Data([0x0B])], lane: .bulk)
    check(q.peek() == Data([0x0B]), "ble queue: backfill goes before media")
    var big = BLESendQueue()
    check(big.push(Array(repeating: Data([1]), count: 3000), lane: .media), "ble queue: media lane takes up to 3000 frames")
    check(!big.push([Data([1])], lane: .media), "ble queue: media lane cap keeps room for text")
    check(big.push(Array(repeating: Data([2]), count: 3000), lane: .urgent), "ble queue: text still fits when media is full")
    check(!big.push([Data([3])], lane: .urgent), "ble queue: the whole queue caps at 6000 frames")
    check(big.push([Data([4])], lane: .control), "ble queue: control frames are always accepted")
    var drain = BLESendQueue()
    drain.push((0..<1000).map { Data([UInt8($0 % 256)]) }, lane: .urgent)
    var n = 0
    while drain.pop() != nil { n += 1 }
    check(n == 1000 && drain.isEmpty, "ble queue: drains in order with compaction")

    // Bluetooth-only scope: media waits for Wi-Fi by default.
    let held = LinkRouter.plan(wifi: ["Mac"], bluetooth: ["Mac", "iPhone 12"], blocked: [], excluding: [], bytes: 17_000, lane: .media)
    check(held.wifi == ["Mac"] && held.bluetooth.isEmpty && held.heldForWifi == ["iPhone 12"], "ble scope: a photo piece goes over Wi-Fi only; the Bluetooth-only phone waits")
    let on = LinkRouter.plan(wifi: [], bluetooth: ["iPhone 12"], blocked: [], excluding: [], bytes: 17_000, lane: .media, mediaOverBluetooth: true)
    check(on.bluetooth == ["iPhone 12"] && on.heldForWifi.isEmpty, "ble scope: the setting turns media over Bluetooth back on")
    let text = LinkRouter.plan(wifi: [], bluetooth: ["iPhone 12"], blocked: [], excluding: [], bytes: 1_500, lane: .urgent)
    check(text.bluetooth == ["iPhone 12"], "ble scope: text, answers and tasks always go over Bluetooth")
    let unknownBig = LinkRouter.plan(wifi: [], bluetooth: ["iPhone 12"], blocked: [], excluding: [], bytes: 20_000)
    check(unknownBig.heldForWifi == ["iPhone 12"], "ble scope: an unknown packet over 8 KB is treated as media")
    check(BLELane.urgent.allowedOnBluetoothOnly(mediaOverBluetooth: false) && !BLELane.media.allowedOnBluetoothOnly(mediaOverBluetooth: false),
          "ble scope: only the media lane is held")
}
