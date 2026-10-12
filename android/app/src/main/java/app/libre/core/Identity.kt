// Identity.kt: device keys, signed blobs and key boxes, as Libre/Sources/Core/Identity.swift.
// - Signing: Ed25519 (CryptoKit Curve25519.Signing; the 32-byte secret is the seed).
// - Key agreement: X25519 (CryptoKit Curve25519.KeyAgreement).
// - SignedBlob signs "pasa-<domain>-v1|" + exact body bytes. JSON: body, signer, sig as base64.
// - KeyBox: ephemeral X25519 public key (32) + ChaCha20-Poly1305 box of the epoch key, key from
//   HKDF-SHA256(shared, salt "pasa-keybox-salt", info "pasa-keybox-v1|<room>|<epoch>|" + recipient).
package app.libre.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

data class DeviceIdentity(val signSecret: ByteArray, val boxSecret: ByteArray) {
    val signKey: ByteArray by lazy { Crypto.ed25519Public(signSecret) }
    val boxKey: ByteArray by lazy { Crypto.x25519Public(boxSecret) }

    fun sign(body: ByteArray, domain: String): SignedBlob = PasaSign.sign(body, signSecret, domain)

    companion object {
        fun generate() = DeviceIdentity(Crypto.randomBytes(32), Crypto.randomBytes(32))
    }
}

data class SignedBlob(val body: ByteArray, val signer: ByteArray, val sig: ByteArray, val domain: String) {
    val isValid: Boolean get() = PasaSign.verify(this)

    fun toJson(): JsonObject = JsonObject(sortedMapOf(
        "body" to JsonPrimitive(Bytes.b64(body)), "domain" to JsonPrimitive(domain),
        "sig" to JsonPrimitive(Bytes.b64(sig)), "signer" to JsonPrimitive(Bytes.b64(signer)),
    ))

    fun bodyJson(): JsonObject? = MeshCodec.parseObject(body)

    companion object {
        fun fromJson(o: JsonObject?): SignedBlob? {
            o ?: return null
            fun b(k: String) = (o[k] as? JsonPrimitive)?.content?.let { Bytes.unb64(it) }
            return SignedBlob(b("body") ?: return null, b("signer") ?: return null, b("sig") ?: return null,
                (o["domain"] as? JsonPrimitive)?.content ?: return null)
        }
    }
}

object PasaSign {
    fun message(body: ByteArray, domain: String): ByteArray = Bytes.utf8("pasa-$domain-v1|") + body
    fun sign(body: ByteArray, secret: ByteArray, domain: String) =
        SignedBlob(body, Crypto.ed25519Public(secret), Crypto.ed25519Sign(secret, message(body, domain)), domain)
    fun verify(b: SignedBlob) = Crypto.ed25519Verify(b.signer, message(b.body, b.domain), b.sig)
}

object KeyBox {
    private val SALT = Bytes.utf8("pasa-keybox-salt")
    fun info(room: String, epoch: Int, recipient: ByteArray) = Bytes.utf8("pasa-keybox-v1|$room|$epoch|") + recipient

    fun seal(epochKey: ByteArray, recipient: ByteArray, room: String, epoch: Int): ByteArray? {
        val eph = Crypto.randomBytes(32)
        val shared = Crypto.x25519(eph, recipient) ?: return null
        val info = info(room, epoch, recipient)
        val key = Crypto.hkdf(shared, SALT, info, 32)
        return Crypto.x25519Public(eph) + Crypto.chachaSeal(epochKey, key, info)
    }

    fun open(box: ByteArray, secret: ByteArray, room: String, epoch: Int): ByteArray? {
        if (box.size <= 32) return null
        val shared = Crypto.x25519(secret, box.copyOfRange(0, 32)) ?: return null
        val info = info(room, epoch, Crypto.x25519Public(secret))
        val key = Crypto.hkdf(shared, SALT, info, 32)
        return Crypto.chachaOpen(box.copyOfRange(32, box.size), key, info)
    }
}
