// RoomKDF.swift
// Pasa: Wi-Fi style rooms. A room has a NAME and a PASSCODE. The 256-bit room key is derived from
// the passcode with PBKDF2-HMAC-SHA256 (600,000 rounds), salted with a fixed app salt plus the
// normalized room name, so the same name and passcode give the same key on every device and the
// same passcode in another room gives a different key. Pure Swift, tested on Linux.
//
// - Apple platforms: CommonCrypto CCKeyDerivationPBKDF (fast, native).
// - Linux test build: a small pure-Swift PBKDF2 over HMAC<SHA256> (swift-crypto). The same pure
//   Swift code also compiles on Apple so the tests check both paths give identical bytes, plus the
//   RFC 7914 section 11 PBKDF2-HMAC-SHA256 vectors and an app vector computed independently.
//
// Derivation is deliberately slow (about half a second to a second on an iPhone). Call it off the
// main thread (MeshService does, and the UI shows a spinner).

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

public enum PBKDF2SHA256 {
    /// Pure Swift PBKDF2-HMAC-SHA256 (RFC 8018). Used on Linux, and on Apple as a cross-check.
    public static func deriveSwift(password: Data, salt: Data, rounds: Int, length: Int) -> Data {
        precondition(rounds >= 1 && length >= 1)
        let keyed = HMAC<SHA256>(key: SymmetricKey(data: password))
        var output = Data()
        output.reserveCapacity(length)
        var block: UInt32 = 1
        while output.count < length {
            var first = keyed
            first.update(data: salt)
            first.update(data: withUnsafeBytes(of: block.bigEndian) { Data($0) })
            var u = Array(first.finalize().withUnsafeBytes { Data($0) })
            var t = u
            if rounds > 1 {
                for _ in 1..<rounds {
                    var mac = keyed   // HMAC is a value type: copying reuses the keyed pads
                    mac.update(data: u)
                    u = mac.finalize().withUnsafeBytes { Array($0) }
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            output.append(contentsOf: t)
            block += 1
        }
        return output.prefix(length)
    }

    #if canImport(CommonCrypto)
    /// CommonCrypto PBKDF2-HMAC-SHA256 (Apple only). nil if CommonCrypto reports an error.
    public static func deriveCommonCrypto(password: Data, salt: Data, rounds: Int, length: Int) -> Data? {
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBytes { pw -> Int32 in
            salt.withUnsafeBytes { s -> Int32 in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     &out, length)
            }
        }
        return status == Int32(kCCSuccess) ? Data(out) : nil
    }
    #endif

    /// Fastest available implementation for this platform.
    public static func derive(password: Data, salt: Data, rounds: Int, length: Int) -> Data {
        #if canImport(CommonCrypto)
        if let fast = deriveCommonCrypto(password: password, salt: salt, rounds: rounds, length: length) { return fast }
        #endif
        return deriveSwift(password: password, salt: salt, rounds: rounds, length: length)
    }
}

/// Room name and passcode rules, and the room key derivation.
public enum RoomPasscode {
    /// OWASP 2023 guidance for PBKDF2-HMAC-SHA256.
    public static let rounds = 600_000
    public static let minLength = 6
    /// Fixed app salt; the normalized room name is appended.
    public static let appSalt = "pasa-room-passcode-v1|"

    public enum Strength: String, Sendable { case tooShort, weak, fair, strong }

    /// Room name used in the salt: the shown label (A-Z, 0-9, "-"), lowercased. "Bohol 7",
    /// " bohol-7 " and "BOHOL-7" are the same room.
    public static func normalizedName(_ raw: String) -> String {
        Room.cleanLabel(raw).lowercased()
    }

    /// Passcodes keep their case and inner spaces; leading and trailing whitespace is dropped
    /// (phone keyboards add a trailing space) and Unicode is normalized (NFC).
    public static func normalizedPasscode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    public static func salt(forName name: String) -> Data {
        Data((appSalt + normalizedName(name)).utf8)
    }

    /// The 256-bit room key. Slow on purpose: call off the main thread.
    public static func deriveKey(name: String, passcode: String, rounds: Int = rounds) -> Data {
        PBKDF2SHA256.derive(password: Data(normalizedPasscode(passcode).utf8), salt: salt(forName: name),
                            rounds: rounds, length: 32)
    }

    static let common: Set<String> = [
        "123456", "1234567", "12345678", "123456789", "1234567890", "000000", "111111", "121212", "123123",
        "654321", "666666", "696969", "112233", "password", "password1", "qwerty", "qwerty123", "abc123",
        "abcdef", "iloveyou", "letmein", "welcome", "admin123", "pasa123", "pasapasa", "mahalkita", "ilovepasa",
    ]

    /// Simple strength hint: length, character variety, and a short list of very common passcodes.
    /// Not a guarantee. Anyone who records room traffic can try guesses offline, so longer is better.
    public static func strength(_ raw: String) -> Strength {
        let code = normalizedPasscode(raw)
        if code.count < minLength { return .tooShort }
        let lower = code.lowercased()
        if common.contains(lower) || Set(lower).count <= 2 { return .weak }
        var classes = 0
        if code.contains(where: { $0.isLowercase }) { classes += 1 }
        if code.contains(where: { $0.isUppercase }) { classes += 1 }
        if code.contains(where: { $0.isNumber }) { classes += 1 }
        if code.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        if code.allSatisfy({ $0.isNumber }) { return code.count >= 10 ? .fair : .weak }
        if code.count >= 12 && classes >= 2 { return .strong }
        if code.count >= 10 || (code.count >= 8 && classes >= 3) { return .fair }
        return .weak
    }

    public static func hint(_ raw: String) -> String {
        switch strength(raw) {
        case .tooShort: return "At least \(minLength) characters."
        case .weak: return "Weak: easy to guess. Use 3 or 4 words, or mix letters, numbers and symbols."
        case .fair: return "Fair. Longer is safer, for example 3 or 4 words."
        case .strong: return "Strong."
        }
    }

    public static func isAcceptable(_ raw: String) -> Bool { strength(raw) != .tooShort }
}
