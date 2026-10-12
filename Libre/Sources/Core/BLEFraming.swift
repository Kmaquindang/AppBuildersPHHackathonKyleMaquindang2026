// BLEFraming.swift
// Libre: Bluetooth Low Energy link framing (Oct 11, 2026). Pure Swift, tested on Linux.
//
// MultipeerConnectivity needs the Wi-Fi radio. With Wi-Fi switched off, Libre still links over
// CoreBluetooth (BLETransport). A BLE write or notification carries at most a few hundred bytes
// (the negotiated MTU minus headers), so every encoded MeshMessage is cut into frames:
//
//   byte 0      magic 0x4C ("L")
//   byte 1      version (2 since the signed hello, Oct 12, 2026)
//   byte 2      type: 0 data, 1 signed hello (BLEHandshake), 2 probe (speed test), 3 probe reply, 4 proof
//   bytes 3-6   message id (UInt32, big endian, per sender)
//   bytes 7-8   chunk index (UInt16)
//   bytes 9-10  chunk count (UInt16)
//   bytes 11..  payload
//
// BLE is just another link: the reassembled bytes are the same sealed MeshMessage packets that
// travel over Wi-Fi, so room encryption, relay hops and duplicate suppression (RelayEngine) are
// unchanged.

import Foundation

public enum LinkKind: String, Codable, Sendable {
    case wifi
    case bluetooth

    /// "via Bluetooth" / "via Wi-Fi" for the Details sheet.
    public var via: String { self == .bluetooth ? "via Bluetooth" : "via Wi-Fi (peer to peer)" }
}

public enum BLEFrameType: UInt8, Sendable {
    case data = 0
    case hello = 1
    case probe = 2
    case probeReply = 3
    case proof = 4
}

public struct BLEFrame: Equatable, Sendable {
    public static let magic: UInt8 = 0x4C
    public static let version: UInt8 = 2   // 2 = signed hello + proof (Oct 12, 2026); version 1 frames are ignored
    public static let headerSize = 11
    /// The smallest ATT payload a BLE link allows (default MTU 23 minus 3).
    public static let minimumMTU = 20

    public var type: BLEFrameType
    public var messageID: UInt32
    public var index: UInt16
    public var count: UInt16
    public var payload: Data

    public init(type: BLEFrameType, messageID: UInt32, index: UInt16, count: UInt16, payload: Data) {
        self.type = type
        self.messageID = messageID
        self.index = index
        self.count = count
        self.payload = payload
    }

    public func encoded() -> Data {
        var d = Data([BLEFrame.magic, BLEFrame.version, type.rawValue])
        d.append(contentsOf: withUnsafeBytes(of: messageID.bigEndian, Array.init))
        d.append(contentsOf: withUnsafeBytes(of: index.bigEndian, Array.init))
        d.append(contentsOf: withUnsafeBytes(of: count.bigEndian, Array.init))
        d.append(payload)
        return d
    }

    /// nil for anything that is not a well-formed Libre frame (wrong magic or version, short,
    /// unknown type, index out of range, zero count).
    public static func decode(_ raw: Data) -> BLEFrame? {
        let b = [UInt8](raw)
        guard b.count >= headerSize, b[0] == magic, b[1] == version, let type = BLEFrameType(rawValue: b[2]) else { return nil }
        let id = b[3..<7].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let index = (UInt16(b[7]) << 8) | UInt16(b[8])
        let count = (UInt16(b[9]) << 8) | UInt16(b[10])
        guard count > 0, index < count else { return nil }
        return BLEFrame(type: type, messageID: id, index: index, count: count, payload: Data(b[headerSize...]))
    }
}

public enum BLEChunker {
    /// Largest message accepted over BLE. Media packets are 12 KB chunks (about 17 KB sealed), so
    /// this leaves room; anything bigger is refused rather than tying up the radio for minutes.
    public static let maxMessageBytes = 256 * 1024

    /// Payload bytes per frame for a link whose largest single write is `mtu` bytes.
    public static func payloadSize(mtu: Int) -> Int {
        max(BLEFrame.minimumMTU, mtu) - BLEFrame.headerSize
    }

    /// Cuts `data` into frames that each fit in `mtu` bytes. Empty data gives one empty frame.
    /// nil when the message is too big for BLE (over maxMessageBytes or over 65,535 frames).
    public static func frames(_ data: Data, type: BLEFrameType = .data, messageID: UInt32, mtu: Int) -> [Data]? {
        guard data.count <= maxMessageBytes else { return nil }
        let size = payloadSize(mtu: mtu)
        let count = max(1, (data.count + size - 1) / size)
        guard count <= Int(UInt16.max) else { return nil }
        let bytes = [UInt8](data)
        return (0..<count).map { i in
            let start = i * size
            let end = min(bytes.count, start + size)
            let part = start < end ? Data(bytes[start..<end]) : Data()
            return BLEFrame(type: type, messageID: messageID, index: UInt16(i), count: UInt16(count), payload: part).encoded()
        }
    }
}

/// Puts frames back together per link and message id. Frames of one message may arrive with
/// other messages' frames in between. Duplicated frames are ignored; a message that stops
/// arriving is dropped after `timeout`; memory per link is capped.
public struct BLEReassembler: Sendable {
    public struct Complete: Equatable, Sendable {
        public var type: BLEFrameType
        public var messageID: UInt32
        public var data: Data
    }

    struct Partial: Sendable {
        var type: BLEFrameType
        var count: UInt16
        var parts: [UInt16: Data]
        var bytes: Int
        var updated: Date
    }

    public static let timeout: TimeInterval = 60
    /// Bytes buffered per link before the oldest partial message is dropped.
    public static let maxBufferedBytes = 2 * BLEChunker.maxMessageBytes

    private var partials: [String: [UInt32: Partial]] = [:]
    /// Recently completed (link, id) pairs, so a re-sent frame of a finished message is ignored.
    private var finished: [String: [UInt32: Date]] = [:]
    public private(set) var droppedCount = 0

    public init() {}

    /// Feeds one raw frame from `link`. Returns the whole message when its last frame arrives.
    public mutating func add(_ raw: Data, link: String, now: Date = Date()) -> Complete? {
        expire(now: now)
        guard let frame = BLEFrame.decode(raw) else { droppedCount += 1; return nil }
        if finished[link]?[frame.messageID] != nil { return nil }
        if frame.count == 1 {
            markFinished(link, frame.messageID, now: now)
            return Complete(type: frame.type, messageID: frame.messageID, data: frame.payload)
        }
        var forLink = partials[link] ?? [:]
        var p = forLink[frame.messageID] ?? Partial(type: frame.type, count: frame.count, parts: [:], bytes: 0, updated: now)
        // A frame that disagrees with the first one (count or type) means a reused id: start over.
        if p.count != frame.count || p.type != frame.type {
            droppedCount += 1
            p = Partial(type: frame.type, count: frame.count, parts: [:], bytes: 0, updated: now)
        }
        if p.parts[frame.index] == nil {
            p.parts[frame.index] = frame.payload
            p.bytes += frame.payload.count
        }
        p.updated = now
        if p.parts.count == Int(p.count) {
            var out = Data()
            for i in 0..<p.count { out.append(p.parts[i] ?? Data()) }
            forLink.removeValue(forKey: frame.messageID)
            partials[link] = forLink
            markFinished(link, frame.messageID, now: now)
            return Complete(type: p.type, messageID: frame.messageID, data: out)
        }
        forLink[frame.messageID] = p
        // Memory cap: drop the oldest partial messages of this link.
        while forLink.values.reduce(0, { $0 + $1.bytes }) > BLEReassembler.maxBufferedBytes,
              let oldest = forLink.min(by: { $0.value.updated < $1.value.updated })?.key {
            forLink.removeValue(forKey: oldest)
            droppedCount += 1
        }
        partials[link] = forLink
        return nil
    }

    /// Forget a link (it disconnected).
    public mutating func reset(link: String) {
        partials.removeValue(forKey: link)
        finished.removeValue(forKey: link)
    }

    public func pendingCount(link: String) -> Int { partials[link]?.count ?? 0 }

    private mutating func markFinished(_ link: String, _ id: UInt32, now: Date) {
        var f = finished[link] ?? [:]
        f[id] = now
        if f.count > 512 { f = f.filter { now.timeIntervalSince($0.value) < BLEReassembler.timeout } }
        finished[link] = f
    }

    private mutating func expire(now: Date) {
        for (link, forLink) in partials {
            let kept = forLink.filter { now.timeIntervalSince($0.value.updated) < BLEReassembler.timeout }
            droppedCount += forLink.count - kept.count
            partials[link] = kept
        }
        for (link, f) in finished {
            finished[link] = f.filter { now.timeIntervalSince($0.value) < BLEReassembler.timeout }
        }
    }
}

/// Which link carries a packet to which peer when both Wi-Fi (MultipeerConnectivity) and
/// Bluetooth may reach it. Wi-Fi is preferred: it is about 100 times faster.
public enum LinkRouter {
    public struct Plan: Equatable, Sendable {
        public var wifi: [String]
        public var bluetooth: [String]
        /// Bluetooth peers skipped because the packet is too big for BLE.
        public var tooBigForBluetooth: [String]
        /// Bluetooth-only peers skipped because media waits for Wi-Fi (BLEPriority).
        public var heldForWifi: [String] = []
        public var all: [String] { (wifi + bluetooth).sorted() }
    }

    /// `lane` defaults to the lane for an unknown packet of `bytes` (BLELane.of).
    public static func plan(wifi: Set<String>, bluetooth: Set<String>, blocked: Set<String>, excluding: Set<String>,
                            bytes: Int, bluetoothLimit: Int = BLEChunker.maxMessageBytes,
                            lane: BLELane? = nil, mediaOverBluetooth: Bool = false) -> Plan {
        let wifiTargets = wifi.subtracting(blocked).subtracting(excluding)
        let bleOnly = bluetooth.subtracting(wifi).subtracting(blocked).subtracting(excluding)
        let fits = bytes <= bluetoothLimit
        guard fits else { return Plan(wifi: wifiTargets.sorted(), bluetooth: [], tooBigForBluetooth: bleOnly.sorted()) }
        let l = lane ?? BLELane.of(kind: nil, bytes: bytes)
        if !l.allowedOnBluetoothOnly(mediaOverBluetooth: mediaOverBluetooth) {
            return Plan(wifi: wifiTargets.sorted(), bluetooth: [], tooBigForBluetooth: [], heldForWifi: bleOnly.sorted())
        }
        return Plan(wifi: wifiTargets.sorted(), bluetooth: bleOnly.sorted(), tooBigForBluetooth: [])
    }

    /// One state per peer across both links: connected if either link is connected.
    public static func merged(_ a: String?, _ b: String?) -> String? {
        let order = ["connected", "connecting", "discovered", "disconnected"]
        let states = [a, b].compactMap { $0 }
        return states.min { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
    }
}

/// Speed test numbers from one BLE probe: a `bytes`-long probe answered by a short reply.
public struct BLEProbeResult: Equatable, Sendable {
    public var bytes: Int
    public var mtu: Int
    public var roundTripMs: Int

    public init(bytes: Int, mtu: Int, roundTripMs: Int) {
        self.bytes = bytes
        self.mtu = mtu
        self.roundTripMs = roundTripMs
    }

    /// Bytes per second one way (the reply is tiny, so the round trip is mostly the probe).
    public var bytesPerSecond: Double { roundTripMs > 0 ? Double(bytes) * 1000 / Double(roundTripMs) : 0 }

    /// Rough seconds to move `bytes` at this speed.
    public func seconds(for bytes: Int) -> Double { bytesPerSecond > 0 ? Double(bytes) / bytesPerSecond : .infinity }
}
