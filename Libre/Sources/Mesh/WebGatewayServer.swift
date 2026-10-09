// WebGatewayServer.swift (macOS only)
// The browser gateway listener: plain HTTP on the local network, off by default. One request
// per connection (Connection: close); the page polls every 1.5 s. Parsing, auth, rate limits and
// routing live in Core/WebGateway.swift (tested on Linux). This file only moves bytes.
// iPhone MultipeerConnectivity is untouched: web members reach the room through the Mac.

#if os(macOS)
import Foundation
import Network
import Darwin

@MainActor
final class WebGatewayServer {
    let router: GatewayRouter
    private var listener: NWListener?
    private var open = 0
    private(set) var port: UInt16 = 0
    var onChange: ((UInt16?, String?) -> Void)?

    static let maxConnections = 64
    static let readLimit = HTTPRequest.maxHeaderBytes + HTTPRequest.maxBodyBytes

    init(backend: GatewayBackend) {
        router = GatewayRouter(backend: backend)
    }

    var isRunning: Bool { listener != nil }

    func start(preferred: UInt16 = GatewayNet.defaultPort) {
        stop()
        listen(on: NWEndpoint.Port(rawValue: preferred) ?? .any, fallback: true)
    }

    private func listen(on port: NWEndpoint.Port, fallback: Bool) {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true                 // local network peers only
        params.prohibitedInterfaceTypes = [.cellular]
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do { l = try NWListener(using: params, on: port) } catch {
            NSLog("Pasa browser gateway: could not open port: %@", "\(error)")
            if fallback { listen(on: .any, fallback: false) } else { onChange?(nil, "Could not open the browser gateway: \(error.localizedDescription)") }
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            Task { @MainActor in
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready:
                    self.port = l.port?.rawValue ?? 0
                    NSLog("Pasa browser gateway: listening on port %d", Int(self.port))
                    self.onChange?(self.port, nil)
                case .failed(let error):
                    NSLog("Pasa browser gateway: listener failed: %@", "\(error)")
                    l.cancel()
                    self.listener = nil
                    if fallback { self.listen(on: .any, fallback: false) }
                    else { self.onChange?(nil, "Browser gateway stopped: \(error.localizedDescription)") }
                default: break
                }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        listener = l
        l.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        router.sessions.endAll()
    }

    private func accept(_ conn: NWConnection) {
        guard open < WebGatewayServer.maxConnections, case .hostPort(let host, _) = conn.endpoint else { conn.cancel(); return }
        let address = WebGatewayServer.plain(host)
        guard GatewayNet.isLocal(address) else { NSLog("Pasa browser gateway: refused %@", address); conn.cancel(); return }
        open += 1
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: Task { @MainActor in self?.open -= 1 }
            default: break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { conn.cancel() }   // slow or idle clients
        read(conn, buffer: Data(), address: address)
    }

    private func read(_ conn: NWConnection, buffer: Data, address: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if error != nil { conn.cancel(); return }
                if buf.count > WebGatewayServer.readLimit { self.reply(conn, .error(413, "Too large.")); return }
                switch HTTPRequest.parse(buf) {
                case .incomplete:
                    if done { conn.cancel() } else { self.read(conn, buffer: buf, address: address) }
                case .bad:
                    self.reply(conn, .error(400, "Bad request."))
                case .ok(let request, _):
                    let response = await self.router.handle(request, from: address)
                    self.reply(conn, response)
                }
            }
        }
    }

    private func reply(_ conn: NWConnection, _ response: HTTPResponse) {
        conn.send(content: response.data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// "192.168.1.5" or "fe80::1%en0" from an endpoint host (no extra quoting).
    static func plain(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }

    /// The Mac's address on the local network (Wi-Fi or Ethernet first), for the browser QR.
    static func localAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var found: [(String, String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    let name = String(cString: p.pointee.ifa_name)
                    if GatewayNet.isLocal(ip), !ip.hasPrefix("169.254.") { found.append((name, ip)) }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return (found.first { $0.0.hasPrefix("en") } ?? found.first { $0.0.hasPrefix("bridge") } ?? found.first)?.1
    }
}
#endif
