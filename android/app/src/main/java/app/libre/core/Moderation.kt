// Moderation.kt: Town Square moderation (issue #9), as ModerationState in
// Libre/Sources/Core/Moderation.swift. Our own design. The AI Mac's owner signs a hide record
// ({"at","message","room"}, domain "town-hide") and sends it as a sealed `moderation` message in
// Town Square. A phone applies it only when the signer is the admin key of a code room it joined, or
// an AI Mac the person chose to trust. Hidden messages leave the timeline and are never shown again.
package app.libre.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

data class HideRecord(val room: String, val message: String, val atMs: Long)

class ModerationState(trustedMacs: List<String> = emptyList(), records: List<SignedBlob> = emptyList(), hidden: Set<String> = emptySet()) {
    companion object {
        const val DOMAIN = "town-hide"
        const val MAX_RECORDS = 200

        /** Hide record signed by [identity] (the AI Mac; tests and vectors). */
        fun make(message: String, room: String, atMs: Long, identity: DeviceIdentity): SignedBlob {
            val body = JsonObject(sortedMapOf("at" to JsonPrimitive(atMs), "message" to JsonPrimitive(message.uppercase()), "room" to JsonPrimitive(room)))
            return identity.sign(Bytes.utf8(body.toString()), DOMAIN)
        }

        fun record(blob: SignedBlob): HideRecord? {
            val o = blob.bodyJson() ?: return null
            val room = (o["room"] as? JsonPrimitive)?.content ?: return null
            val message = (o["message"] as? JsonPrimitive)?.content?.uppercase() ?: return null
            return HideRecord(room, message, (o["at"] as? JsonPrimitive)?.longOrNull ?: 0)
        }

        fun fromJson(text: String): ModerationState {
            val o = MeshCodec.parseObject(Bytes.utf8(text)) ?: return ModerationState()
            val macs = (o["trustedMacs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: emptyList()
            val recs = (o["records"] as? JsonArray)?.mapNotNull { SignedBlob.fromJson(it as? JsonObject) } ?: emptyList()
            val hid = (o["hidden"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }?.toSet() ?: emptySet()
            return ModerationState(macs, recs, hid)
        }
    }

    /** Trusted AI Mac keys, hex. */
    private val macs = ArrayList(trustedMacs)
    private val recs = ArrayList(records)
    private val hiddenIds = HashSet(hidden)
    val records: List<SignedBlob> get() = recs.toList()

    fun accepts(blob: SignedBlob, room: String, adminKeys: Set<String>, ownKey: String? = null): HideRecord? {
        if (blob.domain != DOMAIN || !PasaSign.verify(blob)) return null
        val r = record(blob) ?: return null
        if (r.room != room) return null
        val signer = Bytes.hex(blob.signer)
        return if (signer in adminKeys || signer in macs || signer == ownKey) r else null
    }

    /** Applies an accepted hide. Returns the hidden message id when it is new. */
    fun apply(blob: SignedBlob, room: String, adminKeys: Set<String>, ownKey: String? = null): String? {
        val r = accepts(blob, room, adminKeys, ownKey) ?: return null
        if (!hiddenIds.add(r.message)) return null
        recs.add(blob)
        while (recs.size > MAX_RECORDS) recs.removeAt(0)
        return r.message
    }

    fun isHidden(id: String) = id.uppercase() in hiddenIds
    fun trusts(macHex: String) = macHex in macs
    fun setTrusted(macHex: String, on: Boolean) { macs.remove(macHex); if (on) macs.add(macHex) }

    fun toJson(): String = JsonObject(mapOf(
        "trustedMacs" to JsonArray(macs.map(::JsonPrimitive)),
        "records" to JsonArray(recs.map { it.toJson() }),
        "hidden" to JsonArray(hiddenIds.sorted().map(::JsonPrimitive)),
    )).toString()
}
