// Framing.kt: Bluetooth LE frames, byte for byte as Libre/Sources/Core/BLEFraming.swift.
//   byte 0 magic 0x4C, byte 1 version 1, byte 2 type (0 data, 1 hello, 2 probe, 3 probe reply),
//   bytes 3-6 message id (UInt32 BE), 7-8 index (UInt16 BE), 9-10 count (UInt16 BE), then payload.
package app.libre.core

enum class FrameType(val raw: Int) { DATA(0), HELLO(1), PROBE(2), PROBE_REPLY(3);
    companion object { fun of(b: Int) = entries.firstOrNull { it.raw == b } }
}

data class BleFrame(val type: FrameType, val messageId: Long, val index: Int, val count: Int, val payload: ByteArray) {
    fun encoded(): ByteArray {
        val h = ByteArray(HEADER)
        h[0] = MAGIC.toByte(); h[1] = VERSION.toByte(); h[2] = type.raw.toByte()
        for (i in 0 until 4) h[3 + i] = (messageId ushr (24 - 8 * i)).toByte()
        h[7] = (index ushr 8).toByte(); h[8] = index.toByte()
        h[9] = (count ushr 8).toByte(); h[10] = count.toByte()
        return h + payload
    }

    companion object {
        const val MAGIC = 0x4C
        const val VERSION = 1
        const val HEADER = 11
        const val MIN_MTU = 20

        fun decode(raw: ByteArray): BleFrame? {
            if (raw.size < HEADER) return null
            fun u(i: Int) = raw[i].toInt() and 0xff
            if (u(0) != MAGIC || u(1) != VERSION) return null
            val type = FrameType.of(u(2)) ?: return null
            val id = (u(3).toLong() shl 24) or (u(4).toLong() shl 16) or (u(5).toLong() shl 8) or u(6).toLong()
            val index = (u(7) shl 8) or u(8)
            val count = (u(9) shl 8) or u(10)
            if (count == 0 || index >= count) return null
            return BleFrame(type, id, index, count, raw.copyOfRange(HEADER, raw.size))
        }
    }
}

object BleChunker {
    const val MAX_MESSAGE_BYTES = 256 * 1024

    fun payloadSize(mtu: Int) = maxOf(BleFrame.MIN_MTU, mtu) - BleFrame.HEADER

    /** Frames that each fit in [mtu] bytes; null when the message is too big for BLE. */
    fun frames(data: ByteArray, messageId: Long, mtu: Int, type: FrameType = FrameType.DATA): List<ByteArray>? {
        if (data.size > MAX_MESSAGE_BYTES) return null
        val size = payloadSize(mtu)
        val count = maxOf(1, (data.size + size - 1) / size)
        if (count > 0xFFFF) return null
        return (0 until count).map { i ->
            val start = i * size
            val end = minOf(data.size, start + size)
            BleFrame(type, messageId and 0xFFFFFFFFL, i, count, if (start < end) data.copyOfRange(start, end) else ByteArray(0)).encoded()
        }
    }
}

/** Puts frames back together per link and message id (BLEReassembler). */
class BleReassembler(private val timeoutMs: Long = 60_000) {
    data class Complete(val type: FrameType, val messageId: Long, val data: ByteArray)

    private class Partial(val type: FrameType, val count: Int, val parts: HashMap<Int, ByteArray> = HashMap(), var bytes: Int = 0, var updated: Long)

    private val partials = HashMap<String, HashMap<Long, Partial>>()
    private val finished = HashMap<String, HashMap<Long, Long>>()
    var dropped = 0
        private set

    @Synchronized
    fun add(raw: ByteArray, link: String, now: Long = System.currentTimeMillis()): Complete? {
        expire(now)
        val f = BleFrame.decode(raw) ?: run { dropped++; return null }
        if (finished[link]?.containsKey(f.messageId) == true) return null
        if (f.count == 1) {
            markFinished(link, f.messageId, now)
            return Complete(f.type, f.messageId, f.payload)
        }
        val forLink = partials.getOrPut(link) { HashMap() }
        var p = forLink[f.messageId] ?: Partial(f.type, f.count, updated = now)
        if (p.count != f.count || p.type != f.type) { dropped++; p = Partial(f.type, f.count, updated = now) }
        if (!p.parts.containsKey(f.index)) { p.parts[f.index] = f.payload; p.bytes += f.payload.size }
        p.updated = now
        if (p.parts.size == p.count) {
            val out = java.io.ByteArrayOutputStream()
            for (i in 0 until p.count) out.write(p.parts[i] ?: ByteArray(0))
            forLink.remove(f.messageId)
            markFinished(link, f.messageId, now)
            return Complete(p.type, f.messageId, out.toByteArray())
        }
        forLink[f.messageId] = p
        while (forLink.values.sumOf { it.bytes } > 2 * BleChunker.MAX_MESSAGE_BYTES) {
            val oldest = forLink.minByOrNull { it.value.updated }?.key ?: break
            forLink.remove(oldest); dropped++
        }
        return null
    }

    @Synchronized
    fun reset(link: String) { partials.remove(link); finished.remove(link) }

    @Synchronized
    fun pending(link: String) = partials[link]?.size ?: 0

    private fun markFinished(link: String, id: Long, now: Long) {
        val f = finished.getOrPut(link) { HashMap() }
        f[id] = now
        if (f.size > 512) f.entries.removeIf { now - it.value >= timeoutMs }
    }

    private fun expire(now: Long) {
        for (forLink in partials.values) {
            val before = forLink.size
            forLink.entries.removeIf { now - it.value.updated >= timeoutMs }
            dropped += before - forLink.size
        }
        for (f in finished.values) f.entries.removeIf { now - it.value >= timeoutMs }
    }
}

object LinkRules {
    /** The device whose name sorts last drops the link it opened as the scanner (Swift String <). */
    fun dropOwnCentralLink(myName: String, peerName: String, alsoLinkedAsPeripheral: Boolean) =
        alsoLinkedAsPeripheral && swiftGreater(myName, peerName)

    /** Swift compares Strings by Unicode scalar values (for NFC text); compare code points. */
    fun swiftGreater(a: String, b: String): Boolean {
        val x = a.codePoints().toArray(); val y = b.codePoints().toArray()
        for (i in 0 until minOf(x.size, y.size)) if (x[i] != y[i]) return x[i] > y[i]
        return x.size > y.size
    }
}
