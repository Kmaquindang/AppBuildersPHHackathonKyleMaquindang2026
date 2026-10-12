// AdvertiseWatchTests.swift: advertiser retry and backoff.
import Foundation

func runAdvertiseWatchTests() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var w = AdvertiseWatch()
    check(w.check(poweredOn: false, advertising: false, now: t0) == .none, "advertise watch: radio off waits")
    check(w.check(poweredOn: true, advertising: false, now: t0) == .restart, "advertise watch: never tried restarts")
    w.attempted(now: t0)
    check(w.check(poweredOn: true, advertising: false, now: t0.addingTimeInterval(1)) == .none, "advertise watch: waits first step")
    check(w.check(poweredOn: true, advertising: false, now: t0.addingTimeInterval(2)) == .restart, "advertise watch: retries after 2 s")
    w.failed(now: t0); w.failed(now: t0); w.failed(now: t0)
    check(w.delay == 8, "advertise watch: backoff doubles")
    check(w.check(poweredOn: true, advertising: false, now: t0.addingTimeInterval(7)) == .none, "advertise watch: backoff holds")
    for _ in 0..<10 { w.failed(now: t0) }
    check(w.delay == 30, "advertise watch: backoff capped at 30 s")
    check(w.check(poweredOn: true, advertising: true, now: t0) == .none && w.failures == 0, "advertise watch: advertising resets")
    var hub = AdvertiseWatch(isHub: true)
    hub.attempted(now: t0)
    check(hub.check(poweredOn: true, advertising: false, now: t0.addingTimeInterval(1)) == .restart, "advertise watch: hub retries after 1 s")
}
