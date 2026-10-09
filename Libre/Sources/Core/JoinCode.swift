// JoinCode.swift
// Pasa: "Create your room" with a short code (Kyle, Oct 9, 2026, 10:17 PM PHT).
//
// A code room is found by its NAME and entered with a short generated CODE:
// - Room tag and base key come from the name only (HKDF of a fixed domain plus the name), so the
//   room keeps its identity when the admin makes a new code. The base key only seals room
//   control traffic (manifests and join requests). Chat, asks and media use the random epoch key
//   that the admin seals to each admitted member (RoomGovernance), never derivable from the name.
// - The code is an admission credential. The joiner derives a code key (PBKDF2-HMAC-SHA256,
//   600,000 rounds, salted by the name) and sends proof = HMAC(code key, room | its signing key)
//   in its signed join request. The admin admits only a proof made with the current code, before
//   the code expires. The admin's manifest carries codeCheck = HMAC(code key, "admin" | admin
//   key), so a joiner pins only an admin who knows the code (two rooms with the same name do not
//   get mixed up).
// - "New code" rotates the code and removes every member who is not an admin, with a new epoch
//   key, so old joins must enter the new code. Expiry (off, 1 hour, 1 day) is in the link and
//   in the signed manifest, and the admin refuses expired proofs.
// - Join link (QR): pasa://join?room=<name>&code=<code>&v=1[&exp=<unix seconds>]. Pasa must be
//   installed; there is no offline web fallback.
// Pure Swift; tested on Linux.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum JoinCode {
    /// 32 symbols with no 0, O, 1 or I, so a code read off a projector cannot be misread.
    public static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    public static let length = 8

    /// "K7QM-3XRF"
    public static func generate<G: RandomNumberGenerator>(using rng: inout G) -> String {
        let raw = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
        return format(raw)
    }

    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    /// "k7qm 3xrf" -> "K7QM3XRF". nil when it is not a valid code (wrong length or symbols).
    public static func normalize(_ typed: String) -> String? {
        let raw = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard raw.count == length, raw.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return raw
    }

    public static func format(_ raw: String) -> String {
        guard raw.count == length else { return raw }
        return String(raw.prefix(4)) + "-" + String(raw.suffix(4))
    }

    public static func isValid(_ typed: String) -> Bool { normalize(typed) != nil }
}

/// How long a new code works.
public enum CodeExpiry: String, CaseIterable, Codable, Sendable {
    case off, hour, day

    public var label: String {
        switch self {
        case .off: return "Never"
        case .hour: return "1 hour"
        case .day: return "1 day"
        }
    }

    public func date(from now: Date) -> Date? {
        switch self {
        case .off: return nil
        case .hour: return now.addingTimeInterval(3600)
        case .day: return now.addingTimeInterval(86400)
        }
    }
}

public enum CodeRoom {
    static let domain = "pasa-code-room-v1|"

    /// Base key from the name only (fast). Same name, same room tag.
    public static func baseKey(name: String) -> Data {
        Data(SHA256.hash(data: Data((domain + RoomPasscode.normalizedName(name)).utf8)))
    }

    /// Code key (slow, PBKDF2 600,000 rounds): call off the main thread.
    public static func codeKey(name: String, code: String, rounds: Int = RoomPasscode.rounds) -> Data? {
        guard let clean = JoinCode.normalize(code) else { return nil }
        return RoomPasscode.deriveKey(name: name, passcode: "code:" + clean, rounds: rounds)
    }

    static func mac(_ key: Data, _ parts: [Data]) -> Data {
        var h = HMAC<SHA256>(key: SymmetricKey(data: key))
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    /// Joiner's proof that it knows the current code, bound to its own signing key.
    public static func proof(codeKey: Data, room: String, signKey: Data) -> Data {
        mac(codeKey, [Data("join|".utf8), Data(room.utf8), Data("|".utf8), signKey])
    }

    /// Admin's proof (in the manifest) that it knows the code.
    public static func check(codeKey: Data, adminKey: Data) -> Data {
        mac(codeKey, [Data("admin|".utf8), adminKey])
    }

    /// Constant-time compare.
    public static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// Admin side: proof matches the current code key and the code has not expired.
    public static func admits(proof: Data?, codeKey: Data?, room: String, signKey: Data, expiresAt: Date?, now: Date) -> Bool {
        guard let proof, let codeKey else { return false }
        if let expiresAt, now >= expiresAt { return false }
        return same(proof, self.proof(codeKey: codeKey, room: room, signKey: signKey))
    }
}

/// pasa://join?room=BOHOL-7&code=K7QM-3XRF&v=1&exp=1791600000
public struct JoinLink: Equatable, Sendable {
    public static let scheme = "pasa"
    public static let version = 1

    public var room: String
    public var code: String
    public var expiresAt: Date?

    public init(room: String, code: String, expiresAt: Date? = nil) {
        self.room = Room.cleanLabel(room)
        self.code = JoinCode.normalize(code).map(JoinCode.format) ?? code
        self.expiresAt = expiresAt
    }

    public var url: String {
        var c = URLComponents()
        c.scheme = JoinLink.scheme
        c.host = "join"
        var items = [URLQueryItem(name: "room", value: room), URLQueryItem(name: "code", value: code),
                     URLQueryItem(name: "v", value: String(JoinLink.version))]
        if let expiresAt { items.append(URLQueryItem(name: "exp", value: String(Int(expiresAt.timeIntervalSince1970)))) }
        c.queryItems = items
        return c.string ?? ""
    }

    public enum ParseError: Error, Equatable { case notPasa, unsupportedVersion, badRoom, badCode }

    public static func parse(_ text: String) -> Result<JoinLink, ParseError> {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == scheme, c.host?.lowercased() == "join" else { return .failure(.notPasa) }
        let items = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let v = items["v"].flatMap(Int.init), v == version else { return .failure(.unsupportedVersion) }
        let room = Room.cleanLabel(items["room"] ?? "")
        guard !room.isEmpty, room != "DEFAULT" else { return .failure(.badRoom) }
        guard let code = items["code"], JoinCode.isValid(code) else { return .failure(.badCode) }
        let exp = items["exp"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        return .success(JoinLink(room: room, code: code, expiresAt: exp))
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// "Code works until 11:15 PM" style line for the share screen.
    public func expiryLine(now: Date = Date()) -> String {
        guard let expiresAt else { return "Code does not expire" }
        if isExpired(now: now) { return "Code expired. Make a new code." }
        let mins = Int(expiresAt.timeIntervalSince(now) / 60)
        if mins < 60 { return "Code expires in \(max(1, mins)) min" }
        let hours = mins / 60
        return "Code expires in \(hours) h"
    }
}
