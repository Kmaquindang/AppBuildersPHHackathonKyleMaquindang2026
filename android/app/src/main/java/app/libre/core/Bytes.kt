// Bytes.kt: hex and base64 helpers shared by the core (pure Kotlin, JVM tested).
package app.libre.core

import java.util.Base64

object Bytes {
    fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    fun unhex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    /** Standard base64 with padding: how Swift's JSONEncoder writes `Data`. */
    fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    fun unb64(s: String): ByteArray? = try { Base64.getDecoder().decode(s) } catch (e: IllegalArgumentException) { null }

    /** base64url without padding (RoomCrypto.base64url). */
    fun b64url(b: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    fun unb64url(s: String): ByteArray? = try { Base64.getUrlDecoder().decode(s) } catch (e: IllegalArgumentException) { null }

    fun utf8(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)
}
