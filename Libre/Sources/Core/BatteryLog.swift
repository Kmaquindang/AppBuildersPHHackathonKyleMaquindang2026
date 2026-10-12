// BatteryLog.swift
// Libre: battery lines for device tests (issue #7). Our own design. Every 5 minutes, and whenever
// the app moves between foreground and background, a device writes one line to its Bluetooth log
// (iPhone and Mac: ble-log.txt; Android: logcat, tag LibreMesh). scripts/ble_log_summary.py turns
// the lines into start and end battery, drain per hour and links held. Numbers only.

import Foundation

public enum BatteryLog {
    public static let every: TimeInterval = 300

    /// "BAT pct=83 charging=0 links=2 bright=0.50 state=bg os=iOS 26.0 model=iPhone15,3"
    /// (pct -1 when the battery level is unknown, for example on a Mac without a battery).
    public static func line(percent: Int?, charging: Bool, links: Int, brightness: Double?, foreground: Bool, os: String, model: String) -> String {
        let bright = brightness.map { String(format: "%.2f", $0) } ?? "-1"
        return "BAT pct=\(percent ?? -1) charging=\(charging ? 1 : 0) links=\(links) bright=\(bright) state=\(foreground ? "fg" : "bg") os=\(os) model=\(model)"
    }

    /// True when a periodic line is due.
    public static func due(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= every
    }
}
