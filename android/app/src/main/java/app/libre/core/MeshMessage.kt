// MeshMessage.kt: the packet that travels over the mesh, with the exact JSON field names and
// shapes Swift's Codable uses (Libre/Sources/Core/MeshMessage.swift):
// - id, replyTo, retryOf: UUID strings (Swift writes them uppercase).
// - createdAt, since: milliseconds since 1970 (JSONEncoder .millisecondsSince1970).
// - destination: {"peer":{"_0":"name"}} or {"role":{"_0":"ai"}}; absent means broadcast.
// - Optional fields are left out when nil, as Swift does.
// Relays never re-encode a packet: they rewrite ttl and hops on the raw JSON (RelayEngine), so
// fields this build does not know survive the hop.
package app.libre.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.UUID

sealed class Destination {
    data class Peer(val name: String) : Destination()
    data class Role(val role: String) : Destination()

    /** Same text Swift's MeshDestination.label gives (used in the sealed packet's AAD). */
    val label: String get() = when (this) { is Peer -> name; is Role -> "@$role" }

    companion object { const val AI_ROLE = "ai" }
}

/** Message kinds this build understands (MessageKind raw values). */
object Kind {
    const val CHAT = "chat"; const val ASK = "ask"; const val ANSWER = "answer"; const val ACK = "ack"
    const val RULE = "rule"; const val TASK = "task"; const val SYNC = "sync"; const val SEALED = "sealed"
    const val MEDIA = "media"; const val CHUNK = "chunk"; const val MEDIA_NACK = "mediaNack"; const val TRANSCRIPT = "transcript"
    const val ROOM_CONTROL = "roomControl"; const val BEACON = "beacon"; const val AI_STATUS = "aiStatus"
    /** Piece of an answer still being written (sealed only; AnswerStream.kt). */
    const val ANSWER_PART = "answerPart"
    /** Signed Town Square hide record from the AI Mac's owner (sealed only; Moderation.kt). */
    const val MODERATION = "moderation"
    val all = setOf(CHAT, ASK, ANSWER, ACK, RULE, TASK, SYNC, SEALED, MEDIA, CHUNK, MEDIA_NACK, TRANSCRIPT, ROOM_CONTROL, BEACON, AI_STATUS, ANSWER_PART, MODERATION)
}

data class DocRef(val title: String, val page: Int?, val version: Int, val excerpt: String) {
    /** "Site safety, p.2, v1" */
    val chipLabel: String get() = listOfNotNull(title, page?.let { "p.$it" }, "v$version").joinToString(", ")
}

data class MeshMessage(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val origin: String,
    val destination: Destination? = null,
    val kind: String,
    val body: String,
    val ttl: Int = DEFAULT_TTL,
    val hops: List<String> = listOf(origin),
    val createdAt: Long = System.currentTimeMillis(),
    val replyTo: String? = null,
    val replyPath: List<String>? = null,
    val senderName: String? = null,
    val v: Int? = null,
    val silent: Boolean? = null,
    val since: Long? = null,
    val checked: List<String>? = null,
    val room: String? = null,
    val sealed: String? = null,
    val epoch: Int? = null,
    val retryOf: String? = null,
    val rulesUsed: List<String>? = null,
    val unverifiedRules: List<String>? = null,
    val noRule: Boolean? = null,
    val docRefs: List<DocRef>? = null,
    val card: String? = null,
    val model: String? = null,
    val latencyMs: Int? = null,
    /** For answer parts: 0, 1, 2... in the order the AI Mac wrote them. */
    val part: Int? = null,
    /** AIProof as raw JSON (shown in Details), kept as is. */
    val proof: JsonObject? = null,
    /** Any other field (forward compatible), kept when re-encoding an inner message. */
    val extra: Map<String, JsonElement> = emptyMap(),
) {
    val wireVersion: Int get() = v ?: 1
    val isBroadcast: Boolean get() = destination == null
    val hopCount: Int get() = maxOf(0, hops.size - 1)

    companion object {
        const val DEFAULT_TTL = 7
        const val PROTOCOL_VERSION = 2
    }
}

object MeshCodec {
    val json = Json { ignoreUnknownKeys = true; isLenient = false }

    private val known = setOf("id", "origin", "destination", "kind", "body", "ttl", "hops", "createdAt", "replyTo", "replyPath",
        "senderName", "v", "silent", "since", "checked", "room", "sealed", "epoch", "retryOf", "rulesUsed", "unverifiedRules",
        "noRule", "docRefs", "card", "model", "latencyMs", "part", "proof")

    fun toJson(m: MeshMessage): JsonObject {
        val o = LinkedHashMap<String, JsonElement>()
        o.putAll(m.extra)
        o["id"] = JsonPrimitive(m.id)
        o["origin"] = JsonPrimitive(m.origin)
        m.destination?.let { o["destination"] = destinationJson(it) }
        o["kind"] = JsonPrimitive(m.kind)
        o["body"] = JsonPrimitive(m.body)
        o["ttl"] = JsonPrimitive(m.ttl)
        o["hops"] = JsonArray(m.hops.map { JsonPrimitive(it) })
        o["createdAt"] = JsonPrimitive(m.createdAt)
        m.replyTo?.let { o["replyTo"] = JsonPrimitive(it) }
        m.replyPath?.let { o["replyPath"] = JsonArray(it.map(::JsonPrimitive)) }
        m.senderName?.let { o["senderName"] = JsonPrimitive(it) }
        m.v?.let { o["v"] = JsonPrimitive(it) }
        m.silent?.let { o["silent"] = JsonPrimitive(it) }
        m.since?.let { o["since"] = JsonPrimitive(it) }
        m.checked?.let { o["checked"] = JsonArray(it.map(::JsonPrimitive)) }
        m.room?.let { o["room"] = JsonPrimitive(it) }
        m.sealed?.let { o["sealed"] = JsonPrimitive(it) }
        m.epoch?.let { o["epoch"] = JsonPrimitive(it) }
        m.retryOf?.let { o["retryOf"] = JsonPrimitive(it) }
        m.rulesUsed?.let { o["rulesUsed"] = JsonArray(it.map(::JsonPrimitive)) }
        m.unverifiedRules?.let { o["unverifiedRules"] = JsonArray(it.map(::JsonPrimitive)) }
        m.noRule?.let { o["noRule"] = JsonPrimitive(it) }
        m.docRefs?.let { refs ->
            o["docRefs"] = JsonArray(refs.map { r ->
                JsonObject(buildMap {
                    put("title", JsonPrimitive(r.title)); r.page?.let { put("page", JsonPrimitive(it)) }
                    put("version", JsonPrimitive(r.version)); put("excerpt", JsonPrimitive(r.excerpt))
                })
            })
        }
        m.card?.let { o["card"] = JsonPrimitive(it) }
        m.model?.let { o["model"] = JsonPrimitive(it) }
        m.latencyMs?.let { o["latencyMs"] = JsonPrimitive(it) }
        m.part?.let { o["part"] = JsonPrimitive(it) }
        m.proof?.let { o["proof"] = it }
        return JsonObject(o)
    }

    fun encode(m: MeshMessage): ByteArray = Bytes.utf8(toJson(m).toString())

    fun destinationJson(d: Destination): JsonObject = when (d) {
        is Destination.Peer -> JsonObject(mapOf("peer" to JsonObject(mapOf("_0" to JsonPrimitive(d.name)))))
        is Destination.Role -> JsonObject(mapOf("role" to JsonObject(mapOf("_0" to JsonPrimitive(d.role)))))
    }

    fun parseDestination(e: JsonElement?): Destination? {
        if (e == null || e is JsonNull) return null
        val o = e as? JsonObject ?: return null
        o["peer"]?.let { return Destination.Peer(inner(it) ?: return null) }
        o["role"]?.let { return Destination.Role(inner(it) ?: return null) }
        return null
    }

    private fun inner(e: JsonElement): String? = (e as? JsonObject)?.get("_0")?.let { (it as? JsonPrimitive)?.content }

    fun parseObject(data: ByteArray): JsonObject? = try {
        json.parseToJsonElement(String(data, Charsets.UTF_8)) as? JsonObject
    } catch (e: Exception) {
        null
    }

    private fun str(o: JsonObject, k: String): String? = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun strList(o: JsonObject, k: String): List<String>? = (o[k] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }
    private fun ms(o: JsonObject, k: String): Long? = (o[k] as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }

    /** Full decode, or null when a required field is missing or the kind is unknown. */
    fun fromJson(o: JsonObject): MeshMessage? {
        return try {
            val id = str(o, "id") ?: return null
            val origin = str(o, "origin") ?: return null
            val kind = str(o, "kind") ?: return null
            if (kind !in Kind.all) return null
            val ttl = (o["ttl"] as? JsonPrimitive)?.intOrNull ?: return null
            val hops = strList(o, "hops") ?: return null
            val createdAt = ms(o, "createdAt") ?: return null
            MeshMessage(
                id = id.uppercase(), origin = origin, destination = parseDestination(o["destination"]), kind = kind,
                body = str(o, "body") ?: return null, ttl = ttl, hops = hops, createdAt = createdAt,
                replyTo = str(o, "replyTo")?.uppercase(), replyPath = strList(o, "replyPath"), senderName = str(o, "senderName"),
                v = (o["v"] as? JsonPrimitive)?.intOrNull, silent = (o["silent"] as? JsonPrimitive)?.booleanOrNull,
                since = ms(o, "since"), checked = strList(o, "checked"), room = str(o, "room"), sealed = str(o, "sealed"),
                epoch = (o["epoch"] as? JsonPrimitive)?.intOrNull, retryOf = str(o, "retryOf")?.uppercase(),
                rulesUsed = strList(o, "rulesUsed"), unverifiedRules = strList(o, "unverifiedRules"),
                noRule = (o["noRule"] as? JsonPrimitive)?.booleanOrNull,
                docRefs = (o["docRefs"] as? JsonArray)?.mapNotNull { e ->
                    val r = e as? JsonObject ?: return@mapNotNull null
                    DocRef(str(r, "title") ?: return@mapNotNull null, (r["page"] as? JsonPrimitive)?.intOrNull,
                        (r["version"] as? JsonPrimitive)?.intOrNull ?: 1, str(r, "excerpt") ?: "")
                },
                card = str(o, "card"), model = str(o, "model"), latencyMs = (o["latencyMs"] as? JsonPrimitive)?.intOrNull,
                part = (o["part"] as? JsonPrimitive)?.intOrNull,
                proof = o["proof"] as? JsonObject,
                extra = o.filterKeys { it !in known },
            )
        } catch (e: Exception) {
            null
        }
    }

    fun decode(data: ByteArray): MeshMessage? = parseObject(data)?.let(::fromJson)
}

/** A received packet: the parsed message when this build reads it, plus the raw JSON for relaying. */
data class Packet(val raw: JsonObject, val message: MeshMessage?) {
    val id: String? get() = (raw["id"] as? JsonPrimitive)?.content?.uppercase()
    val origin: String? get() = (raw["origin"] as? JsonPrimitive)?.content
    val ttl: Int? get() = (raw["ttl"] as? JsonPrimitive)?.intOrNull
    val hops: List<String>? get() = (raw["hops"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }
    val destination: Destination? get() = MeshCodec.parseDestination(raw["destination"])
    val room: String? get() = (raw["room"] as? JsonPrimitive)?.content
    val kind: String? get() = (raw["kind"] as? JsonPrimitive)?.content

    /** Raw bytes with only ttl and hops replaced (OpaquePacket.rewritten in Swift). */
    fun rewritten(ttl: Int, hops: List<String>): ByteArray {
        val m = LinkedHashMap(raw)
        m["ttl"] = JsonPrimitive(ttl)
        m["hops"] = JsonArray(hops.map(::JsonPrimitive))
        return Bytes.utf8(JsonObject(m).toString())
    }

    companion object {
        /** null when the bytes are not a Libre packet with readable routing fields. */
        fun parse(data: ByteArray): Packet? {
            val o = MeshCodec.parseObject(data) ?: return null
            val p = Packet(o, null)
            if (p.id == null || p.origin == null || p.ttl == null || p.hops == null) return null
            val m = MeshCodec.fromJson(o)?.takeIf { it.wireVersion <= MeshMessage.PROTOCOL_VERSION }
            return Packet(o, m)
        }
    }
}
