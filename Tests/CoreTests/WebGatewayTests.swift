// WebGatewayTests.swift: browser gateway (Android and other phones). HTTP parse and responses,
// join check with the app's code key derivation, sessions, rate limits, LAN only, links, router.

import Foundation

@MainActor
final class FakeGatewayBackend: GatewayBackend {
    var rooms: [GatewayRoomInfo] = []
    var posted: [(String, GatewaySession)] = []
    var joined: [GatewaySession] = []
    func gatewayRoom(named name: String) -> GatewayRoomInfo? {
        rooms.first { RoomPasscode.normalizedName($0.name) == RoomPasscode.normalizedName(name) }
    }
    func gatewayRoom(id: String) -> GatewayRoomInfo? { rooms.first { $0.id == id } }
    func gatewayPost(_ text: String, session: GatewaySession) -> Bool { posted.append((text, session)); return true }
    func gatewayState(session: GatewaySession, since: Int) -> GatewayState {
        let all = posted.enumerated().map { i, p in
            GatewayMessage(id: "m\(i)", seq: i + 1, from: p.1.displayName, text: p.0, mine: p.1.token == session.token, pasa: false, kind: "chat", at: Date(timeIntervalSince1970: 0))
        }
        return GatewayState(room: "R", seq: all.count, messages: all.filter { $0.seq > since }, tasks: [], ai: "Libre is on")
    }
    func gatewayJoined(_ session: GatewaySession) { joined.append(session) }
}

private func req(_ method: String, _ path: String, body: String? = nil, token: String? = nil) -> HTTPRequest {
    var raw = "\(method) \(path) HTTP/1.1\r\nHost: 192.168.1.5:8787\r\n"
    if let token { raw += "Authorization: Bearer \(token)\r\n" }
    let b = Data((body ?? "").utf8)
    raw += "Content-Length: \(b.count)\r\n\r\n"
    guard case .ok(let r, _) = HTTPRequest.parse(Data(raw.utf8) + b) else { fatalError("parse") }
    return r
}

private func json(_ r: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
}

@MainActor
func runWebGatewayTests() async {
    // HTTP parsing
    let raw = Data("POST /api/join?room=BOHOL%207&x=a+b HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nAuthorization: Bearer abc\r\n\r\nbody".utf8)
    if case .ok(let r, let used) = HTTPRequest.parse(raw) {
        check(r.method == "POST" && r.path == "/api/join" && r.query["room"] == "BOHOL 7" && r.query["x"] == "a b", "gateway: request line and query decode")
        check(String(data: r.body, encoding: .utf8) == "body" && used == raw.count && r.bearer == "abc", "gateway: body, length and bearer")
    } else { check(false, "gateway: parse a full request") }
    check(HTTPRequest.parse(raw.prefix(raw.count - 2)) == .incomplete, "gateway: partial body waits")
    check(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == .incomplete, "gateway: partial headers wait")
    if case .bad = HTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)) { check(true, "gateway: bad request line refused") } else { check(false, "gateway: bad request line refused") }
    if case .bad = HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) { check(true, "gateway: huge body refused") } else { check(false, "gateway: huge body refused") }
    if case .bad = HTTPRequest.parse(Data(repeating: 65, count: HTTPRequest.maxHeaderBytes + 10)) { check(true, "gateway: huge headers refused") } else { check(false, "gateway: huge headers refused") }

    let resp = HTTPResponse.error(429, "slow", retryAfter: 7).data
    let text = String(data: resp, encoding: .utf8) ?? ""
    check(text.hasPrefix("HTTP/1.1 429 Too Many Requests\r\n") && text.contains("Retry-After: 7") && text.contains("Connection: close"), "gateway: response head")
    check(text.contains("Content-Security-Policy: default-src 'self'"), "gateway: page may load nothing from elsewhere")

    // LAN only
    for ok in ["192.168.1.20", "10.0.0.4", "172.20.10.2", "172.16.0.1", "127.0.0.1", "169.254.3.3", "::1", "fe80::1%en0", "fd12::3", "::ffff:192.168.0.9"] {
        check(GatewayNet.isLocal(ok), "gateway: local address \(ok)")
    }
    for bad in ["8.8.8.8", "172.32.0.1", "1.1.1.1", "2001:4860::8888", "100.64.0.1", "", "not-an-ip", "192.168.1"] {
        check(!GatewayNet.isLocal(bad), "gateway: non-local address refused \(bad)")
    }

    // Links: the browser QR never carries the code
    let code = "K7QM-3XRF"
    let url = GatewayNet.joinURL(host: "172.20.10.3", port: 8787, room: "BOHOL 7")
    check(url == "http://172.20.10.3:8787/join?room=BOHOL%207", "gateway: browser QR url \(url)")
    check(!url.contains(code) && !url.contains("K7QM") && !url.contains("code"), "gateway: code never in the browser QR")
    let app = GatewayNet.appURL(room: "BOHOL 7")
    check(app.hasPrefix("libre://join?room=BOHOL%207") && !app.contains("code"), "gateway: app button carries the room only")
    if case .success = JoinLink.parse(app) { check(false, "gateway: app link without a code is not a full join link") }
    else { check(true, "gateway: app link without a code is not a full join link") }

    check(GatewayNet.roomFromJoinURL(url) == "BOHOL-7", "gateway: app scanner reads the room from the browser QR")
    check(GatewayNet.roomFromJoinURL("http://example.com/join?room=X") == nil, "gateway: app scanner ignores internet links")
    check(JoinLink.roomOnly(app) == "BOHOL-7", "gateway: app reads the room-only link")
    check(JoinLink.roomOnly(GatewayNet.appURL(room: "Town Square")).map(Room.isReservedLabel) == true, "gateway: Town Square room-only link")
    check(JoinLink.roomOnly("pasa://join?room=BOHOL%207&code=K7QM-3XRF&v=1") == nil, "gateway: full link is not room-only")
    check(JoinLink.roomOnly("https://join?room=A&v=1") == nil, "gateway: other scheme is not room-only")

    // Page is self-contained
    let page = GatewayPage.html
    check(!page.contains("http://") && !page.contains("https://") && !page.contains("//cdn"), "gateway: page loads nothing from the internet")
    check(!page.contains("innerHTML"), "gateway: page never sets user text as HTML")
    check(page.contains("same Wi-Fi") && page.contains("not encrypted") && page.contains("Open in Libre app"), "gateway: page tells the truth")

    // Join check (same derivation as the app)
    let rounds = 1000
    let admin = Data(repeating: 7, count: 32)
    let key = CodeRoom.codeKey(name: "BOHOL 7", code: code, rounds: rounds)!
    let cc = CodeRoom.check(codeKey: key, adminKey: admin)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    check(GatewayJoinCheck.verify(name: "BOHOL 7", code: "k7qm3xrf", codeCheck: cc, adminKey: admin, expiresAt: nil, now: t0, rounds: rounds) == .ok, "gateway: right code (any case, no dash)")
    check(GatewayJoinCheck.verify(name: "BOHOL 7", code: "K7QM-3XRG", codeCheck: cc, adminKey: admin, expiresAt: nil, now: t0, rounds: rounds) == .wrongCode, "gateway: wrong code")
    check(GatewayJoinCheck.verify(name: "BOHOL 8", code: code, codeCheck: cc, adminKey: admin, expiresAt: nil, now: t0, rounds: rounds) == .wrongCode, "gateway: right code, other room")
    check(GatewayJoinCheck.verify(name: "BOHOL 7", code: code, codeCheck: cc, adminKey: admin, expiresAt: t0, now: t0, rounds: rounds) == .expired, "gateway: expired code")
    check(GatewayJoinCheck.verify(name: "BOHOL 7", code: code, codeCheck: nil, adminKey: admin, expiresAt: nil, now: t0, rounds: rounds) == .noCodeRoom, "gateway: passcode room not joinable")

    // Limiter
    var lim = GatewayLimiter()
    for i in 0..<5 { check(lim.allowJoin(from: "10.0.0.2", now: t0.addingTimeInterval(Double(i))) == nil, "gateway: join \(i + 1) allowed") }
    let wait = lim.allowJoin(from: "10.0.0.2", now: t0.addingTimeInterval(5))
    check(wait != nil && wait! >= 50, "gateway: sixth join in a minute waits (\(wait ?? -1) s)")
    check(lim.allowJoin(from: "10.0.0.3", now: t0.addingTimeInterval(5)) == nil, "gateway: other address unaffected")
    check(lim.allowJoin(from: "10.0.0.2", now: t0.addingTimeInterval(61)) == nil, "gateway: window slides")
    var lim2 = GatewayLimiter()
    for i in 0..<30 { _ = lim2.allowJoin(from: "10.1.0.\(i)", now: t0) }
    check(lim2.allowJoin(from: "10.2.0.1", now: t0) != nil, "gateway: overall join cap")
    var lim3 = GatewayLimiter()
    for _ in 0..<20 { _ = lim3.allowSend(session: "s", now: t0) }
    check(lim3.allowSend(session: "s", now: t0) != nil && lim3.allowSend(session: "t", now: t0) == nil, "gateway: send cap per session")

    // Sessions
    var ss = GatewaySessions()
    let s1 = ss.start(roomID: "R1", name: "Ana", address: "10.0.0.2", codeEpoch: 0, now: t0)!
    check(s1.token.count == 64 && s1.device == "web-" + s1.token.prefix(8) && s1.displayName == "Ana (via Mac)", "gateway: token and relayed name")
    check(ss.check(s1.token, codeEpoch: { _ in 0 }, now: t0.addingTimeInterval(60)) != nil, "gateway: token works")
    check(ss.check("nope", codeEpoch: { _ in 0 }, now: t0) == nil && ss.check(nil, codeEpoch: { _ in 0 }, now: t0) == nil, "gateway: unknown token refused")
    check(ss.check(s1.token, codeEpoch: { _ in 1 }, now: t0.addingTimeInterval(61)) == nil, "gateway: new code ends the session")
    check(ss.all.isEmpty, "gateway: ended session is gone")
    let s2 = ss.start(roomID: "R1", name: "Ben", address: "10.0.0.2", codeEpoch: 0, now: t0)!
    check(ss.check(s2.token, codeEpoch: { _ in 0 }, now: t0.addingTimeInterval(GatewaySessions.idleLimit + 1)) == nil, "gateway: idle session expires")
    check(ss.check(s2.token, codeEpoch: { _ in nil }, now: t0) == nil, "gateway: room left, session ends")
    check(GatewaySessions.cleanName("  <b>Ana</b>\n ") == "bAna/b" && GatewaySessions.cleanName(String(repeating: "x", count: 40)).count == 24, "gateway: names cleaned and capped")
    var cap = GatewaySessions()
    for i in 0..<GatewaySessions.maxSessions { _ = cap.start(roomID: "R", name: "n\(i)", address: "10.0.0.1", codeEpoch: 0, now: t0) }
    check(cap.start(roomID: "R", name: "late", address: "10.0.0.1", codeEpoch: 0, now: t0) == nil, "gateway: session cap")

    // Router end to end with a fake Mac
    let fake = FakeGatewayBackend()
    fake.rooms = [GatewayRoomInfo(id: "TS", name: "Town Square", isOpen: true, codeEpoch: 0, codeCheck: nil, adminKey: nil, expiresAt: nil),
                  GatewayRoomInfo(id: "B7", name: "BOHOL 7", isOpen: false, codeEpoch: 2, codeCheck: cc, adminKey: admin, expiresAt: nil)]
    let router = GatewayRouter(backend: fake)
    router.rounds = rounds
    router.now = { t0 }
    var r = await router.handle(req("GET", "/join?room=BOHOL%207"), from: "192.168.1.9")
    check(r.status == 200 && r.contentType.hasPrefix("text/html") && String(data: r.body, encoding: .utf8)!.contains("Join a Libre room"), "gateway: join page served")
    r = await router.handle(req("GET", "/join"), from: "8.8.8.8")
    check(r.status == 403, "gateway: internet address refused")
    r = await router.handle(req("GET", "/api/state"), from: "192.168.1.9")
    check(r.status == 401, "gateway: state needs a token")
    r = await router.handle(req("POST", "/api/send", body: #"{"text":"hi"}"#), from: "192.168.1.9")
    check(r.status == 401 && fake.posted.isEmpty, "gateway: send needs a token")
    r = await router.handle(req("POST", "/api/join", body: #"{"room":"bohol 7","code":"K7QM-3XRG","name":"Ana"}"#), from: "192.168.1.9")
    check(r.status == 401 && (json(r)["error"] as? String ?? "").contains("not right"), "gateway: wrong code refused")
    r = await router.handle(req("POST", "/api/join", body: #"{"room":"Nowhere","code":"K7QM-3XRF","name":"Ana"}"#), from: "192.168.1.9")
    check(r.status == 404, "gateway: unknown room")
    r = await router.handle(req("POST", "/api/join", body: #"{"room":"BOHOL 7","code":"K7QM-3XRF","name":"   "}"#), from: "192.168.1.9")
    check(r.status == 400, "gateway: name required")
    for _ in 0..<2 { _ = await router.handle(req("POST", "/api/join", body: #"{"room":"BOHOL 7","code":"K7QM-AAAA","name":"Ana"}"#), from: "192.168.1.9") }
    r = await router.handle(req("POST", "/api/join", body: #"{"room":"BOHOL 7","code":"K7QM-3XRF","name":"Ana"}"#), from: "192.168.1.9")
    check(r.status == 429 && fake.joined.isEmpty, "gateway: sixth try in a minute from one address is blocked, even with the right code")
    r = await router.handle(req("POST", "/api/join", body: #"{"room":"BOHOL 7","code":"K7QM-3XRF","name":"Ana"}"#), from: "192.168.1.10")
    let token = json(r)["token"] as? String ?? ""
    check(r.status == 200 && token.count == 64 && json(r)["name"] as? String == "Ana (via Mac)" && fake.joined.count == 1, "gateway: right code joins")
    check(!String(data: r.body, encoding: .utf8)!.contains("K7QM"), "gateway: reply never echoes the code")
    r = await router.handle(req("POST", "/api/send", body: #"{"text":"  @libre what is the curfew?  "}"#, token: token), from: "192.168.1.10")
    check(r.status == 200 && fake.posted.first?.0 == "@libre what is the curfew?" && fake.posted.first?.1.roomID == "B7", "gateway: send reaches the room")
    r = await router.handle(req("GET", "/api/state?since=0", token: token), from: "192.168.1.10")
    let msgs = json(r)["messages"] as? [[String: Any]] ?? []
    check(r.status == 200 && msgs.count == 1 && msgs[0]["mine"] as? Bool == true, "gateway: state lists messages")
    r = await router.handle(req("GET", "/api/state?since=1", token: token), from: "192.168.1.10")
    check((json(r)["messages"] as? [[String: Any]] ?? []).isEmpty, "gateway: since skips seen messages")
    r = await router.handle(req("POST", "/api/join", body: #"{"room":"town square","name":"Ben"}"#), from: "192.168.1.11")
    check(r.status == 200, "gateway: Town Square needs no code")
    fake.rooms[1].codeEpoch = 3
    r = await router.handle(req("GET", "/api/state", token: token), from: "192.168.1.10")
    check(r.status == 401, "gateway: New code signs browser members out")
    r = await router.handle(req("DELETE", "/api/send"), from: "192.168.1.10")
    check(r.status == 405, "gateway: wrong method")
    r = await router.handle(req("GET", "/etc/passwd"), from: "192.168.1.10")
    check(r.status == 404, "gateway: unknown path")
    r = await router.handle(req("POST", "/api/join", body: "not json"), from: "192.168.1.12")
    check(r.status == 400, "gateway: bad json")

    // Doc excerpts stay capped on the wire
    let long = DocRef(title: "Guide", page: 2, version: 1, excerpt: String(repeating: "a", count: 2000))
    let gm = GatewayMessage(id: "x", seq: 1, from: "Libre", text: "t", mine: false, pasa: true, kind: "answer", at: t0, docs: [long])
    check((gm.docs?.first?.excerpt.count ?? 0) <= 600, "gateway: excerpt cap 600")
}
