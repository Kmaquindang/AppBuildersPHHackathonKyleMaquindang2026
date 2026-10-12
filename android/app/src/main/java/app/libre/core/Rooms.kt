// Rooms.kt: room names, keys, tags and codes, byte for byte as Libre/Sources/Core/Rooms.swift,
// RoomKDF.swift and JoinCode.swift.
package app.libre.core

import java.text.Normalizer

object RoomNames {
    const val DEFAULT_LABEL = "DEFAULT"
    const val TOWN_SQUARE = "Town Square"
    private const val ALLOWED = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"

    /** A-Z, 0-9 and "-", runs of spaces become one "-", at most 24 characters. */
    fun cleanLabel(raw: String): String {
        val words = mutableListOf<String>()
        val cur = StringBuilder()
        for (ch in raw.uppercase()) {
            if (ch.isWhitespace()) { if (cur.isNotEmpty()) { words.add(cur.toString()); cur.clear() } } else cur.append(ch)
        }
        if (cur.isNotEmpty()) words.add(cur.toString())
        val upper = words.joinToString("-")
        return upper.filter { it in ALLOWED }.take(24)
    }

    fun normalizedName(raw: String): String = cleanLabel(raw).lowercase()

    fun isReserved(label: String): Boolean {
        val c = cleanLabel(label)
        return c == DEFAULT_LABEL || c == cleanLabel(TOWN_SQUARE)
    }

    /** Trimmed, Unicode NFC (Swift precomposedStringWithCanonicalMapping). */
    fun normalizedPasscode(raw: String): String = Normalizer.normalize(raw.trim(), Normalizer.Form.NFC)
}

object RoomKeys {
    const val ROUNDS = 600_000
    const val APP_SALT = "pasa-room-passcode-v1|"
    private val SALT = Bytes.utf8("pasa-room-v1")

    /** Published key of the open room (Town Square): SHA-256 of a fixed string. */
    val defaultKey: ByteArray = Crypto.sha256(Bytes.utf8("pasa-default-room-v1"))

    fun salt(name: String): ByteArray = Bytes.utf8(APP_SALT + RoomNames.normalizedName(name))

    /** Slow on purpose (PBKDF2, 600,000 rounds): call off the main thread. */
    fun passcodeKey(name: String, passcode: String, rounds: Int = ROUNDS): ByteArray =
        Crypto.pbkdf2(Bytes.utf8(RoomNames.normalizedPasscode(passcode)), salt(name), rounds, 32)

    private fun derive(key: ByteArray, info: String, n: Int) = Crypto.hkdf(key, SALT, Bytes.utf8(info), n)

    /** 8-byte room tag as 16 hex characters: the room id on the wire. */
    fun tag(key: ByteArray): String = Bytes.hex(derive(key, "pasa-room-tag", 8))

    fun sealingKey(key: ByteArray): ByteArray = derive(key, "pasa-room-seal", 32)

    fun seal(plain: ByteArray, key: ByteArray, aad: ByteArray, nonce: ByteArray = Crypto.randomBytes(12)): ByteArray =
        Crypto.chachaSeal(plain, sealingKey(key), aad, nonce)

    fun open(combined: ByteArray, key: ByteArray, aad: ByteArray): ByteArray? = Crypto.chachaOpen(combined, sealingKey(key), aad)
}

object JoinCode {
    const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    const val LENGTH = 8

    /** "k7qm 3xrf" -> "K7QM3XRF", null when not a valid code. */
    fun normalize(typed: String): String? {
        val raw = typed.uppercase().filter { !it.isWhitespace() && it != '-' }
        return if (raw.length == LENGTH && raw.all { it in ALPHABET }) raw else null
    }

    fun format(raw: String): String = if (raw.length == LENGTH) raw.take(4) + "-" + raw.takeLast(4) else raw
    fun isValid(typed: String) = normalize(typed) != null
}

object CodeRoom {
    private const val DOMAIN = "pasa-code-room-v1|"

    fun baseKey(name: String): ByteArray = Crypto.sha256(Bytes.utf8(DOMAIN + RoomNames.normalizedName(name)))

    fun codeKey(name: String, code: String, rounds: Int = RoomKeys.ROUNDS): ByteArray? {
        val clean = JoinCode.normalize(code) ?: return null
        return RoomKeys.passcodeKey(name, "code:$clean", rounds)
    }

    fun proof(codeKey: ByteArray, room: String, signKey: ByteArray): ByteArray =
        Crypto.hmacSha256(codeKey, Bytes.utf8("join|"), Bytes.utf8(room), Bytes.utf8("|"), signKey)

    fun check(codeKey: ByteArray, adminKey: ByteArray): ByteArray =
        Crypto.hmacSha256(codeKey, Bytes.utf8("admin|"), adminKey)

    fun same(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].toInt() xor b[i].toInt())
        return diff == 0
    }
}

/** libre://join?room=BOHOL-7&code=K7QM-3XRF&v=1[&exp=unix seconds] (pasa:// still accepted). */
data class JoinLink(val room: String, val code: String, val expiresAtMs: Long?) {
    companion object {
        fun parse(text: String): JoinLink? {
            val t = text.trim()
            val m = Regex("^(libre|pasa)://join\\?(.*)$", RegexOption.IGNORE_CASE).find(t) ?: return null
            val items = m.groupValues[2].split("&").mapNotNull {
                val i = it.indexOf('=')
                if (i <= 0) null else it.substring(0, i) to java.net.URLDecoder.decode(it.substring(i + 1), "UTF-8")
            }.toMap()
            if (items["v"] != "1") return null
            val room = RoomNames.cleanLabel(items["room"] ?: "")
            if (room.isEmpty() || RoomNames.isReserved(room)) return null
            val code = items["code"]?.let { JoinCode.normalize(it) } ?: return null
            val exp = items["exp"]?.toDoubleOrNull()?.let { (it * 1000).toLong() }
            return JoinLink(room, JoinCode.format(code), exp)
        }
    }
}
