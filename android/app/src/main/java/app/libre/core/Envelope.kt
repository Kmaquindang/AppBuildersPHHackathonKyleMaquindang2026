// Envelope.kt: room-sealed packets, as RoomEnvelope in Libre/Sources/Core/Rooms.swift.
// Outer packet: routing fields in the clear (v, id, origin, destination, ttl, hops, room tag,
// epoch), everything else sealed with ChaCha20-Poly1305 under HKDF(room key). AAD =
// "<v>|<UUID uppercase>|<room tag>|<origin>|<destination label or *>[|e<epoch>]".
package app.libre.core

object RoomEnvelope {
    fun aad(m: MeshMessage, room: String): ByteArray {
        var text = "${m.wireVersion}|${m.id.uppercase()}|$room|${m.origin}|${m.destination?.label ?: "*"}"
        val e = m.epoch
        if (e != null && e > 0) text += "|e$e"
        return Bytes.utf8(text)
    }

    /**
     * Seals [inner] for a room. [key] is the epoch key for content (or the base key at epoch 0 and
     * for room control). [nonce] is only fixed in tests.
     */
    fun seal(inner: MeshMessage, roomTag: String, key: ByteArray, epoch: Int, nonce: ByteArray = Crypto.randomBytes(12)): MeshMessage {
        val plain = inner.copy(v = MeshMessage.PROTOCOL_VERSION, epoch = null)
        val body = MeshCodec.encode(plain)
        val outer0 = MeshMessage(
            id = inner.id, origin = inner.origin, destination = inner.destination, kind = Kind.SEALED, body = "",
            ttl = inner.ttl, hops = inner.hops, createdAt = 0, v = MeshMessage.PROTOCOL_VERSION,
            room = roomTag, epoch = if (epoch > 0) epoch else null,
        )
        val box = RoomKeys.seal(body, key, aad(outer0, roomTag), nonce)
        return outer0.copy(sealed = Bytes.b64url(box))
    }

    /** Opens with [key]; null when it is another room's packet, tampered with, or the header does not match. */
    fun open(outer: MeshMessage, roomTag: String, key: ByteArray): MeshMessage? {
        if (outer.kind != Kind.SEALED || outer.room != roomTag) return null
        val box = outer.sealed?.let { Bytes.unb64url(it) } ?: return null
        val plain = RoomKeys.open(box, key, aad(outer, roomTag)) ?: return null
        val inner = MeshCodec.decode(plain) ?: return null
        if (inner.id.uppercase() != outer.id.uppercase() || inner.origin != outer.origin || inner.destination != outer.destination) return null
        return inner.copy(hops = outer.hops, ttl = outer.ttl, epoch = outer.epoch)
    }
}
