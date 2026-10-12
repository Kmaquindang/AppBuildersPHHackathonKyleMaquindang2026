package app.libre.mesh

import app.libre.core.Vectors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class FakeLink(var peers: MutableSet<String> = mutableSetOf()) : Link {
    val sent = mutableListOf<Pair<ByteArray, Set<String>>>()
    override val linkedPeers: Set<String> get() = peers
    val lanes = mutableListOf<app.libre.core.Lane>()
    override fun send(data: ByteArray, to: Set<String>, lane: app.libre.core.Lane): Set<String> { sent += data to to; lanes += lane; return to }
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

    @Test fun threePhonesCarryChatWithoutTheMac() {
        val clock = Vectors.T0 + 5_000
        fun phone(name: String) = MeshController(Files.createTempDirectory("libre").toFile(), now = { clock }).also {
            it.completeOnboarding(name, "Pixel 8"); it.link = FakeLink()
        }
        val a = phone("PATIENT_A"); val b = phone("PATIENT_B"); val c = phone("PATIENT_C")
        val all = listOf(a, b, c).associateBy { it.meshName() }
        fun link(x: MeshController, y: MeshController) {
            (x.link as FakeLink).peers += y.meshName(); (y.link as FakeLink).peers += x.meshName()
            x.peerLinked(y.meshName()); y.peerLinked(x.meshName())
        }
        fun unlink(x: MeshController, y: MeshController) {
            (x.link as FakeLink).peers -= y.meshName(); (y.link as FakeLink).peers -= x.meshName()
            x.peerUnlinked(y.meshName()); y.peerUnlinked(x.meshName())
        }
        fun pump() {
            repeat(10) {
                for ((name, ctl) in all) {
                    val l = ctl.link as FakeLink
                    val out = l.sent.toList(); l.sent.clear()
                    for ((data, to) in out) for (t in to) all[t]?.receive(data, name)
                }
            }
        }
        a.send("Gate 2 is closed, use gate 3")   // nobody linked yet: waits in A's outbox
        link(a, b); pump()
        assertTrue("B got A's chat", b.entries.value.any { it.body == "Gate 2 is closed, use gate 3" })
        unlink(a, b)
        c.send("Ana is at the clinic")
        link(b, c); pump()
        assertTrue("C got A's chat from B, no Mac anywhere", c.entries.value.any { it.body == "Gate 2 is closed, use gate 3" })
        assertTrue("B got C's chat", b.entries.value.any { it.body == "Ana is at the clinic" })
        assertEquals("no duplicates on C", 1, c.entries.value.count { it.body == "Gate 2 is closed, use gate 3" })
    }

    @Test fun townSquareHideFromTrustedMacOnly() {
        val (c, l) = controller()
        l.peers += "Mac-1"; c.peerLinked("Mac-1")
        val mac = app.libre.core.DeviceIdentity(ByteArray(32) { (it * 5 + 41).toByte() }, ByteArray(32) { 41 })
        val town = c.activeRoom
        fun deliver(m: app.libre.core.MeshMessage) =
            c.receive(app.libre.core.MeshCodec.encode(app.libre.core.RoomEnvelope.seal(m, town.id, town.contentKey!!, town.epoch)), "Mac-1")
        val bad = app.libre.core.MeshMessage(origin = "iPhone-2", kind = app.libre.core.Kind.CHAT, body = "spam placeholder", createdAt = Vectors.T0)
        deliver(bad)
        val hide = app.libre.core.MeshMessage(origin = "Mac-1", kind = app.libre.core.Kind.MODERATION, createdAt = Vectors.T0,
            body = app.libre.core.ModerationState.make(bad.id, town.id, Vectors.T0, mac).toJson().toString())
        deliver(hide)
        assertEquals("not trusted yet: still shown", 1, c.entries.value.count { it.id == bad.id })
        // The phone hears the AI Mac's signed status and the person trusts it.
        val status = mac.sign(app.libre.core.Bytes.utf8("""{"device":"Mac-1"}"""), "ai-status")
        c.receive(app.libre.core.MeshCodec.encode(app.libre.core.MeshMessage(origin = "Mac-1", kind = app.libre.core.Kind.AI_STATUS,
            body = status.toJson().toString(), createdAt = Vectors.T0)), "Mac-1")
        c.setTrustAiMac(true)
        deliver(hide.copy(id = java.util.UUID.randomUUID().toString().uppercase()))
        assertEquals("trusted Mac's hide removes it", 0, c.entries.value.count { it.id == bad.id })
        // Backfill or phone-to-phone sync bringing it back (no relay dedupe on batch contents).
        val batch = app.libre.core.PeerSync.batchBodies(listOf(bad)).single()
        deliver(app.libre.core.MeshMessage(origin = "iPhone-2", destination = app.libre.core.Destination.Peer(c.meshName()),
            kind = app.libre.core.Kind.SYNC, body = batch, createdAt = Vectors.T0))
        assertEquals("never shown again, even from a sync batch", 0, c.entries.value.count { it.id == bad.id })
    }

    @Test fun askGoesToTheAiRole() {
        val (c, l) = controller()
        l.peers += "Mac-1"; c.peerLinked("Mac-1"); l.sent.clear()
        c.send("@libre what is the visit rule?")
        val json = String(l.sent.last().first)
        assertTrue(json.contains("\"sealed\""))
        assertTrue(c.waiting.value.isNotEmpty())
        assertEquals("@libre ask rides the urgent Bluetooth lane", app.libre.core.Lane.URGENT, l.lanes.last())
    }

    @Test fun streamedAnswerShowsPartsThenFinalOnce() {
        val (c, l) = controller()
        l.peers += "Mac-1"; c.peerLinked("Mac-1")
        c.send("@libre what is the visit rule?")
        val ask = c.waiting.value.single()
        val room = c.activeRoom
        fun deliver(m: app.libre.core.MeshMessage) =
            c.receive(app.libre.core.MeshCodec.encode(app.libre.core.RoomEnvelope.seal(m, room.id, room.contentKey!!, room.epoch)), "Mac-1")
        fun part(seq: Int, text: String) = app.libre.core.MeshMessage(origin = "Mac-1", destination = app.libre.core.Destination.Peer(c.meshName()),
            kind = app.libre.core.Kind.ANSWER_PART, body = text, replyTo = ask, part = seq, createdAt = Vectors.T0)

        deliver(part(1, " end at 8 PM"))
        assertTrue("part 1 alone shows nothing", c.partials.value.isEmpty())
        deliver(part(0, "Visits"))
        assertEquals(listOf(PartialAnswer(ask, "Visits end at 8 PM")), c.partials.value)
        assertEquals("parts never enter the timeline", 1, c.entries.value.size)

        deliver(app.libre.core.MeshMessage(origin = "Mac-1", destination = app.libre.core.Destination.Peer(c.meshName()),
            kind = app.libre.core.Kind.ANSWER, body = "Visits end at 8 PM.", replyTo = ask, createdAt = Vectors.T0))
        assertTrue("final answer replaces the partial", c.partials.value.isEmpty())
        deliver(part(2, " late"))
        assertTrue("late part ignored", c.partials.value.isEmpty())
        assertEquals("answer shown once", 1, c.entries.value.count { it.isAnswer })
        assertTrue(c.waiting.value.isEmpty())
    }

    @Test fun answerLogsRoundTripLinkAndHops() {
        var clock = Vectors.T0 + 5_000
        val c = MeshController(Files.createTempDirectory("libre").toFile(), now = { clock })
        c.completeOnboarding("PATIENT_A", "Pixel 8")
        val l = FakeLink(mutableSetOf("iPhone-2")); c.link = l; c.peerLinked("iPhone-2")
        val lines = mutableListOf<String>()
        c.timingLog = { lines += it }
        c.send("@libre what is the visit rule?")
        val askId = c.waiting.value.single()
        clock += 3_100
        // The Mac's answer arrives through iPhone-2 (two hops), sealed for the same room.
        val room = c.activeRoom
        val answer = app.libre.core.MeshMessage(origin = "Mac-1", kind = app.libre.core.Kind.ANSWER, body = "Visits end at 8 PM.",
            hops = listOf("Mac-1", "iPhone-2"), replyTo = askId, latencyMs = 2500, createdAt = clock)
        val sealed = app.libre.core.RoomEnvelope.seal(answer, room.id, room.contentKey!!, room.epoch)
        c.receive(app.libre.core.MeshCodec.encode(sealed), "iPhone-2")
        assertEquals(listOf("MSG answer link=bluetooth hops=2 rtt_ms=3100 ai_ms=2500"), lines)
        assertTrue(c.waiting.value.isEmpty())
        // A chat logs link and hops only, never its text.
        lines.clear()
        val chat = app.libre.core.MeshMessage(origin = "Mac-1", kind = app.libre.core.Kind.CHAT, body = "secret words", createdAt = clock)
        c.receive(app.libre.core.MeshCodec.encode(app.libre.core.RoomEnvelope.seal(chat, room.id, room.contentKey!!, room.epoch)), "Mac-1")
        assertEquals(listOf("MSG chat link=bluetooth hops=1"), lines)
    }
}
