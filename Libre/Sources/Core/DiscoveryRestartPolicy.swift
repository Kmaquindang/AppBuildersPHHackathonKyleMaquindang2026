// DiscoveryRestartPolicy.swift
// Pasa: when the link layer may stop and restart MultipeerConnectivity advertising and browsing.
// Pure Swift with an injected clock, tested on Linux.
//
// Why: stopping and starting MCNearbyServiceBrowser / MCNearbyServiceAdvertiser in quick
// succession, or from two threads at once, races CFNetService teardown inside the framework and
// crashed the Mac app (Oct 9, 8:37 PM: EXC_BREAKPOINT in _CFAssertMismatchedTypeID under
// CFRunLoopSourceInvalidate / _BrowserCancel while MC's sync queues were still tearing down the
// previous browse). The rules here:
// - One browser and one advertiser for the life of the transport. Restarts reuse them.
// - A state machine (idle, running, stopping, starting): a stop and a start never overlap, and a
//   restart asked for while one is in flight is folded into one pending restart.
// - At least `minGap` seconds between restarts. A request inside the gap is deferred, not dropped.
// - After stop, wait `settleDelay` seconds before start, so the framework finishes tearing down.
// - Coming back to the foreground never restarts a running browser (the caller re-invites the
//   peers it already found). A dropped link never restarts discovery either: the browser keeps
//   running and reports the peer again.
// - Only a stale mesh (no links and nothing discovered for `staleAfter` seconds) or waking from
//   sleep or a forced relay reset asks for a restart.

import Foundation

public struct DiscoveryRestartPolicy: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable { case idle, running, stopping, starting }

    public enum Reason: String, Equatable, Sendable {
        case foreground, wake, stale, forcedRelay
    }

    public enum Action: Equatable, Sendable {
        /// Nothing to do with the browser or advertiser.
        case none
        /// Stop advertising and browsing now, then call `stopSettled` after this many seconds.
        case stop(settle: TimeInterval)
        /// Too soon after the last restart: ask again (`firePending`) at this time.
        case deferUntil(Date)
    }

    public static let minGap: TimeInterval = 15
    public static let settleDelay: TimeInterval = 1.5
    public static let staleAfter: TimeInterval = 120

    public private(set) var phase: Phase = .idle
    public private(set) var lastRestartAt: Date = .distantPast
    /// Restarts actually performed since the transport started (debug counter on the dashboard).
    public private(set) var restartCount = 0
    /// Requests that were folded into another restart or deferred by the gap.
    public private(set) var coalescedCount = 0
    /// A restart asked for during the gap or while a restart was in flight.
    public private(set) var pending: Reason?
    /// Restart a quiet mesh every `staleAfter` seconds. Off on the Mac (QA, Oct 9, 9:35 PM PHT): the
    /// same `_BrowserCancel` crash came back at 9:25 PM on the build with the 8:42 PM fix, after
    /// about 15 minutes alone with no phones linked, which is exactly when stale restarts fire
    /// (about one every 2 minutes). A Mac never suspends Multipeer, so its browser keeps running
    /// and reports phones again on its own; every stop it does not make is one fewer chance to
    /// hit the framework bug. Phones keep it (iOS can silently stop browsing after background).
    public var allowsStaleRestart = true

    public init(allowsStaleRestart: Bool = true) {
        self.allowsStaleRestart = allowsStaleRestart
    }

    /// The browser and advertiser were started for the first time (or after `shutdown`).
    /// Returns false when they are already running (start must not be called twice).
    public mutating func begin(now: Date) -> Bool {
        guard phase == .idle else { return false }
        phase = .running
        lastRestartAt = now
        pending = nil
        return true
    }

    /// The transport is shutting down: forget everything in flight.
    public mutating func shutdown() {
        phase = .idle
        pending = nil
    }

    public mutating func request(_ reason: Reason, now: Date) -> Action {
        switch phase {
        case .idle:
            return .none
        case .stopping, .starting:
            if reason != .foreground { pending = pending ?? reason; coalescedCount += 1 }
            return .none
        case .running:
            // Foreground: the browser is running, so only re-invite (done by the caller).
            if reason == .foreground { return .none }
            let nextAllowed = lastRestartAt.addingTimeInterval(DiscoveryRestartPolicy.minGap)
            if now < nextAllowed {
                if pending == nil { pending = reason }
                coalescedCount += 1
                return .deferUntil(nextAllowed)
            }
            phase = .stopping
            lastRestartAt = now
            restartCount += 1
            pending = nil
            return .stop(settle: DiscoveryRestartPolicy.settleDelay)
        }
    }

    /// The settle delay after a stop is over. True means: start advertising and browsing now,
    /// then call `started`. False means the transport was shut down meanwhile.
    public mutating func stopSettled() -> Bool {
        guard phase == .stopping else { return false }
        phase = .starting
        return true
    }

    /// Advertising and browsing were started again. Returns the time a pending restart may run,
    /// if one is waiting.
    public mutating func started(now: Date) -> Date? {
        guard phase == .starting else { return nil }
        phase = .running
        guard pending != nil else { return nil }
        return lastRestartAt.addingTimeInterval(DiscoveryRestartPolicy.minGap)
    }

    /// A deferred restart's time came. Runs the pending request through the same rules.
    public mutating func firePending(now: Date) -> Action {
        guard let reason = pending, phase == .running else { return .none }
        pending = nil
        return request(reason, now: now)
    }

    /// Stale mesh: running, no links, nothing discovered, and quiet for `staleAfter` seconds
    /// since the last restart and the last sighting.
    public func isStale(linked: Int, discovered: Int, lastFound: Date, now: Date) -> Bool {
        allowsStaleRestart && phase == .running && linked == 0 && discovered == 0
            && now.timeIntervalSince(lastRestartAt) >= DiscoveryRestartPolicy.staleAfter
            && now.timeIntervalSince(lastFound) >= DiscoveryRestartPolicy.staleAfter
    }
}
