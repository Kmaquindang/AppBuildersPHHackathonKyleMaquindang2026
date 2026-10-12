// Org.kt: what a phone caches from the AI Mac: tasks, rules (read only), Knowledge titles, and
// the sync payloads that carry them (OrgModels.swift, LibraryModels.swift, Timeline.swift).
package app.libre.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

@Serializable
data class TaskItem(val id: String, val title: String, val assignee: String? = null, val due: String? = null,
                    val status: String = "open", val createdBy: String = "") {
    val shortLine: String get() {
        val extras = listOfNotNull(assignee?.takeIf { it.isNotEmpty() }, due?.takeIf { it.isNotEmpty() }?.let { "due $it" })
        return title + if (extras.isEmpty()) "" else " (${extras.joinToString(", ")})"
    }

    companion object {
        fun decode(body: String): TaskItem? {
            val o = MeshCodec.parseObject(Bytes.utf8(body)) ?: return null
            fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return TaskItem(s("id")?.uppercase() ?: return null, s("title") ?: return null, s("assignee"), s("due"), s("status") ?: "open", s("createdBy") ?: "")
        }
    }
}

@Serializable
data class RuleItem(val id: String, val kind: String, val title: String, val body: String, val version: Int, val retired: Boolean = false) {
    val citation: String get() = "[${if (kind == "skill") "Skill" else "Rule"}: $title v$version]"

    companion object {
        fun decode(body: String): RuleItem? {
            val o = MeshCodec.parseObject(Bytes.utf8(body)) ?: return null
            fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return RuleItem(s("id")?.uppercase() ?: return null, s("kind") ?: "rule", s("title") ?: return null, s("body") ?: "",
                (o["version"] as? JsonPrimitive)?.intOrNull ?: 1, (o["retired"] as? JsonPrimitive)?.booleanOrNull ?: false)
        }
    }
}

@Serializable
data class LibraryListing(val title: String, val version: Int, val pages: Int, val visibility: String)

/** What a .sync body carries that a phone uses: the Mac's memory manifest, or a backfill batch. */
data class SyncPayload(val ruleIds: List<String>?, val taskIds: List<String>?, val library: List<LibraryListing>?, val batch: List<MeshMessage>?) {
    companion object {
        fun decode(body: String): SyncPayload? {
            val o = MeshCodec.parseObject(Bytes.utf8(body)) ?: return null
            val m = o["manifest"] as? JsonObject
            val ids = { k: String -> (m?.get(k) as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content?.uppercase() } }
            val lib = (m?.get("library") as? JsonArray)?.mapNotNull { e ->
                val l = e as? JsonObject ?: return@mapNotNull null
                LibraryListing((l["title"] as? JsonPrimitive)?.content ?: return@mapNotNull null, (l["version"] as? JsonPrimitive)?.intOrNull ?: 1,
                    (l["pages"] as? JsonPrimitive)?.intOrNull ?: 0, (l["visibility"] as? JsonPrimitive)?.content ?: "everyone")
            }
            val batch = ((o["batch"] as? JsonObject)?.get("messages") as? JsonArray)?.mapNotNull { (it as? JsonObject)?.let(MeshCodec::fromJson) }
            return SyncPayload(m?.let { ids("ruleIDs") }, m?.let { ids("taskIDs") }, lib, batch)
        }

        /** Phone to AI Mac on link: "send me what I missed" (SyncRequest). */
        fun request(newestMs: Long?, knownIds: List<String>): String = JsonObject(mapOf("request" to JsonObject(buildMap {
            newestMs?.let { put("newest", JsonPrimitive(it)) }
            put("knownIDs", JsonArray(knownIds.takeLast(150).map(::JsonPrimitive)))
        }))).toString()
    }
}

/** "@libre ..." (or "@pasa ...") at the start: the text after it, or null (AssistantMention.strip). */
object AssistantMention {
    const val PRIMARY = "@libre"
    private val aliases = listOf("@libre", "@pasa")

    fun strip(raw: String): String? {
        val text = raw.trim()
        val lower = text.lowercase()
        for (tag in aliases) {
            if (!lower.startsWith(tag)) continue
            val rest = text.substring(tag.length)
            val next = rest.firstOrNull()
            if (next != null && (next.isLetterOrDigit() || next == '_')) continue
            return rest.trimStart(':', ',').trim()
        }
        return null
    }
}
