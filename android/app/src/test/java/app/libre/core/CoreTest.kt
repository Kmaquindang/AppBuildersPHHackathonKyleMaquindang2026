// Unit tests for the Android core: framing edge cases, relay rules, room state, mentions.
package app.libre.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreTest {
    private fun bytes(n: Int, seed: Int = 7) = ByteArray(n) { (it * 31 + seed).toByte() }

    @Test fun malformedFramesRefused() {
        val good = BleFrame(FrameType.DATA, 1, 0, 2, byteArrayOf(9)).encoded()
        assertNull(BleFrame.decode(good.copyOf().also { it[0] = 0 }))
        assertNull(BleFrame.decode(good.copyOf().also { it[1] = 1 }))
        assertNull(BleFrame.decode(good.copyOf().also { it[2] = 77 }))
        assertNull(BleFrame.decode(good.copyOf().also { it[9] = 0; it[10] = 0 }))
        assertNull(BleFrame.decode(good.copyOf().also { it[8] = 2 }))
        assertNull(BleFrame.decode(good.copyOf(10)))
        assertNotNull(BleFrame.decode(good))
    }

    @Test fun mtuEdges() {
        assertEquals(9, BleChunker.payloadSize(20))
        assertEquals(9, BleChunker.payloadSize(5))
        assertEquals(171, BleChunker.payloadSize(182))
        assertEquals(1, BleChunker.frames(bytes(171), 1, 182)!!.size)
        assertEquals(2, BleChunker.frames(bytes(172), 1, 182)!!.size)
        assertEquals(1, BleChunker.frames(ByteArray(0), 1, 182)!!.size)
        assertTrue(BleChunker.frames(bytes(1000), 1, 20)!!.all { it.size <= 20 })
        assertNull(BleChunker.frames(ByteArray(BleChunker.MAX_MESSAGE_BYTES + 1), 1, 512))
        // Android MTU 517 gives writes of 514 bytes.
        assertTrue(BleChunker.frames(bytes(17_000), 9, 514)!!.all { it.size <= 514 })
    }

    @Test fun reassemblyDuplicatesInterleaveTimeout() {
        val data = bytes(2000)
        val frames = BleChunker.frames(data, 5, 100)!!
        val r = BleReassembler()
        var out: ByteArray? = null
        var deliveries = 0
        for (f in frames.flatMap { listOf(it, it) } + frames.first()) r.add(f, "L")?.let { out = it.data; deliveries++ }
        assertArrayEquals(data, out)
        assertEquals(1, deliveries)

        val a = BleChunker.frames(bytes(300, 1), 7, 64)!!
        val b = BleChunker.frames(bytes(300, 2), 7, 64)!!
        val r2 = BleReassembler()
        val got = HashMap<String, ByteArray>()
        for (i in a.indices) { r2.add(a[i], "A")?.let { got["A"] = it.data }; r2.add(b[i], "B")?.let { got["B"] = it.data } }
        assertArrayEquals(bytes(300, 1), got["A"]); assertArrayEquals(bytes(300, 2), got["B"])

        val r3 = BleReassembler(timeoutMs = 1000)
        val f3 = BleChunker.frames(bytes(500), 3, 64)!!
        r3.add(f3[0], "L", now = 0)
        var late: ByteArray? = null
        for (f in f3.drop(1)) r3.add(f, "L", now = 5000)?.let { late = it.data }
        assertNull("never a corrupt message after a timeout", late)
    }

    @Test fun relayDedupeTtlPath() {
        val e = RelayEngine("Pixel-A1")
        val m = MeshMessage(origin = "iPhone 12", kind = Kind.CHAT, body = "x", v = 2)
        val p = Packet.parse(MeshCodec.encode(m))!!
        val d1 = e.handleIncoming(p, "iPhone 12")
        assertFalse(d1.isDuplicate)
        assertNotNull(d1.deliver)
        assertEquals(listOf("iPhone 12", "Pixel-A1"), d1.deliverHops)
        val fwd = Packet.parse(d1.forward!!)!!
        assertEquals(6, fwd.ttl)
        assertEquals(listOf("iPhone 12", "Pixel-A1"), fwd.hops)
        assertEquals(setOf("iPhone 12", "Pixel-A1"), d1.forwardExcluding)
        assertTrue("same packet over the other link is a duplicate", e.handleIncoming(p, "iPhone 12").isDuplicate)

        // Unicast to someone else: not delivered, forwarded; ttl 1 stops.
        val uni = Packet.parse(MeshCodec.encode(MeshMessage(origin = "A", destination = Destination.Peer("B"), kind = Kind.CHAT, body = "", ttl = 1)))!!
        val d2 = e.handleIncoming(uni, "A")
        assertNull(d2.deliver); assertNull(d2.forward)
        // Role ask: Android holds no role, so it relays without reading.
        val ask = Packet.parse(MeshCodec.encode(MeshMessage(origin = "A", destination = Destination.Role("ai"), kind = Kind.ASK, body = "")))!!
        val d3 = e.handleIncoming(ask, "A")
        assertNull(d3.deliver); assertNotNull(d3.forward)
        // Own message echo dropped; unknown fields survive the relay.
        val mine = e.makeOutgoing(Kind.CHAT, "hi")
        assertTrue(e.handleIncoming(Packet.parse(MeshCodec.encode(mine))!!, "A").isDuplicate)
        val future = Bytes.utf8("""{"id":"AAAAAAAA-0000-4000-8000-000000000001","origin":"X","kind":"hologram","body":"","ttl":7,"hops":["X"],"createdAt":0,"v":3,"newField":{"a":1}}""")
        val fp = Packet.parse(future)!!
        assertNull(fp.message)
        val fd = e.handleIncoming(fp, "X")
        assertTrue(String(fd.forward!!).contains("\"newField\""))
    }

    @Test fun roomStateKeysAndBlockers() {
        val town = RoomState.townSquare()
        assertTrue(town.isDefault)
        assertEquals("Town Square", town.displayName)
        assertNotNull(town.contentKey)
        val code = RoomState.fromCode("bohol 7", "k7qm-3xrf", rounds = 1)!!
        assertEquals("BOHOL-7", code.label)
        assertNull(code.contentKey)
        assertTrue(code.sendBlocker!!.startsWith("Waiting"))
        assertNull(RoomState.fromCode("Town Square", "K7QM-3XRF", rounds = 1))
        assertNull(RoomState.fromCode("BOHOL-7", "0000-0000", rounds = 1))
        assertNull(RoomState.fromPasscode("BOHOL-7", "short", rounds = 1))
        assertTrue(Governor.wantsAdmission(code, DeviceIdentity.generate()))
        assertFalse(Governor.wantsAdmission(town, DeviceIdentity.generate()))
    }

    @Test fun keyBoxRoundTripAndEnvelopeEpochAad() {
        val me = DeviceIdentity.generate()
        val k = Crypto.randomBytes(32)
        val box = KeyBox.seal(k, me.boxKey, "c5f38f77165833b5", 3)!!
        assertArrayEquals(k, KeyBox.open(box, me.boxSecret, "c5f38f77165833b5", 3))
        assertNull(KeyBox.open(box, me.boxSecret, "c5f38f77165833b5", 4))
        val inner = MeshMessage(origin = "Pixel-A1", kind = Kind.CHAT, body = "hello", v = 2)
        val sealed = RoomEnvelope.seal(inner, "tag", k, 3)
        assertEquals(3, sealed.epoch)
        assertTrue(String(RoomEnvelope.aad(sealed, "tag")).endsWith("|e3"))
        assertEquals("hello", RoomEnvelope.open(sealed, "tag", k)!!.body)
        assertNull(RoomEnvelope.open(sealed.copy(epoch = 2), "tag", k))
    }

    @Test fun mentionsAndJoinLinks() {
        assertEquals("what is the rule", AssistantMention.strip("@libre: what is the rule"))
        assertEquals("hi", AssistantMention.strip("  @PASA, hi"))
        assertNull(AssistantMention.strip("@libreng hi"))
        assertEquals("", AssistantMention.strip("@libre"))
        val link = JoinLink.parse("libre://join?room=Bohol%207&code=k7qm3xrf&v=1&exp=1791600000")!!
        assertEquals(JoinLink("BOHOL-7", "K7QM-3XRF", 1_791_600_000_000L), link)
        assertNotNull(JoinLink.parse("pasa://join?room=X&code=K7QM-3XRF&v=1"))
        assertNull(JoinLink.parse("libre://join?room=Town%20Square&code=K7QM-3XRF&v=1"))
        assertNull(JoinLink.parse("libre://join?room=X&code=K7QM-3XRF&v=2"))
    }
}
