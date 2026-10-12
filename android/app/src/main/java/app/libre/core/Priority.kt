// Priority.kt: Bluetooth lanes and per-link send queue, same rules as
// Libre/Sources/Core/BLEPriority.swift (Oct 12, 2026). Our own design.
// control (hello, proof, probe reply) > urgent (chat, asks, answers, tasks, rules, room control,
// beacons, AI status) > bulk (backfill, transcripts) > media (photo and voice pieces, probes,
// unknown packets over 8 KB). Frames leave highest lane first. Media is held for Wi-Fi on
// Bluetooth-only links unless the setting allows it (Android has no Wi-Fi link, so it never
// sends media; it still relays at the media lane).
package app.libre.core

enum class Lane { CONTROL, URGENT, BULK, MEDIA;
    fun allowedOnBluetoothOnly(mediaOverBluetooth: Boolean) = this != MEDIA || mediaOverBluetooth

    companion object {
        const val UNKNOWN_MEDIA_BYTES = 8 * 1024
        fun of(kind: String?, bytes: Int): Lane = when (kind) {
            Kind.CHAT, Kind.ASK, Kind.ANSWER, Kind.ANSWER_PART, Kind.ACK, Kind.TASK, Kind.RULE, Kind.ROOM_CONTROL, Kind.BEACON, Kind.AI_STATUS -> URGENT
            Kind.SYNC, Kind.TRANSCRIPT -> BULK
            Kind.MEDIA, Kind.CHUNK, Kind.MEDIA_NACK -> MEDIA
            else -> if (bytes > UNKNOWN_MEDIA_BYTES) MEDIA else URGENT
        }
    }
}

class SendQueue {
    companion object { const val MAX_FRAMES = 6000; const val MAX_MEDIA_FRAMES = 3000 }
    private val lanes = Array(Lane.entries.size) { ArrayDeque<ByteArray>() }

    val size: Int get() = lanes.sumOf { it.size }
    fun isEmpty() = size == 0
    fun count(lane: Lane) = lanes[lane.ordinal].size

    fun push(frames: List<ByteArray>, lane: Lane): Boolean {
        if (lane != Lane.CONTROL) {
            if (size + frames.size > MAX_FRAMES) return false
            if (lane == Lane.MEDIA && count(Lane.MEDIA) + frames.size > MAX_MEDIA_FRAMES) return false
        }
        lanes[lane.ordinal].addAll(frames)
        return true
    }

    fun peek(): ByteArray? = lanes.firstOrNull { it.isNotEmpty() }?.first()
    fun pop(): ByteArray? = lanes.firstOrNull { it.isNotEmpty() }?.removeFirst()
    fun clear() = lanes.forEach { it.clear() }
}
