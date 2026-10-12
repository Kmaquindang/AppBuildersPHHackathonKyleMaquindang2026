// BatteryLogTests.swift: battery log lines for device tests (issue #7). Same cases as BatteryLogTest.kt.
import Foundation

func runBatteryLogTests() {
    check(BatteryLog.line(percent: 83, charging: false, links: 2, brightness: 0.5, foreground: false, os: "iOS 26.0", model: "iPhone15,3")
          == "BAT pct=83 charging=0 links=2 bright=0.50 state=bg os=iOS 26.0 model=iPhone15,3", "battery log: line format")
    check(BatteryLog.line(percent: nil, charging: true, links: 0, brightness: nil, foreground: true, os: "macOS 26.3", model: "Mac")
          == "BAT pct=-1 charging=1 links=0 bright=-1 state=fg os=macOS 26.3 model=Mac", "battery log: unknown level and brightness")
    let t0 = Date(timeIntervalSince1970: 1_000)
    check(BatteryLog.due(last: nil, now: t0), "battery log: first line due at once")
    check(!BatteryLog.due(last: t0, now: t0.addingTimeInterval(299)) && BatteryLog.due(last: t0, now: t0.addingTimeInterval(300)), "battery log: every 5 minutes")
}
