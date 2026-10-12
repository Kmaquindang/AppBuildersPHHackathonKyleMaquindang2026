// BLEPriority.swift
// Libre: what goes first on a Bluetooth link, and what waits for Wi-Fi (Oct 12, 2026).
// Pure Swift, tested on Linux. Our own design.
//
// A Bluetooth LE link moves a few KB per second, so one photo can hold a link for a minute.
// Frames now leave in lanes, highest first, at frame granularity (a text that arrives while a
// photo is going out is sent before the photo's remaining frames; the reassembler already
// handles frames of different messages interleaved):
//   control  hello, proof, probe reply
//   urgent   chat, @libre asks and answers, tasks, rules, room control, beacons, AI status
//   bulk     timeline backfill (sync), voice note transcripts
//   media    photo and voice pieces and their manifests, speed probes, anything unknown over 8 KB
// Bluetooth-only scope: by default photos and voice notes are NOT sent to a device reached only
// over Bluetooth (no Wi-Fi link to it). They wait for Wi-Fi. Text, @libre answers and tasks
// always go. A setting turns media over Bluetooth back on.

import Foundation

public enum BLELane: Int, Comparable, CaseIterable, Sendable {
    case control = 0, urgent = 1, bulk = 2, media = 3

    public static func < (a: BLELane, b: BLELane) -> Bool { a.rawValue < b.rawValue }

    /// Packets above this size with no known kind are treated as media.
    public static let unknownMediaBytes = 8 * 1024

    /// Lane for a message of `kind` (the inner kind when known) that encodes to `bytes`.
    public static func of(kind: MessageKind?, bytes: Int) -> BLELane {
        switch kind {
        case .chat?, .ask?, .answer?, .answerPart?, .ack?, .task?, .rule?, .roomControl?, .beacon?, .aiStatus?:
            return .urgent
        case .sync?, .transcript?:
            return .bulk
        case .media?, .chunk?, .mediaNack?:
            return .media
        case .sealed?, nil:
            return bytes > unknownMediaBytes ? .media : .urgent
        }
    }

    /// Bluetooth-only scope: may this lane go to a peer reached only over Bluetooth?
    public func allowedOnBluetoothOnly(mediaOverBluetooth: Bool) -> Bool {
        self != .media || mediaOverBluetooth
    }
}

/// Frames waiting on one link, per lane. `pop` always takes the highest lane first.
public struct BLESendQueue: Sendable {
    /// Frames allowed per link in total, and for the media lane alone (so media cannot fill the
    /// queue and push out text).
    public static let maxFrames = 6000
    public static let maxMediaFrames = 3000

    private var lanes: [[Data]] = Array(repeating: [], count: BLELane.allCases.count)
    private var heads: [Int] = Array(repeating: 0, count: BLELane.allCases.count)

    public init() {}

    public var count: Int { (0..<lanes.count).reduce(0) { $0 + lanes[$1].count - heads[$1] } }
    public var isEmpty: Bool { count == 0 }
    public func count(_ lane: BLELane) -> Int { lanes[lane.rawValue].count - heads[lane.rawValue] }

    /// Adds one message's frames. Returns false (nothing added) when the queue or the media lane
    /// is full; control frames are always accepted.
    @discardableResult
    public mutating func push(_ frames: [Data], lane: BLELane) -> Bool {
        if lane != .control {
            if count + frames.count > BLESendQueue.maxFrames { return false }
            if lane == .media && count(.media) + frames.count > BLESendQueue.maxMediaFrames { return false }
        }
        lanes[lane.rawValue].append(contentsOf: frames)
        return true
    }

    public func peek() -> Data? {
        for i in 0..<lanes.count where heads[i] < lanes[i].count { return lanes[i][heads[i]] }
        return nil
    }

    @discardableResult
    public mutating func pop() -> Data? {
        for i in 0..<lanes.count where heads[i] < lanes[i].count {
            let f = lanes[i][heads[i]]
            heads[i] += 1
            if heads[i] > 256 && heads[i] * 2 > lanes[i].count {
                lanes[i].removeFirst(heads[i]); heads[i] = 0
            }
            return f
        }
        return nil
    }

    public mutating func removeAll() {
        lanes = Array(repeating: [], count: BLELane.allCases.count)
        heads = Array(repeating: 0, count: BLELane.allCases.count)
    }
}
