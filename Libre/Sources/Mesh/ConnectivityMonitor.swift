// ConnectivityMonitor.swift
// Pasa (Mac AI peer): watches whether the Mac has an internet route, with Apple's NWPathMonitor.
// It only listens to the system's network path updates; it never sends anything out (no ping,
// no request). Peer-to-peer Wi-Fi (AWDL) and loopback do not count as internet.

import Foundation
import Network

final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "pasa.path-monitor", qos: .utility)

    init(onChange: @escaping @Sendable (InternetState) -> Void) {
        monitor.pathUpdateHandler = { path in
            let real = path.availableInterfaces.filter { [.wifi, .wiredEthernet, .cellular].contains($0.type) }.count
            onChange(InternetState.from(satisfied: path.status == .satisfied, realInterfaces: real))
        }
        monitor.start(queue: queue)
    }

    func cancel() { monitor.cancel() }
}
