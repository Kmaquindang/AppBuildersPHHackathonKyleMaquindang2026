// PeerSync.kt: phone-to-phone history sync without the AI Mac, as PeerSync in
// Libre/Sources/Core/PeerSync.swift (issue #6, our own design). On link, a phone asks the other for
// the active room's team chat from the last 6 hours it does not have: a `.sync` request with
// `window` (start, ms) and `knownShort` (12-hex-character ids, newest 400). The answer is ordinary
// sync batches. Only broadcast team chat travels this way; everything stays sealed with the room key.
package app.libre.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

object PeerSync {
    const val WINDOW_MS = 6 * 3600_000L
    const val MAX_KNOWN = 400
    const val MAX_MESSAGES = 100
    const val MAX_BYTES = 36_000
    const val ASK_EVERY_MS = 120_000L
    const val ANSWER_EVERY_MS = 60_000L
    const val FUTURE_SLACK_MS = 300_000L
    const val CHUNK_BYTES = 12_000

    data class Request(val windowMs: Long, val knownShort: Set<String>, val clearedAtMs: Long?)

    fun shortId(id: String): String = id.replace("-", "").take(12).lowercase()

    private fun isTeamChat(m: MeshMessage) = m.kind == Kind.CHAT && m.destination == null && m.silent != true

    /** Body of the request this phone sends a newly linked peer. */
    fun requestBody(messages: List<MeshMessage>, nowMs: Long): String {
        val start = nowMs - WINDOW_MS
        val mine = messages.filter { isTeamChat(it) && it.createdAt >= start }.distinctBy { it.id }.sortedBy { it.createdAt }
        return JsonObject(mapOf("request" to JsonObject(buildMap {
            mine.lastOrNull()?.let { put("newest", JsonPrimitive(it.createdAt)) }
            put("knownIDs", JsonArray(emptyList()))
            put("window", JsonPrimitive(start))
            put("knownShort", JsonArray(mine.takeLast(MAX_KNOWN).map { JsonPrimitive(shortId(it.id)) }))
        }))).toString()
    }

    /** The peer request inside a `.sync` body, or null (a plain Mac backfill request has no window). */
    fun parseRequest(o: JsonObject): Request? {
        val r = o["request"] as? JsonObject ?: return null
        val window = (r["window"] as? JsonPrimitive)?.longOrNull ?: return null
        val known = (r["knownShort"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }?.toSet() ?: emptySet()
        return Request(window, known, (r["clearedAt"] as? JsonPrimitive)?.longOrNull)
    }

    /** Team chat the asker is missing, oldest first, capped by count and bytes (newest kept). */
    fun select(messages: List<MeshMessage>, req: Request, nowMs: Long): List<MeshMessage> {
        val floor = maxOf(req.windowMs, req.clearedAtMs ?: Long.MIN_VALUE)
        val picked = messages.filter {
            isTeamChat(it) && it.createdAt >= floor && it.createdAt <= nowMs + FUTURE_SLACK_MS && shortId(it.id) !in req.knownShort
        }.distinctBy { it.id }.sortedBy { it.createdAt }.takeLast(MAX_MESSAGES)
        val kept = ArrayList<MeshMessage>()
        var bytes = 0
        for (m in picked.asReversed()) {
            val size = MeshCodec.encode(m).size
            if (bytes + size > MAX_BYTES) break
            bytes += size
            kept.add(m)
        }
        return kept.asReversed()
    }

    /** Sync batch bodies ({"batch":{"messages":[...],"part":n,"parts":total}}), each about 12 KB at most. */
    fun batchBodies(messages: List<MeshMessage>): List<String> {
        val chunks = ArrayList<List<MeshMessage>>()
        var current = ArrayList<MeshMessage>()
        var size = 0
        for (m in messages) {
            val b = MeshCodec.encode(m).size
            if (current.isNotEmpty() && size + b > CHUNK_BYTES) { chunks.add(current); current = ArrayList(); size = 0 }
            current.add(m); size += b
        }
        if (current.isNotEmpty()) chunks.add(current)
        return chunks.mapIndexed { i, c ->
            JsonObject(mapOf("batch" to JsonObject(mapOf(
                "messages" to JsonArray(c.map(MeshCodec::toJson)),
                "part" to JsonPrimitive(i + 1), "parts" to JsonPrimitive(chunks.size))))).toString()
        }
    }
}
