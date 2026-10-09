// WebGateway.swift
// Pasa browser gateway (Kyle, Oct 9 2026, 10:46 PM PHT): the AI Mac serves a small web chat on the
// local network so Android phones (or any browser) can join a room. Pure Swift, tested on Linux.
// The Mac app runs the listener (Mesh/WebGatewayServer.swift) and bridges web members into the
// room as relayed members ("Ana (via Mac)"). This file holds everything that can be tested
// without a network: HTTP parsing and responses, the join check (same code key derivation as the
// app), sessions, rate limits, LAN address checks, links and the router.
//
// Security model (disclosed in the UI and README):
// - Off by default. Plain HTTP on the local network only (private, link-local and loopback
//   addresses; anything else is refused).
// - Joining a code room needs the room name and code, checked against the signed manifest
//   (PBKDF2 code key, HMAC check, expiry). Town Square needs no code (it is open anyway).
// - After the check the browser gets a random session token (sent as a header, not in the URL).
//   "New code" ends every web session of that room.
// - Joins are rate limited per address and overall; sends are rate limited per session.
// - Plain HTTP: anyone on the same Wi-Fi who captures traffic can read a web member's chat.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: HTTP

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]   // lowercased names
    public var body: Data

    public enum Parse: Equatable { case incomplete, bad(String), ok(HTTPRequest, consumed: Int) }

    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 16 * 1024

    /// Parses one request from the start of `data`.
    public static func parse(_ data: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .bad("headers too large") : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .bad("bad headers")
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .bad("bad request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .bad("bad header") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBodyBytes else { return .bad("body too large") }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        let target = String(start[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = decode(String(kv[0]))
                query[key] = kv.count == 2 ? decode(String(kv[1])) : ""
            }
        }
        return .ok(HTTPRequest(method: String(start[0]).uppercased(), path: path, query: query, headers: headers, body: Data(body)),
                   consumed: data.distance(from: data.startIndex, to: bodyStart) + length)
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    public var bearer: String? {
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var extraHeaders: [(String, String)] = []

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool { a.status == b.status && a.contentType == b.contentType && a.body == b.body }

    public init(status: Int, contentType: String = "text/plain; charset=utf-8", body: Data = Data(), extraHeaders: [(String, String)] = []) {
        self.status = status; self.contentType = contentType; self.body = body; self.extraHeaders = extraHeaders
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    public static func error(_ status: Int, _ message: String, retryAfter: Int? = nil) -> HTTPResponse {
        var r = json(["error": message], status: status)
        if let retryAfter { r.extraHeaders.append(("Retry-After", String(retryAfter))) }
        return r
    }

    static let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests", 503: "Service Unavailable"]

    public var data: Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "Status")\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        // Everything is bundled: the page may load nothing from anywhere else.
        head += "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: Network checks and links

public enum GatewayNet {
    public static let defaultPort: UInt16 = 8787

    /// Local network only: private IPv4 (10/8, 172.16/12, 192.168/16), link-local, loopback, and
    /// IPv6 link-local, unique local and loopback. Everything else is refused.
    public static func isLocal(_ address: String) -> Bool {
        var a = address.lowercased()
        if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
        if a.hasPrefix("::ffff:") { a = String(a.dropFirst(7)) }
        let parts = a.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, a.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if a == "::1" { return true }
        if a.hasPrefix("fe8") || a.hasPrefix("fe9") || a.hasPrefix("fea") || a.hasPrefix("feb") { return true }
        if a.hasPrefix("fc") || a.hasPrefix("fd") { return true }
        return false
    }

    /// The browser QR: http://<ip>:<port>/join?room=<name>. Never carries the code.
    public static func joinURL(host: String, port: UInt16, room: String) -> String {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = Int(port)
        c.path = "/join"
        c.queryItems = [URLQueryItem(name: "room", value: room)]
        return c.string ?? "http://\(host):\(port)/join"
    }

    /// Room name from a browser QR (http://<local ip>:<port>/join?room=X), for the app's scanner.
    public static func roomFromJoinURL(_ text: String) -> String? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "http", let host = c.host, isLocal(host), c.path == "/join",
              let room = c.queryItems?.first(where: { $0.name == "room" })?.value else { return nil }
        let clean = Room.cleanLabel(room)
        return clean.isEmpty ? nil : clean
    }

    /// "Open in Libre app" button on the page: room only; the code is typed in the app.
    public static func appURL(room: String) -> String {
        var c = URLComponents()
        c.scheme = JoinLink.scheme
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "room", value: room), URLQueryItem(name: "v", value: String(JoinLink.version))]
        return c.string ?? "libre://join"
    }
}

// MARK: Rate limits

/// Sliding one-minute windows: joins per address, joins overall, sends per session.
public struct GatewayLimiter: Sendable {
    public var perAddressJoins = 5
    public var totalJoins = 30
    public var perSessionSends = 20
    public var window: TimeInterval = 60

    private var joins: [String: [Date]] = [:]
    private var allJoins: [Date] = []
    private var sends: [String: [Date]] = [:]

    public init() {}

    /// Seconds to wait, or nil when the join attempt may go ahead (and is counted).
    public mutating func allowJoin(from address: String, now: Date = Date()) -> Int? {
        let cut = now.addingTimeInterval(-window)
        allJoins.removeAll { $0 <= cut }
        var mine = (joins[address] ?? []).filter { $0 > cut }
        if mine.count >= perAddressJoins { joins[address] = mine; return wait(mine, now) }
        if allJoins.count >= totalJoins { return wait(allJoins, now) }
        mine.append(now); joins[address] = mine; allJoins.append(now)
        return nil
    }

    public mutating func allowSend(session: String, now: Date = Date()) -> Int? {
        let cut = now.addingTimeInterval(-window)
        var mine = (sends[session] ?? []).filter { $0 > cut }
        if mine.count >= perSessionSends { sends[session] = mine; return wait(mine, now) }
        mine.append(now); sends[session] = mine
        return nil
    }

    private func wait(_ times: [Date], _ now: Date) -> Int {
        max(1, Int((times.min()!.addingTimeInterval(window).timeIntervalSince(now)).rounded(.up)))
    }
}

// MARK: Sessions

public struct GatewaySession: Equatable, Sendable {
    public var token: String
    public var roomID: String
    public var name: String
    /// Mesh origin for this web member ("web-" + 8 hex), stable for the session.
    public var device: String
    public var address: String
    public var codeEpoch: Int
    public var createdAt: Date
    public var lastSeen: Date

    /// "Ana (via Mac)": how the room sees a web member.
    public var displayName: String { "\(name) (via Mac)" }
}

public struct GatewaySessions: Sendable {
    public static let idleLimit: TimeInterval = 12 * 3600
    public static let maxSessions = 40
    public private(set) var all: [String: GatewaySession] = [:]

    public init() {}

    public static func newToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    public static func cleanName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let kept = trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "<" && $0 != ">" }
        return String(String(String.UnicodeScalarView(kept)).prefix(24))
    }

    public mutating func start(roomID: String, name: String, address: String, codeEpoch: Int, now: Date = Date()) -> GatewaySession? {
        prune(now: now)
        guard all.count < GatewaySessions.maxSessions else { return nil }
        let token = GatewaySessions.newToken()
        let s = GatewaySession(token: token, roomID: roomID, name: name, device: "web-" + String(token.prefix(8)),
                               address: address, codeEpoch: codeEpoch, createdAt: now, lastSeen: now)
        all[token] = s
        return s
    }

    /// The session for a token, still valid for the room's current code epoch (refreshes lastSeen).
    public mutating func check(_ token: String?, codeEpoch: (String) -> Int?, now: Date = Date()) -> GatewaySession? {
        guard let token, var s = all[token] else { return nil }
        guard now.timeIntervalSince(s.lastSeen) < GatewaySessions.idleLimit, let epoch = codeEpoch(s.roomID), epoch == s.codeEpoch else {
            all[token] = nil
            return nil
        }
        s.lastSeen = now
        all[token] = s
        return s
    }

    public mutating func end(_ token: String) { all[token] = nil }
    public mutating func endAll() { all = [:] }
    public mutating func endRoom(_ roomID: String) { all = all.filter { $0.value.roomID != roomID } }
    public mutating func prune(now: Date = Date()) { all = all.filter { now.timeIntervalSince($0.value.lastSeen) < GatewaySessions.idleLimit } }
    public func isWebDevice(_ device: String) -> Bool { all.values.contains { $0.device == device } }
}

// MARK: Join check (same code key derivation as the app)

public enum GatewayJoinCheck {
    public enum Result: Equatable { case ok, wrongCode, expired, noCodeRoom }

    /// The code is right when HMAC(codeKey(name, code), "admin|" + adminKey) equals the signed
    /// manifest's codeCheck, and the code has not expired. Slow (PBKDF2): call off the main thread.
    public static func verify(name: String, code: String, codeCheck: Data?, adminKey: Data?, expiresAt: Date?,
                              now: Date = Date(), rounds: Int = RoomPasscode.rounds) -> Result {
        guard let codeCheck, let adminKey else { return .noCodeRoom }
        if let expiresAt, now >= expiresAt { return .expired }
        guard let key = CodeRoom.codeKey(name: name, code: code, rounds: rounds) else { return .wrongCode }
        return CodeRoom.same(codeCheck, CodeRoom.check(codeKey: key, adminKey: adminKey)) ? .ok : .wrongCode
    }
}

// MARK: Wire types (JSON for the page)

public struct GatewayJoinRequest: Codable, Sendable { public var room: String; public var code: String?; public var name: String }
public struct GatewaySendRequest: Codable, Sendable { public var text: String }

public struct GatewayJoinReply: Codable, Equatable, Sendable {
    public var token: String
    public var room: String
    public var name: String
    public var device: String
}

public struct GatewayMessage: Codable, Equatable, Sendable {
    public var id: String
    public var seq: Int
    public var from: String
    public var text: String
    public var mine: Bool
    public var pasa: Bool
    public var kind: String
    public var at: Date
    public var rules: [String]?
    public var docs: [DocRef]?
    public init(id: String, seq: Int, from: String, text: String, mine: Bool, pasa: Bool, kind: String, at: Date, rules: [String]? = nil, docs: [DocRef]? = nil) {
        self.id = id; self.seq = seq; self.from = from; self.text = text; self.mine = mine; self.pasa = pasa
        self.kind = kind; self.at = at; self.rules = rules; self.docs = docs.map { $0.map { DocRef(title: $0.title, page: $0.page, version: $0.version, excerpt: $0.excerpt) } }
    }
}

public struct GatewayTask: Codable, Equatable, Sendable {
    public var title: String
    public var owner: String
    public var due: String?
    public var status: String
    public init(title: String, owner: String, due: String?, status: String) { self.title = title; self.owner = owner; self.due = due; self.status = status }
}

public struct GatewayState: Codable, Equatable, Sendable {
    public var room: String
    public var seq: Int
    public var messages: [GatewayMessage]
    public var tasks: [GatewayTask]
    public var ai: String
    public init(room: String, seq: Int, messages: [GatewayMessage], tasks: [GatewayTask], ai: String) {
        self.room = room; self.seq = seq; self.messages = messages; self.tasks = tasks; self.ai = ai
    }
}

public struct GatewayRoomInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var isOpen: Bool
    public var codeEpoch: Int
    public var codeCheck: Data?
    public var adminKey: Data?
    public var expiresAt: Date?
    public init(id: String, name: String, isOpen: Bool, codeEpoch: Int, codeCheck: Data?, adminKey: Data?, expiresAt: Date?) {
        self.id = id; self.name = name; self.isOpen = isOpen; self.codeEpoch = codeEpoch
        self.codeCheck = codeCheck; self.adminKey = adminKey; self.expiresAt = expiresAt
    }
}

/// What the router needs from the Mac (MeshService on the Mac; a fake in tests).
@MainActor
public protocol GatewayBackend: AnyObject {
    /// Rooms a browser may join on this Mac: Town Square and code rooms the Mac is in.
    func gatewayRoom(named name: String) -> GatewayRoomInfo?
    func gatewayRoom(id: String) -> GatewayRoomInfo?
    func gatewayPost(_ text: String, session: GatewaySession) -> Bool
    func gatewayState(session: GatewaySession, since: Int) -> GatewayState
    func gatewayJoined(_ session: GatewaySession)
}

// MARK: Router

@MainActor
public final class GatewayRouter {
    public var sessions = GatewaySessions()
    public var limiter = GatewayLimiter()
    public var rounds = RoomPasscode.rounds
    public var now: () -> Date = { Date() }
    public weak var backend: GatewayBackend?

    public init(backend: GatewayBackend?) { self.backend = backend }

    public func handle(_ req: HTTPRequest, from address: String) async -> HTTPResponse {
        guard GatewayNet.isLocal(address) else { return .error(403, "Local network only.") }
        guard let backend else { return .error(503, "Libre is not ready.") }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/join"), ("GET", "/index.html"):
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(GatewayPage.html.utf8))
        case ("GET", "/api/ping"):
            return .json(["ok": "libre"])
        case ("POST", "/api/join"):
            if let wait = limiter.allowJoin(from: address, now: now()) {
                return .error(429, "Too many tries. Wait \(wait) seconds.", retryAfter: wait)
            }
            guard let body = try? JSONDecoder().decode(GatewayJoinRequest.self, from: req.body) else { return .error(400, "Bad request.") }
            let name = GatewaySessions.cleanName(body.name)
            guard !name.isEmpty else { return .error(400, "Type your name.") }
            guard let room = backend.gatewayRoom(named: body.room) else {
                return .error(404, "No room with that name on this Mac. Check the name on the join screen.")
            }
            if !room.isOpen {
                let code = body.code ?? ""
                let (check, adminKey, exp, label, rounds, at) = (room.codeCheck, room.adminKey, room.expiresAt, room.name, self.rounds, now())
                let result = await Task.detached(priority: .userInitiated) {
                    GatewayJoinCheck.verify(name: label, code: code, codeCheck: check, adminKey: adminKey, expiresAt: exp, now: at, rounds: rounds)
                }.value
                switch result {
                case .ok: break
                case .wrongCode: return .error(401, "That code is not right. Check the code on the join screen.")
                case .expired: return .error(401, "That code expired. Ask the room admin for a new one.")
                case .noCodeRoom: return .error(409, "This room cannot be joined from a browser.")
                }
            }
            guard let s = sessions.start(roomID: room.id, name: name, address: address, codeEpoch: room.codeEpoch, now: now()) else {
                return .error(503, "Too many browser members right now. Try again later.")
            }
            backend.gatewayJoined(s)
            return .json(GatewayJoinReply(token: s.token, room: room.name, name: s.displayName, device: s.device))
        case ("GET", "/api/state"):
            guard let s = session(req) else { return .error(401, "Please join again.") }
            return .json(backend.gatewayState(session: s, since: Int(req.query["since"] ?? "0") ?? 0))
        case ("POST", "/api/send"):
            guard let s = session(req) else { return .error(401, "Please join again.") }
            if let wait = limiter.allowSend(session: s.token, now: now()) {
                return .error(429, "Slow down. Wait \(wait) seconds.", retryAfter: wait)
            }
            guard let body = try? JSONDecoder().decode(GatewaySendRequest.self, from: req.body) else { return .error(400, "Bad request.") }
            let text = String(body.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
            guard !text.isEmpty else { return .error(400, "Type a message.") }
            return backend.gatewayPost(text, session: s) ? .json(["ok": "sent"]) : .error(409, "Could not send right now.")
        case ("POST", "/api/leave"):
            if let token = req.bearer { sessions.end(token) }
            return .json(["ok": "left"])
        case (_, "/"), (_, "/join"), (_, "/api/join"), (_, "/api/state"), (_, "/api/send"), (_, "/api/leave"):
            return .error(405, "Method not allowed.")
        default:
            return .error(404, "Not found.")
        }
    }

    private func session(_ req: HTTPRequest) -> GatewaySession? {
        let backend = self.backend
        return sessions.check(req.bearer, codeEpoch: { id in backend?.gatewayRoom(id: id)?.codeEpoch }, now: now())
    }
}
