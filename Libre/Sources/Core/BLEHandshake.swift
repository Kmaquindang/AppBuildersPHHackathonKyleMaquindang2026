// BLEHandshake.swift
// Libre: signed Bluetooth hello and link book (Oct 12, 2026). Pure Swift, tested on Linux.
// Our own design. It shares no code with any other mesh app.
//
// Before this, a Bluetooth link was named by an unsigned hello carrying the device's mesh name,
// so any nearby device could claim any name. Now each side proves it holds a device key:
//
//   hello (frame type 1), payload:
//     byte 0        hello version (2)
//     bytes 1-32    sender's Ed25519 public key (DeviceIdentity.signKey)
//     bytes 33-48   16 random bytes (this link's challenge for the other side)
//     byte 49       flags (bit 0: this device is an AI Mac hub)
//     byte 50       name length n (1 to 64)
//     bytes 51..    mesh name, UTF-8 (n bytes)
//     last 64       Ed25519 signature over "libre-ble-hello-v2|" + every byte before it
//   proof (frame type 4), payload: 64-byte Ed25519 signature over
//     "libre-ble-proof-v2|" + peer's challenge (16) + my key (32) + peer's key (32)
//
// A link is verified only when the peer's hello is signed by the key it carries AND the peer's
// proof signs this side's fresh challenge with that key. A recorded hello replayed by someone
// else fails, because they cannot sign the new challenge. Links are keyed by the peer's key
// (BLEPeerBook), not by its name: one name is bound to one key while that key is linked, so a
// second device claiming the same name is refused, blocking follows the key, and the tie-break
// compares keys. Room content was already sealed; this protects routing and blocking.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct BLEHello: Equatable, Sendable {
    public static let version: UInt8 = 2
    public static let nonceBytes = 16
    public static let maxNameBytes = 64
    static let helloDomain = Data("libre-ble-hello-v2|".utf8)
    static let proofDomain = Data("libre-ble-proof-v2|".utf8)

    public var signKey: Data
    public var nonce: Data
    public var isHub: Bool
    public var name: String
    public var signature: Data

    /// Hex of the full public key: the stable id of a peer on Bluetooth.
    public var keyID: String { BLEHello.keyID(signKey) }

    public static func keyID(_ key: Data) -> String { key.map { String(format: "%02x", $0) }.joined() }

    static func body(key: Data, nonce: Data, hub: Bool, name: Data) -> Data {
        var d = Data([version])
        d.append(key); d.append(nonce)
        d.append(hub ? 1 : 0)
        d.append(UInt8(name.count)); d.append(name)
        return d
    }

    /// Signed hello for this device. nil if the name is empty or longer than 64 bytes.
    public static func make(identity: DeviceIdentity, name: String, nonce: Data, hub: Bool = false) -> Data? {
        let n = Data(name.utf8)
        guard !n.isEmpty, n.count <= maxNameBytes, nonce.count == nonceBytes,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: identity.signSecret) else { return nil }
        let b = body(key: key.publicKey.rawRepresentation, nonce: nonce, hub: hub, name: n)
        guard let sig = try? key.signature(for: helloDomain + b) else { return nil }
        return b + sig
    }

    /// Parses and checks the signature. nil for anything malformed or not signed by its key.
    public static func open(_ data: Data) -> BLEHello? {
        let b = [UInt8](data)
        guard b.count >= 51 + 1 + 64, b[0] == version else { return nil }
        let n = Int(b[50])
        guard n >= 1, n <= maxNameBytes, b.count == 51 + n + 64 else { return nil }
        let key = Data(b[1..<33]), nonce = Data(b[33..<49])
        let nameBytes = Data(b[51..<(51 + n)])
        let sig = Data(b[(51 + n)...])
        guard let name = String(data: nameBytes, encoding: .utf8),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              pub.isValidSignature(sig, for: helloDomain + Data(b[0..<(51 + n)])) else { return nil }
        return BLEHello(signKey: key, nonce: nonce, isHub: b[49] & 1 == 1, name: name, signature: sig)
    }

    static func proofMessage(challenge: Data, signer: Data, verifier: Data) -> Data {
        proofDomain + challenge + signer + verifier
    }

    /// Answer to the peer's hello: sign its challenge, binding both keys.
    public static func proof(identity: DeviceIdentity, peer: BLEHello) -> Data? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: identity.signSecret) else { return nil }
        return try? key.signature(for: proofMessage(challenge: peer.nonce, signer: key.publicKey.rawRepresentation, verifier: peer.signKey))
    }

    /// True when `proof` is the peer's signature over the challenge this side sent.
    public static func checkProof(_ proof: Data, peer: BLEHello, myChallenge: Data, myKey: Data) -> Bool {
        guard proof.count == 64, let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: peer.signKey) else { return false }
        return pub.isValidSignature(proof, for: proofMessage(challenge: myChallenge, signer: peer.signKey, verifier: myKey))
    }

    /// Unsigned byte order of two keys (the same on every platform).
    public static func keyGreater(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return a.count > b.count
    }
}

/// Trust on first use for Bluetooth device keys (issue #12). The first key verified for a device
/// name is remembered (BLETransport saves it to ble-trust.json); later, a hello with that name and
/// a different key is refused and listed as a conflict until the person trusts the new key (for
/// example after Libre was reinstalled) or it stops. Codable, so it survives restarts.
public struct BLETrustStore: Codable, Equatable, Sendable {
    public enum Check: Equatable, Sendable { case trusted, firstUse, changed(trustedKey: String) }

    /// Device name -> key id trusted for it.
    public private(set) var keys: [String: String] = [:]
    /// Device name -> the different key id it last came back with (refused until trusted).
    public private(set) var conflicts: [String: String] = [:]

    public init() {}

    public func check(name: String, keyID: String) -> Check {
        guard let known = keys[name] else { return .firstUse }
        return known == keyID ? .trusted : .changed(trustedKey: known)
    }

    /// Remembers a verified key the first time a name is seen. Returns true when the store changed.
    @discardableResult
    public mutating func remember(name: String, keyID: String) -> Bool {
        guard keys[name] == nil else { return false }
        keys[name] = keyID
        return true
    }

    /// A hello came with a key other than the trusted one. Returns true when this is news.
    @discardableResult
    public mutating func flag(name: String, keyID: String) -> Bool {
        guard conflicts[name] != keyID else { return false }
        conflicts[name] = keyID
        return true
    }

    /// The person chose to trust the new key: the next link with it is accepted and remembered.
    public mutating func reset(name: String) {
        keys.removeValue(forKey: name)
        conflicts.removeValue(forKey: name)
    }
}

/// Who is on each Bluetooth link, keyed by the peer's device key. Pure state, no radio.
public struct BLEPeerBook: Sendable {
    public enum Role: String, Sendable { case central, peripheral }

    public struct Link: Equatable, Sendable {
        public var role: Role
        public var challenge: Data
        public var hello: BLEHello?
        public var verified = false
        public var openedAt: Date
    }

    public enum HelloResult: Equatable, Sendable {
        /// Signed hello accepted: send this proof back.
        case sendProof(Data)
        case rejected(String)
    }

    public enum ProofResult: Equatable, Sendable {
        /// Link verified. `newPeer` is true when this is the first verified link to that key.
        /// `dropLink` is our own central link to close (tie-break: one link per pair).
        /// `replaced` is an older link to the same key in the same role (the peer's radio address
        /// changed, or the old link is stale): close it, the new one takes over.
        case verified(name: String, keyID: String, newPeer: Bool, dropLink: String?, replaced: String? = nil)
        case rejected(String)
    }

    public let identity: DeviceIdentity
    public let myKey: Data
    public private(set) var links: [String: Link] = [:]
    public private(set) var blockedNames: Set<String> = []
    public private(set) var blockedKeys: Set<String> = []
    /// Keys remembered per device name (trust on first use). BLETransport loads and saves it.
    public var trust = BLETrustStore()

    public init(identity: DeviceIdentity) {
        self.identity = identity
        self.myKey = identity.signKey
    }

    /// A link is up (subscribed). Returns the challenge to put in our hello.
    public mutating func opened(_ linkID: String, role: Role, challenge: Data = BLEPeerBook.randomChallenge(), now: Date = Date()) -> Data {
        if let l = links[linkID] { return l.challenge }
        links[linkID] = Link(role: role, challenge: challenge, openedAt: now)
        return challenge
    }

    public static func randomChallenge() -> Data {
        Data((0..<BLEHello.nonceBytes).map { _ in UInt8.random(in: 0...255) })
    }

    public mutating func received(hello data: Data, on linkID: String) -> HelloResult {
        guard var link = links[linkID] else { return .rejected("no link") }
        guard link.hello == nil else { return .rejected("second hello") }
        guard let hello = BLEHello.open(data) else { return .rejected("bad signature") }
        guard hello.signKey != myKey else { return .rejected("own key") }
        if isBlocked(keyID: hello.keyID, name: hello.name) { return .rejected("blocked") }
        // One name per key and one key per name while linked.
        for (id, other) in links where id != linkID && other.verified {
            guard let h = other.hello else { continue }
            if h.name == hello.name && h.signKey != hello.signKey { return .rejected("name \(hello.name) is linked to another key") }
            if h.signKey == hello.signKey && h.name != hello.name { return .rejected("key already linked as \(h.name)") }
        }
        // Trust on first use: a known name with a different key, even when nobody is linked.
        if case .changed = trust.check(name: hello.name, keyID: hello.keyID) {
            trust.flag(name: hello.name, keyID: hello.keyID)
            return .rejected("key changed for \(hello.name)")
        }
        guard let proof = BLEHello.proof(identity: identity, peer: hello) else { return .rejected("cannot sign") }
        link.hello = hello
        links[linkID] = link
        return .sendProof(proof)
    }

    public mutating func received(proof: Data, on linkID: String) -> ProofResult {
        guard var link = links[linkID], let hello = link.hello else { return .rejected("proof before hello") }
        guard !link.verified else { return .rejected("already verified") }
        guard BLEHello.checkProof(proof, peer: hello, myChallenge: link.challenge, myKey: myKey) else { return .rejected("bad proof") }
        let newPeer = !links.values.contains { $0.verified && $0.hello?.signKey == hello.signKey }
        // Same key, same role, older link: the peer came back under a new radio address (Android
        // sees iPhones rotate theirs) or the old link has not noticed it died. Keep the new one.
        let replaced = links.first { $0.key != linkID && $0.value.verified && $0.value.role == link.role && $0.value.hello?.signKey == hello.signKey }?.key
        if let replaced { links.removeValue(forKey: replaced) }
        link.verified = true
        links[linkID] = link
        trust.remember(name: hello.name, keyID: hello.keyID)
        // Both devices opened a link as scanner: the one with the greater key drops its own.
        var drop: String?
        let mine = links.filter { $0.value.verified && $0.value.hello?.signKey == hello.signKey }
        if let central = mine.first(where: { $0.value.role == .central })?.key,
           mine.contains(where: { $0.value.role == .peripheral }),
           BLEHello.keyGreater(myKey, hello.signKey) {
            drop = central
            links.removeValue(forKey: central)
        }
        return .verified(name: hello.name, keyID: hello.keyID, newPeer: newPeer && replaced == nil, dropLink: drop, replaced: replaced)
    }

    /// Link gone. Returns the peer's name and key if it was verified, and whether another
    /// verified link to that key is still up.
    public mutating func closed(_ linkID: String) -> (name: String, keyID: String, stillLinked: Bool)? {
        guard let link = links.removeValue(forKey: linkID), link.verified, let h = link.hello else { return nil }
        let still = links.values.contains { $0.verified && $0.hello?.signKey == h.signKey }
        return (h.name, h.keyID, still)
    }

    public func isVerified(_ linkID: String) -> Bool { links[linkID]?.verified == true }
    public func peer(on linkID: String) -> BLEHello? { links[linkID].flatMap { $0.verified ? $0.hello : nil } }

    /// Verified links to the device named `name`, central first (a central writes without
    /// waiting on the peer's notify queue).
    public func linkIDs(forName name: String) -> [String] {
        links.filter { $0.value.verified && $0.value.hello?.name == name }
            .sorted { ($0.value.role == .central ? 0 : 1, $0.key) < ($1.value.role == .central ? 0 : 1, $1.key) }
            .map { $0.key }
    }

    /// Names of verified, unblocked peers.
    public var linkedNames: [String] {
        Array(Set(links.values.compactMap { l -> String? in
            guard l.verified, let h = l.hello, !isBlocked(keyID: h.keyID, name: h.name) else { return nil }
            return h.name
        })).sorted()
    }

    public func keyID(forName name: String) -> String? {
        links.values.first { $0.verified && $0.hello?.name == name }?.hello?.keyID
    }

    public func isHub(name: String) -> Bool { links.values.contains { $0.verified && $0.hello?.name == name && $0.hello?.isHub == true } }

    /// Blocking by name (what Settings stores) also blocks the key that name is linked with,
    /// so the same device cannot come back under a new name. Returns links to close.
    public mutating func setBlocked(_ names: Set<String>) -> [String] {
        blockedNames = names
        for l in links.values { if let h = l.hello, names.contains(h.name) { blockedKeys.insert(h.keyID) } }
        return links.filter { $0.value.hello.map { isBlocked(keyID: $0.keyID, name: $0.name) } ?? false }.map { $0.key }.sorted()
    }

    public func isBlocked(keyID: String, name: String) -> Bool { blockedNames.contains(name) || blockedKeys.contains(keyID) }

    public mutating func reset() { links.removeAll() }
}
