// DiscoveryRestartTests.swift: the link layer's restart state machine and debounce, with a fake clock.

import Foundation

func runDiscoveryRestartTests() {
    let t0 = Date(timeIntervalSince1970: 1_791_600_000)
    var p = DiscoveryRestartPolicy()

    check(p.request(.wake, now: t0) == .none && p.restartCount == 0, "no restart before the transport starts")
    check(p.begin(now: t0) && p.phase == .running, "begin: idle -> running")
    check(!p.begin(now: t0 + 1), "begin twice is refused (start never runs twice)")

    // Foreground never restarts a running browser.
    check(p.request(.foreground, now: t0 + 60) == .none && p.restartCount == 0 && p.pending == nil, "foreground with the browser running: no restart, no pending")

    // Inside the 15 s gap after start: deferred, not dropped.
    let early = p.request(.wake, now: t0 + 5)
    check(early == .deferUntil(t0 + DiscoveryRestartPolicy.minGap) && p.pending == .wake && p.phase == .running, "request inside the gap is deferred to the end of the gap")
    check(p.request(.stale, now: t0 + 6) == .deferUntil(t0 + 15) && p.pending == .wake, "a second request inside the gap folds into the first pending")

    // Gap over: the deferred request runs as one restart.
    check(p.firePending(now: t0 + 15) == .stop(settle: DiscoveryRestartPolicy.settleDelay) && p.phase == .stopping && p.restartCount == 1, "deferred request becomes one stop with a settle delay")
    check(p.pending == nil, "pending cleared once it runs")

    // While stopping or starting, nothing overlaps.
    check(p.request(.forcedRelay, now: t0 + 15.5) == .none && p.pending == .forcedRelay, "request while stopping does not stop again; it waits")
    check(p.request(.wake, now: t0 + 15.6) == .none && p.restartCount == 1, "still one restart in flight")
    check(p.stopSettled() && p.phase == .starting, "settle over: stopping -> starting")
    check(!p.stopSettled(), "settle cannot fire twice")
    check(p.request(.stale, now: t0 + 16.6) == .none && p.restartCount == 1, "request while starting does not overlap")
    let next = p.started(now: t0 + 16.6)
    check(p.phase == .running && next == t0 + 15 + DiscoveryRestartPolicy.minGap, "started: running again, pending restart scheduled at the next gap end")
    check(p.firePending(now: t0 + 30) == .stop(settle: 1.5) && p.restartCount == 2, "pending restart runs after the gap")
    _ = p.stopSettled()
    check(p.started(now: t0 + 31.5) == nil, "no pending left: nothing scheduled")

    // Restarts are never closer than the gap, however often they are asked for.
    var q = DiscoveryRestartPolicy()
    _ = q.begin(now: t0)
    var stops = 0
    var lastStop: Date?
    var minSpacing = Double.infinity
    for i in 0..<600 {   // a request every second for 10 minutes, with settle handled
        let now = t0 + Double(i)
        if q.phase == .stopping, let ls = lastStop, now.timeIntervalSince(ls) >= 1.5 { _ = q.stopSettled() }
        if q.phase == .starting { _ = q.started(now: now) }
        var action = q.request(i % 2 == 0 ? .stale : .wake, now: now)
        if case .deferUntil(let at) = action, at <= now { action = q.firePending(now: now) }
        if case .stop = action {
            if let ls = lastStop { minSpacing = min(minSpacing, now.timeIntervalSince(ls)) }
            lastStop = now
            stops += 1
        }
    }
    check(minSpacing >= DiscoveryRestartPolicy.minGap, "restarts at least 15 s apart under a request every second")
    check(stops <= 600 / 15 + 1 && stops >= 30, "about one restart per 15 s, not one per request (\(stops))")

    // Shutdown mid-restart: the settle does not start anything.
    var r = DiscoveryRestartPolicy()
    _ = r.begin(now: t0)
    _ = r.request(.wake, now: t0 + 20)
    r.shutdown()
    check(!r.stopSettled() && r.phase == .idle, "shutdown during the settle: no start afterwards")
    check(r.firePending(now: t0 + 60) == .none, "shutdown clears pending")

    // Stale detection.
    var s = DiscoveryRestartPolicy()
    _ = s.begin(now: t0)
    check(!s.isStale(linked: 0, discovered: 0, lastFound: .distantPast, now: t0 + 60), "not stale before 2 minutes")
    check(s.isStale(linked: 0, discovered: 0, lastFound: .distantPast, now: t0 + 121), "stale after 2 minutes with no links and nothing found")
    check(!s.isStale(linked: 1, discovered: 0, lastFound: .distantPast, now: t0 + 500), "a live link is never stale")
    check(!s.isStale(linked: 0, discovered: 1, lastFound: .distantPast, now: t0 + 500), "a found peer is never stale (it gets re-invited instead)")
    check(!s.isStale(linked: 0, discovered: 0, lastFound: t0 + 100, now: t0 + 150), "a recent sighting resets the stale clock")
}
