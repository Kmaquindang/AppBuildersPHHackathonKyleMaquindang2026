// AnswerStream.kt: streamed @libre answers on the phone side, as AnswerStreams in
// Libre/Sources/Core/AnswerStream.swift (issue #2, our own design). The AI Mac sends `answerPart`
// messages (replyTo = ask id, part = 0, 1, 2..., body = text added since the previous part) and
// then the whole `answer`, which replaces them. Only the in-order prefix shows; a part after a gap
// waits. Late parts after the final answer are ignored; a stream with no final answer within
// TIMEOUT_MS is dropped. Android never answers asks, so it has no sender side.
package app.libre.core

class AnswerStreams {
    companion object {
        const val TIMEOUT_MS = 120_000L
        const val MAX_PARTS = 16
        const val MAX_CHARS = 2000
    }

    private class Stream(val room: String, var updated: Long) {
        val parts = HashMap<Int, String>()
        var chars = 0
    }

    private val streams = HashMap<String, Stream>()
    private val finished = HashMap<String, Long>()

    /** Adds one part. Returns true when the text shown for that ask changed. */
    fun add(askId: String, seq: Int, text: String, room: String, now: Long): Boolean {
        if (askId in finished || seq < 0 || seq >= MAX_PARTS || text.isEmpty()) return false
        val stream = streams[askId] ?: Stream(room, now)
        if (stream.room != room || seq in stream.parts || stream.chars + text.length > MAX_CHARS) return false
        val before = prefix(stream.parts)
        stream.parts[seq] = text
        stream.chars += text.length
        stream.updated = now
        streams[askId] = stream
        return prefix(stream.parts) != before
    }

    /** In-order text for an ask (parts 0, 1, 2... up to the first gap), null when nothing shows yet. */
    fun text(askId: String): String? = streams[askId]?.let { prefix(it.parts) }?.takeIf { it.isNotEmpty() }

    /** Asks in [room] with text to show, oldest first. */
    fun open(room: String): List<String> =
        streams.entries.filter { it.value.room == room && text(it.key) != null }.sortedBy { it.value.updated }.map { it.key }

    /** The final answer arrived: drop the partial text and ignore late parts. */
    fun finish(askId: String, now: Long) {
        streams.remove(askId)
        finished[askId] = now
    }

    /** Drops streams with no part for TIMEOUT_MS. Returns the asks dropped. */
    fun expire(now: Long): List<String> {
        val old = streams.filterValues { now - it.updated >= TIMEOUT_MS }.keys.toList()
        old.forEach { streams.remove(it) }
        finished.entries.removeIf { now - it.value >= TIMEOUT_MS * 5 }
        return old
    }

    fun clear() = streams.clear()

    /** Parts are exact deltas (spaces included), so they join as is. */
    private fun prefix(parts: Map<Int, String>): String = buildString {
        var i = 0
        while (true) { append(parts[i] ?: break); i++ }
    }
}
