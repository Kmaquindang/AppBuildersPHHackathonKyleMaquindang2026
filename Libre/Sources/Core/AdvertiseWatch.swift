// AdvertiseWatch.swift
// Libre: keeps the Bluetooth advertiser (peripheral side) alive (Oct 12, 2026). Pure Swift,
// tested on Linux. Our own design.
//
// The AI Mac acts as a Bluetooth hub: phones find it by its advertisement and connect to it,
// while it also scans and connects out. If the service add or advertising fails, or the system
// stops advertising (radio reset, sleep), the hub silently disappears for phones. The watch is
// checked on the transport's 2 s tick and says when to try again:
// - Radio off: nothing to do (wait for power on).
// - Advertising: healthy, failures reset.
// - Not advertising: retry after a backoff of 2, 4, 8 ... up to 30 s since the last attempt.
//   The hub uses a 1 s first step so phones see it again quickly.

import Foundation

public struct AdvertiseWatch: Sendable {
    public enum Action: Equatable, Sendable { case none, restart }

    public let firstDelay: TimeInterval
    public let maxDelay: TimeInterval
    public private(set) var failures = 0
    public private(set) var lastAttempt: Date?

    public init(isHub: Bool = false, maxDelay: TimeInterval = 30) {
        firstDelay = isHub ? 1 : 2
        self.maxDelay = maxDelay
    }

    /// Delay before the next retry, given the failures so far.
    public var delay: TimeInterval { min(maxDelay, firstDelay * pow(2, Double(max(0, failures - 1)))) }

    /// Call when an attempt (add service + start advertising) begins.
    public mutating func attempted(now: Date = Date()) { lastAttempt = now }
    /// The attempt failed (service add or advertising error).
    public mutating func failed(now: Date = Date()) { failures += 1; lastAttempt = now }
    /// Advertising started.
    public mutating func started() { failures = 0 }

    public mutating func check(poweredOn: Bool, advertising: Bool, now: Date = Date()) -> Action {
        guard poweredOn else { failures = 0; lastAttempt = nil; return .none }
        if advertising { failures = 0; return .none }
        guard let last = lastAttempt else { return .restart }
        let wait = failures == 0 ? firstDelay : delay
        return now.timeIntervalSince(last) >= wait ? .restart : .none
    }
}
