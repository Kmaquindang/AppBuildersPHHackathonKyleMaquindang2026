// AnswerStreamTest.kt: same cases as the AnswerStreams checks in Tests/CoreTests/AnswerStreamTests.swift.
package app.libre.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnswerStreamTest {
    private val t0 = 1_000_000L

    @Test fun inOrderPrefixOnly() {
        val s = AnswerStreams()
        assertFalse("part 1 alone shows nothing", s.add("A", 1, " world", "r1", t0))
        assertNull(s.text("A"))
        assertTrue(s.add("A", 0, "Hello", "r1", t0))
        assertEquals("Hello world", s.text("A"))
        assertFalse("duplicate part ignored", s.add("A", 0, "Again", "r1", t0))
        assertFalse("part after a gap waits", s.add("A", 3, "!", "r1", t0))
        assertEquals("Hello world", s.text("A"))
        assertFalse("other room refused", s.add("A", 2, " x", "r2", t0))
        assertFalse("over the part cap", s.add("A", AnswerStreams.MAX_PARTS, "x", "r1", t0))
        s.add("B", 0, "Other answer", "r2", t0 + 1)
        assertEquals(listOf("A"), s.open("r1"))
        assertEquals(listOf("B"), s.open("r2"))
    }

    @Test fun finalAnswerReplacesAndLatePartsIgnored() {
        val s = AnswerStreams()
        s.add("A", 0, "Hello", "r1", t0)
        s.finish("A", t0 + 2)
        assertNull(s.text("A"))
        assertFalse(s.add("A", 1, " late", "r1", t0 + 3))
    }

    @Test fun noFinalAnswerExpires() {
        val s = AnswerStreams()
        s.add("B", 0, "Other answer", "r2", t0)
        assertTrue(s.expire(t0 + 60_000).isEmpty())
        assertEquals(listOf("B"), s.expire(t0 + AnswerStreams.TIMEOUT_MS))
        assertNull(s.text("B"))
        assertFalse("oversized part refused", AnswerStreams().add("C", 0, "a".repeat(AnswerStreams.MAX_CHARS + 1), "r1", t0))
    }

    @Test fun wireKindAndPart() {
        val m = MeshMessage(origin = "Mac-1", kind = Kind.ANSWER_PART, body = " at 8 PM", replyTo = "A1", part = 1, createdAt = t0)
        val json = String(MeshCodec.encode(m))
        assertTrue(json.contains("\"kind\":\"answerPart\"") && json.contains("\"part\":1"))
        assertEquals(1, MeshCodec.decode(json.toByteArray())?.part)
        assertEquals(Lane.URGENT, Lane.of(Kind.ANSWER_PART, 600))
        assertNull("unknown inner kinds still refused (what older builds do with answerPart)",
            MeshCodec.decode(json.replace("answerPart", "answerPiece2099").toByteArray()))
    }
}
