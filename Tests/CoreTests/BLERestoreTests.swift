// BLERestoreTests.swift: Bluetooth state restoration plan (issue #5).
import Foundation

func runBLERestoreTests() {
    let none = BLERestore.plan([], openLinks: 0, cap: 7)
    check(none == BLERestore.Plan(), "restore: nothing restored, nothing to do")

    let mixed = BLERestore.plan([(id: "C", state: .connecting), (id: "A", state: .connected), (id: "B", state: .disconnected)], openLinks: 0, cap: 7)
    check(mixed.adopt == ["A"] && mixed.reconnect == ["B", "C"] && mixed.cancel.isEmpty, "restore: connected adopted, others go to the connect queue")

    let full = BLERestore.plan([(id: "P1", state: .connected), (id: "P2", state: .connected), (id: "P3", state: .connected)], openLinks: 5, cap: 7)
    check(full.adopt == ["P1", "P2"] && full.cancel == ["P3"], "restore: links over the cap are cancelled, counting links open the other way")

    let over = BLERestore.plan([(id: "P1", state: .connected), (id: "P2", state: .connecting)], openLinks: 9, cap: 7)
    check(over.adopt.isEmpty && over.cancel == ["P1"] && over.reconnect == ["P2"], "restore: already over the cap adopts nothing; pending connects wait in the queue")

    let hub = BLERestore.plan((0..<12).map { (id: String(format: "H%02d", $0), state: BLERestore.State.connected) }, openLinks: 0,
                              cap: BLEConnectPolicy.Config.hub.maxLinks)
    check(hub.adopt.count == 12 && hub.cancel.isEmpty, "restore: the hub keeps up to 12")
}
