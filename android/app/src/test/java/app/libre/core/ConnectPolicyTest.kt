// ConnectPolicyTest.kt: same cases as Tests/CoreTests/BLEConnectPolicyTests.swift.
package app.libre.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectPolicyTest {
    private val t0 = 1_792_000_000_000L

    @Test fun capStrongestFirstOneAtATime() {
        val p = ConnectPolicy(ConnectPolicy.Config(maxLinks = 3, maxPending = 1))
        listOf(-60, -70, -50, -80).forEachIndexed { i, r -> p.discovered("d$i", r, t0) }
        assertEquals(listOf("d2"), p.next(0, t0))
        assertTrue(p.next(0, t0).isEmpty())
        p.connected("d2"); assertEquals(listOf("d0"), p.next(1, t0))
        p.connected("d0"); assertEquals(listOf("d1"), p.next(2, t0))
        p.connected("d1"); assertTrue(p.next(3, t0).isEmpty())
        assertEquals(7, ConnectPolicy.Config.ANDROID.maxLinks); assertEquals(1, ConnectPolicy.Config.ANDROID.maxPending)
        assertEquals(12, ConnectPolicy.Config.HUB.maxLinks)
    }

    @Test fun signalFloor() {
        val f = ConnectPolicy()
        assertFalse(f.discovered("weak", -92, t0)); assertTrue(f.discovered("ok", -85, t0)); assertTrue(f.discovered("u", 127, t0))
        f.verified("weak"); assertTrue(f.discovered("weak", -92, t0)); assertFalse(f.discovered("w2", -99, t0))
    }

    @Test fun timeoutBackoffAnd133() {
        val b = ConnectPolicy(ConnectPolicy.Config(maxPending = 1, connectTimeoutMs = 10_000))
        b.discovered("x", -60, t0); b.next(0, t0)
        assertTrue(b.timedOut(t0 + 5_000).isEmpty())
        assertEquals(listOf("x"), b.timedOut(t0 + 10_000))
        assertFalse(b.discovered("x", -60, t0 + 11_000)); assertTrue(b.discovered("x", -60, t0 + 13_000))
        assertEquals(listOf(2000L, 4000, 8000, 16000, 32000, 60000), (0 until 6).map { b.failed("y", ConnectPolicy.Failure.OTHER, t0) })
        val g = ConnectPolicy()
        assertEquals(listOf(500L, 1000, 2000, 2000, 4000), (0 until 5).map { g.failed("pixel", ConnectPolicy.Failure.GATT_ERROR_133, t0) })
        g.connected("pixel"); assertEquals(500L, g.failed("pixel", ConnectPolicy.Failure.GATT_ERROR_133, t0))
    }

    @Test fun excludedAndForgotten() {
        val e = ConnectPolicy()
        e.exclude("dup"); assertFalse(e.discovered("dup", -40, t0)); e.include("dup"); assertTrue(e.discovered("dup", -40, t0))
        val s = ConnectPolicy(); s.discovered("old", -60, t0); assertTrue(s.next(0, t0 + 31_000).isEmpty())
    }

    @Test fun sameKeyNewMacReplacesOldLink() {
        val me = DeviceIdentity(ByteArray(32) { (it * 5 + 40).toByte() }, ByteArray(32) { 40 })
        val phone = DeviceIdentity(ByteArray(32) { (it * 5 + 50).toByte() }, ByteArray(32) { 50 })
        val book = PeerBook(me)
        fun link(id: String): PeerBook.ProofResult {
            val ch = book.opened(id, PeerBook.Role.CENTRAL)
            val other = PeerBook(phone); val och = other.opened("o", PeerBook.Role.PERIPHERAL)
            book.receivedHello(BleHello.make(phone, "iPhone 12", och)!!, id)
            val pr = (other.receivedHello(BleHello.make(me, "Pixel-A1", ch)!!, "o") as PeerBook.HelloResult.SendProof).proof
            return book.receivedProof(pr, id)
        }
        assertNull((link("c-AA:01") as PeerBook.ProofResult.Verified).replaced)
        val r = link("c-BB:02") as PeerBook.ProofResult.Verified
        assertEquals("c-AA:01", r.replaced); assertFalse(r.newPeer)
        assertEquals(listOf("c-BB:02"), book.linkIds("iPhone 12"))
    }
}
