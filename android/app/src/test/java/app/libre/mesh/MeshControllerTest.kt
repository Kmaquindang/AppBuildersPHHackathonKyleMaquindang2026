package app.libre.mesh

import app.libre.core.Vectors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class FakeLink(var peers: MutableSet<String> = mutableSetOf()) : Link {
    val sent = mutableListOf<Pair<ByteArray, Set<String>>>()
    override val linkedPeers: Set<String> get() = peers
    override fun send(data: ByteArray, to: Set<String>): Set<String> { sent += data to to; return to }
}

class MeshControllerTest {
    private fun controller(): Pair<MeshController, FakeLink> {
        val c = MeshController(Files.createTempDirectory("libre").toFile(), now = { Vectors.T0 + 5_000 })
        c.completeOnboarding("PATIENT_A", "Pixel 8")
        val l = FakeLink(); c.link = l
        return c to l
    }

    @Test fun swiftSealedTownSquareShowsUpAndRelays() {
        val (c, l) = controller()
        l.peers += setOf("Mac-1", "iPhone-2")
        c.peerLinked("Mac-1"); c.peerLinked("iPhone-2")
        l.sent.clear()
        c.receive(Vectors.s("townSealedJSON").toByteArray(), "Mac-1")
        val e = c.entries.value.single()
        assertEquals("Bluetooth", e.link)
        assertTrue(e.body.isNotEmpty())
        assertTrue("forwarded to the other peer only", l.sent.any { it.second == setOf("iPhone-2") })
        val before = l.sent.size
        c.receive(Vectors.s("townSealedJSON").toByteArray(), "iPhone-2")
        assertEquals("duplicate dropped", before, l.sent.size)
        assertEquals(1, c.entries.value.size)
    }

    @Test fun messagesWaitForAPeerThenGo() {
        val (c, l) = controller()
        assertTrue(c.meshName().startsWith("Pixel-8-") || c.meshName().startsWith("Pixel"))
        c.send("hello from PATIENT_A")
        assertTrue(l.sent.isEmpty())
        l.peers += "Mac-1"; c.peerLinked("Mac-1")
        assertTrue(l.sent.any { "Mac-1" in it.second })
    }

    @Test fun askGoesToTheAiRole() {
        val (c, l) = controller()
        l.peers += "Mac-1"; c.peerLinked("Mac-1"); l.sent.clear()
        c.send("@libre what is the visit rule?")
        val json = String(l.sent.last().first)
        assertTrue(json.contains("\"sealed\""))
        assertTrue(c.waiting.value.isNotEmpty())
    }
}
