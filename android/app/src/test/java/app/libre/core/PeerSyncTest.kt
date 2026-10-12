// PeerSyncTest.kt: same cases as Tests/CoreTests/PeerSyncTests.swift (issue #6).
package app.libre.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PeerSyncTest {
    private val now = 1_800_000_000_000L
    private fun chat(body: String, minutesAgo: Long, origin: String = "PHONE_A") =
        MeshMessage(origin = origin, kind = Kind.CHAT, body = body, createdAt = now - minutesAgo * 60_000)
    private fun req(have: List<MeshMessage>) = PeerSync.parseRequest(MeshCodec.parseObject(Bytes.utf8(PeerSync.requestBody(have, now)))!!)!!

    @Test fun onlyRecentTeamChatTheAskerLacks() {
        val known = chat("known", 10)
        val answer = MeshMessage(origin = "Mac-1", destination = Destination.Peer("PHONE_A"), kind = Kind.ANSWER, body = "a", createdAt = now)
        val server = listOf(known, chat("old news", 7 * 60), chat("fresh", 1), answer,
            MeshMessage(origin = "Mac-1", kind = Kind.RULE, body = "{}", createdAt = now), chat("from the future", -60))
        assertEquals(listOf("fresh"), PeerSync.select(server, req(listOf(known)), now).map { it.body })
    }

    @Test fun plainBackfillRequestIsNotAPeerRequest() {
        assertNull(PeerSync.parseRequest(MeshCodec.parseObject(Bytes.utf8(SyncPayload.request(now, emptyList())))!!))
    }

    @Test fun cappedByCountAndBytesNewestKept() {
        val many = (0 until 150).map { chat("message $it " + "x".repeat(300), (150 - it).toLong()) }
        val picked = PeerSync.select(many, req(emptyList()), now)
        assertTrue(picked.size <= PeerSync.MAX_MESSAGES)
        assertTrue(picked.sumOf { MeshCodec.encode(it).size } <= PeerSync.MAX_BYTES)
        assertTrue(picked.last().body.startsWith("message 149"))
        assertEquals("one short id per message, no duplicates", 150, req(many + many).knownShort.size)
    }

    @Test fun shortIdAndBatches() {
        assertEquals("6f1c2a3b4d5e", PeerSync.shortId("6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8"))
        val bodies = PeerSync.batchBodies((0 until 60).map { chat("m$it " + "y".repeat(400), it.toLong()) })
        assertTrue("split into about 12 KB batches", bodies.size > 1)
        val back = bodies.flatMap { SyncPayload.decode(it)!!.batch!! }
        assertEquals(60, back.size)
    }
}
