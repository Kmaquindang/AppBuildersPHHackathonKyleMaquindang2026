// BleHandshakeTest.kt: signed hello, proof, key-keyed link book, tie-break and blocking on Android.
package app.libre.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BleHandshakeTest {
    private fun id(seed: Int) = DeviceIdentity(ByteArray(32) { (it * 7 + seed).toByte() }, ByteArray(32) { seed.toByte() })
    private val a = id(11); private val b = id(22); private val c = id(33)
    private val nA = ByteArray(16) { 0xA1.toByte() }; private val nB = ByteArray(16) { 0xB2.toByte() }

    @Test fun helloRoundTripAndTamper() {
        val raw = BleHello.make(a, "Pixel-A1", nA)!!
        val h = BleHello.open(raw)!!
        assertEquals("Pixel-A1", h.name); assertArrayEquals(a.signKey, h.signKey); assertFalse(h.isHub)
        assertEquals(51 + 8 + 64, raw.size)
        val t = raw.copyOf(); t[52] = (t[52].toInt() xor 1).toByte()
        assertNull(BleHello.open(t))
        val swap = raw.copyOf(); b.signKey.copyInto(swap, 1)
        assertNull("another key cannot take over a hello", BleHello.open(swap))
        assertNull(BleHello.open(Bytes.utf8("iPhone 14")))
        assertNull(BleHello.make(a, "", nA)); assertNull(BleHello.make(a, "x".repeat(65), nA))
    }

    @Test fun proofIsBoundToChallengeAndKeys() {
        val hA = BleHello.open(BleHello.make(a, "A", nA)!!)!!
        val hB = BleHello.open(BleHello.make(b, "B", nB)!!)!!
        val p = BleHello.proof(b, hA)
        assertTrue(BleHello.checkProof(p, hB, nA, a.signKey))
        assertFalse(BleHello.checkProof(p, hB, ByteArray(16), a.signKey))
        assertFalse(BleHello.checkProof(p, hB, nA, c.signKey))
    }

    private fun handshake(me: DeviceIdentity, peer: DeviceIdentity, book: PeerBook, link: String, role: PeerBook.Role, peerName: String): PeerBook.ProofResult {
        val ch = book.opened(link, role)
        val other = PeerBook(peer)
        val och = other.opened("o", if (role == PeerBook.Role.CENTRAL) PeerBook.Role.PERIPHERAL else PeerBook.Role.CENTRAL)
        assertTrue(book.receivedHello(BleHello.make(peer, peerName, och)!!, link) is PeerBook.HelloResult.SendProof)
        val p = (other.receivedHello(BleHello.make(me, "me", ch)!!, "o") as PeerBook.HelloResult.SendProof).proof
        return book.receivedProof(p, link)
    }

    @Test fun bookVerifiesByKeyAndRefusesNameSpoof() {
        val book = PeerBook(a)
        val r = handshake(a, b, book, "c-1", PeerBook.Role.CENTRAL, "iPhone 14") as PeerBook.ProofResult.Verified
        assertEquals("iPhone 14", r.name); assertTrue(r.newPeer)
        assertEquals(setOf("iPhone 14"), book.linkedNames())
        book.opened("c-2", PeerBook.Role.CENTRAL)
        val spoof = book.receivedHello(BleHello.make(c, "iPhone 14", nB)!!, "c-2")
        assertTrue("second key claiming a linked name refused", spoof is PeerBook.HelloResult.Rejected)
        book.opened("c-3", PeerBook.Role.CENTRAL)
        assertTrue(book.receivedProof(ByteArray(64), "c-3") is PeerBook.ProofResult.Rejected)
        assertFalse("unverified link carries no data", book.isVerified("c-3"))
    }

    @Test fun trustOnFirstUseRefusesChangedKeyUntilReset() {
        val book = PeerBook(a)
        assertTrue(handshake(a, b, book, "p-1", PeerBook.Role.PERIPHERAL, "iPhone 14") is PeerBook.ProofResult.Verified)
        assertEquals(TrustStore.Check.Trusted, book.trust.check("iPhone 14", Bytes.hex(b.signKey)))
        book.closed("p-1")
        assertTrue("same key accepted again", handshake(a, b, book, "p-2", PeerBook.Role.PERIPHERAL, "iPhone 14") is PeerBook.ProofResult.Verified)
        book.closed("p-2")
        book.opened("p-3", PeerBook.Role.PERIPHERAL)
        assertEquals(PeerBook.HelloResult.Rejected("key changed for iPhone 14"), book.receivedHello(BleHello.make(c, "iPhone 14", nB)!!, "p-3"))
        assertEquals(Bytes.hex(c.signKey), book.trust.conflictNames["iPhone 14"])
        book.closed("p-3")
        // Saved and loaded: a restart keeps refusing; the Swift JSON shape reads too.
        val loaded = TrustStore.fromJson(book.trust.toJson())
        assertEquals(book.trust.trusted, loaded.trusted); assertEquals(book.trust.conflictNames, loaded.conflictNames)
        assertEquals(mapOf("X" to "k1"), TrustStore.fromJson("""{"keys":{"X":"k1"},"conflicts":{}}""").trusted)
        book.trust.reset("iPhone 14")
        assertTrue("new key accepted after reset", handshake(a, c, book, "p-4", PeerBook.Role.PERIPHERAL, "iPhone 14") is PeerBook.ProofResult.Verified)
        assertTrue(book.trust.conflictNames.isEmpty())
        val store = TrustStore()
        assertTrue(store.flag("X", "k2")); assertFalse("same conflict is news once", store.flag("X", "k2"))
    }

    @Test fun tieBreakByKeyAndBlocking() {
        val greater = if (BleHello.keyGreater(a.signKey, b.signKey)) a else b
        val lesser = if (greater === a) b else a
        val g = PeerBook(greater)
        handshake(greater, lesser, g, "c-x", PeerBook.Role.CENTRAL, "peer")
        val r = handshake(greater, lesser, g, "p-x", PeerBook.Role.PERIPHERAL, "peer") as PeerBook.ProofResult.Verified
        assertEquals("c-x", r.dropLink)
        val l = PeerBook(lesser)
        handshake(lesser, greater, l, "c-x", PeerBook.Role.CENTRAL, "peer")
        assertNull((handshake(lesser, greater, l, "p-x", PeerBook.Role.PERIPHERAL, "peer") as PeerBook.ProofResult.Verified).dropLink)
        // Blocking follows the key.
        assertEquals(listOf("p-x"), g.setBlocked(setOf("peer")))
        assertTrue(g.isBlocked(Bytes.hex(lesser.signKey), "renamed"))
        g.opened("c-9", PeerBook.Role.CENTRAL)
        assertEquals(PeerBook.HelloResult.Rejected("blocked"), g.receivedHello(BleHello.make(lesser, "renamed", nB)!!, "c-9"))
        val closed = l.closed("c-x"); assertNotNull(closed); assertTrue(closed!!.stillLinked)
        assertFalse(l.closed("p-x")!!.stillLinked)
    }
}
