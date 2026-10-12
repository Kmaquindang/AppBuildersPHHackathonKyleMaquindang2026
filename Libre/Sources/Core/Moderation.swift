// Moderation.swift
// Libre: Town Square moderation (issue #9, Oct 2026). Our own design. Pure, tested on Linux.
//
// Town Square has no admin, so nobody could remove a message there. Now the AI Mac's owner can
// hide one for everyone: the Mac signs a hide record (its device key, domain "town-hide") naming
// the room and the message id, and sends it as a `.moderation` message sealed in Town Square.
// Builds without the kind drop it unread and keep showing the message.
//
// Which keys a phone accepts hides from (Town Square has no manifest to pin a key):
// - the admin key of any code room this phone joined (already checked against the room code and
//   its signed manifest when it joined), and
// - an AI Mac the person explicitly chose to trust ("Let this AI Mac hide Town Square messages").
// A Mac that merely shows up nearby is never trusted on its own, so it cannot censor Town Square.
// A hidden message leaves the timeline, is never backfilled or synced phone to phone, and is not
// shown again if it arrives later.

import Foundation

public struct HideRecord: Codable, Equatable, Sendable {
    public var room: String
    public var message: UUID
    public var at: Date

    public init(room: String, message: UUID, at: Date) {
        self.room = room
        self.message = message
        self.at = at
    }
}

public struct ModerationState: Codable, Equatable, Sendable {
    public static let domain = "town-hide"
    /// Hide records kept to pass on to devices that link later.
    public static let maxRecords = 200

    /// AI Mac keys the person chose to trust for Town Square hides.
    public private(set) var trustedMacs: [Data] = []
    /// Accepted hide records (signed), oldest first.
    public private(set) var records: [SignedBlob] = []
    public private(set) var hidden: Set<UUID> = []

    public init() {}

    /// The AI Mac's hide record for `message`.
    public static func make(message: UUID, room: String, at: Date = Date(), identity: DeviceIdentity) -> SignedBlob? {
        guard let body = try? PasaJSON.encoder.encode(HideRecord(room: room, message: message, at: at)) else { return nil }
        return identity.sign(body, domain: domain)
    }

    /// The record inside `blob` when it is a valid hide for `room` signed by one of `adminKeys` (code
    /// rooms this device joined), a trusted AI Mac, or `ownKey` (this device's own hides).
    public func accepts(_ blob: SignedBlob, room: String, adminKeys: Set<Data>, ownKey: Data? = nil) -> HideRecord? {
        guard blob.domain == ModerationState.domain, blob.isValid, let r = blob.decode(HideRecord.self), r.room == room else { return nil }
        guard adminKeys.contains(blob.signer) || trustedMacs.contains(blob.signer) || blob.signer == ownKey else { return nil }
        return r
    }

    /// Applies a hide when it is accepted. Returns the hidden message id when it is new.
    @discardableResult
    public mutating func apply(_ blob: SignedBlob, room: String, adminKeys: Set<Data>, ownKey: Data? = nil) -> UUID? {
        guard let r = accepts(blob, room: room, adminKeys: adminKeys, ownKey: ownKey), hidden.insert(r.message).inserted else { return nil }
        records.append(blob)
        if records.count > ModerationState.maxRecords { records.removeFirst(records.count - ModerationState.maxRecords) }
        return r.message
    }

    public func isHidden(_ id: UUID) -> Bool { hidden.contains(id) }

    public func trusts(mac key: Data) -> Bool { trustedMacs.contains(key) }

    public mutating func setTrusted(mac key: Data, _ on: Bool) {
        trustedMacs.removeAll { $0 == key }
        if on { trustedMacs.append(key) }
    }
}
