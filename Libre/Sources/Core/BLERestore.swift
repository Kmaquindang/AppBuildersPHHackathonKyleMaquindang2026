// BLERestore.swift
// Libre: what to do with the Bluetooth links iOS hands back after it relaunched Libre in the
// background (state restoration, issue #5). Our own design. Pure, tested on Linux.
//
// iOS keeps a background app's Bluetooth connections alive and, when it ended the app to free
// memory, relaunches it for the next Bluetooth event and passes the peripherals it was connected or
// connecting to. BLETransport waits until the radio is on, then follows this plan:
// - adopt: still connected. Find the Libre service again, subscribe, and redo the signed hello
//   (verified state and send queues lived in memory and are gone; the outbox is on disk).
// - reconnect: connecting or dropped. Hand to the connect queue (cap, backoff, timeouts).
// - cancel: connected, but over the link cap once links already open on our own service count.

import Foundation

public enum BLERestore {
    public enum State: Sendable { case connected, connecting, disconnected }

    public struct Plan: Equatable, Sendable {
        public var adopt: [String] = []
        public var reconnect: [String] = []
        public var cancel: [String] = []
    }

    /// - Parameters:
    ///   - restored: peripheral id and its state, as iOS restored them.
    ///   - openLinks: links already open the other way (centrals subscribed to our service).
    ///   - cap: most links this device holds (BLEConnectPolicy.Config.maxLinks).
    public static func plan(_ restored: [(id: String, state: State)], openLinks: Int, cap: Int) -> Plan {
        var plan = Plan()
        var room = max(0, cap - openLinks)
        for item in restored.sorted(by: { $0.id < $1.id }) {
            switch item.state {
            case .connected:
                if room > 0 { plan.adopt.append(item.id); room -= 1 } else { plan.cancel.append(item.id) }
            case .connecting, .disconnected:
                plan.reconnect.append(item.id)
            }
        }
        return plan
    }
}
