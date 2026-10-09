// Identity.swift
// Pasa: per-device keys, signed blobs and per-member key boxes. Pure Swift, tested on Linux.
//
// - Every device has a Curve25519 signing key pair (who wrote this) and a Curve25519 key
//   agreement pair (seal a room key to this device). Saved as JSON in Application Support
//   (not the Keychain yet).
// - SignedBlob carries the exact signed bytes, so verifying never depends on re-encoding JSON.
// - KeyBox seals a 32-byte room epoch key to one member: ephemeral X25519, HKDF-SHA256,
//   ChaCha20-Poly1305, bound to the room tag, epoch and the member's public key.
//
// Crypto: CryptoKit on Apple platforms; Apple's open-source swift-crypto for the Linux tests.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct DeviceIdentity: Codable, Equatable, Sendable {
    /// Raw Curve25519 signing private key (32 bytes).
    public var signSecret: Data
    /// Raw Curve25519 key agreement private key (32 bytes).
    public var boxSecret: Data

    public init(signSecret: Data, boxSecret: Data) {
        self.signSecret = signSecret
        self.boxSecret = boxSecret
    }

    public static func generate() -> DeviceIdentity {
        DeviceIdentity(signSecret: Curve25519.Signing.PrivateKey().rawRepresentation,
                       boxSecret: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    public var signKey: Data { (try? Curve25519.Signing.PrivateKey(rawRepresentation: signSecret))?.publicKey.rawRepresentation ?? Data() }
    public var boxKey: Data { (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: boxSecret))?.publicKey.rawRepresentation ?? Data() }
    public var fingerprint: String { Fingerprint.of(signKey) }

    public func sign(_ body: Data, domain: String) -> SignedBlob? {
        PasaSign.sign(body, secret: signSecret, domain: domain)
    }

    /// Loads identity.json, or makes and saves a new identity.
    public static func loadOrCreate(at url: URL?) -> DeviceIdentity {
        if let url, let data = try? Data(contentsOf: url), let id = try? JSONDecoder().decode(DeviceIdentity.self, from: data),
           id.signSecret.count == 32, id.boxSecret.count == 32 {
            return id
        }
        let id = DeviceIdentity.generate()
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(id).write(to: url, options: .atomic)
        }
        return id
    }
}

/// Short, readable key fingerprint people can compare out loud: "3FA9-1C07-88D2".
public enum Fingerprint {
    public static func of(_ key: Data) -> String {
        guard !key.isEmpty else { return "none" }
        let hex = Data(SHA256.hash(data: key)).prefix(6).map { String(format: "%02X", $0) }.joined()
        var groups: [String] = []
        var rest = Substring(hex)
        while !rest.isEmpty { groups.append(String(rest.prefix(4))); rest = rest.dropFirst(4) }
        return groups.joined(separator: "-")
    }
}

/// Exact signed bytes plus signer public key and signature.
public struct SignedBlob: Codable, Equatable, Sendable {
    public var body: Data
    public var signer: Data
    public var sig: Data
    /// What kind of document this is ("manifest", "beacon", "join", "ai-status"). Signed too.
    public var domain: String

    public init(body: Data, signer: Data, sig: Data, domain: String) {
        self.body = body
        self.signer = signer
        self.sig = sig
        self.domain = domain
    }

    public var isValid: Bool { PasaSign.verify(self) }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? PasaJSON.decoder.decode(T.self, from: body)
    }
}

public enum PasaJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
    public static func string<T: Encodable>(_ value: T) -> String? {
        (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
    public static func value<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        try? decoder.decode(T.self, from: Data(text.utf8))
    }
}

public enum PasaSign {
    static func message(_ body: Data, domain: String) -> Data {
        Data("pasa-\(domain)-v1|".utf8) + body
    }

    public static func sign(_ body: Data, secret: Data, domain: String) -> SignedBlob? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret),
              let sig = try? key.signature(for: message(body, domain: domain)) else { return nil }
        return SignedBlob(body: body, signer: key.publicKey.rawRepresentation, sig: sig, domain: domain)
    }

    public static func sign<T: Encodable>(_ value: T, secret: Data, domain: String) -> SignedBlob? {
        guard let body = try? PasaJSON.encoder.encode(value) else { return nil }
        return sign(body, secret: secret, domain: domain)
    }

    public static func verify(_ blob: SignedBlob) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: blob.signer) else { return false }
        return key.isValidSignature(blob.sig, for: message(blob.body, domain: blob.domain))
    }

    public static func publicKey(ofSecret secret: Data) -> Data? {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: secret))?.publicKey.rawRepresentation
    }

    public static func newSecret() -> Data { Curve25519.Signing.PrivateKey().rawRepresentation }
}

/// A room epoch key sealed to one member's key agreement public key.
public enum KeyBox {
    static func info(room: String, epoch: Int, recipient: Data) -> Data {
        Data("pasa-keybox-v1|\(room)|\(epoch)|".utf8) + recipient
    }

    /// Box = ephemeral public key (32 bytes) + ChaCha20-Poly1305 combined box.
    public static func seal(_ epochKey: Data, to recipient: Data, room: String, epoch: Int) -> Data? {
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient) else { return nil }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? eph.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        let info = info(room: room, epoch: epoch, recipient: recipient)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("pasa-keybox-salt".utf8),
                                                 sharedInfo: info, outputByteCount: 32)
        guard let box = try? ChaChaPoly.seal(epochKey, using: key, authenticating: info) else { return nil }
        return eph.publicKey.rawRepresentation + box.combined
    }

    public static func open(_ box: Data, secret: Data, room: String, epoch: Int) -> Data? {
        guard box.count > 32,
              let me = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret),
              let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: box.prefix(32)),
              let shared = try? me.sharedSecretFromKeyAgreement(with: eph) else { return nil }
        let info = info(room: room, epoch: epoch, recipient: me.publicKey.rawRepresentation)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("pasa-keybox-salt".utf8),
                                                 sharedInfo: info, outputByteCount: 32)
        guard let sealed = try? ChaChaPoly.SealedBox(combined: box.dropFirst(32)) else { return nil }
        return try? ChaChaPoly.open(sealed, using: key, authenticating: info)
    }
}
