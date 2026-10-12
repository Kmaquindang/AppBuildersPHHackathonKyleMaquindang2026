// PriorityTest.kt: same cases as Tests/CoreTests/BLEPriorityTests.swift.
package app.libre.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PriorityTest {
    @Test fun lanesByKind() {
        assertEquals(Lane.URGENT, Lane.of(Kind.CHAT, 900)); assertEquals(Lane.URGENT, Lane.of(Kind.ANSWER, 3000)); assertEquals(Lane.URGENT, Lane.of(Kind.TASK, 1))
        assertEquals(Lane.BULK, Lane.of(Kind.SYNC, 50_000)); assertEquals(Lane.MEDIA, Lane.of(Kind.CHUNK, 17_000))
        assertEquals(Lane.URGENT, Lane.of(Kind.SEALED, 2000)); assertEquals(Lane.MEDIA, Lane.of(null, 17_000))
        assertFalse(Lane.MEDIA.allowedOnBluetoothOnly(false)); assertTrue(Lane.MEDIA.allowedOnBluetoothOnly(true)); assertTrue(Lane.URGENT.allowedOnBluetoothOnly(false))
    }

    @Test fun textJumpsAheadOfPhoto() {
        val q = SendQueue()
        assertTrue(q.push((0 until 50).map { byteArrayOf(0xEE.toByte(), it.toByte()) }, Lane.MEDIA))
        q.pop(); q.pop()
        q.push(listOf(byteArrayOf(1), byteArrayOf(2)), Lane.URGENT)
        q.push(listOf(byteArrayOf(0x0C)), Lane.CONTROL)
        assertArrayEquals(byteArrayOf(0x0C), q.pop()); assertArrayEquals(byteArrayOf(1), q.pop()); assertArrayEquals(byteArrayOf(2), q.pop())
        assertArrayEquals(byteArrayOf(0xEE.toByte(), 2), q.pop())
        q.push(listOf(byteArrayOf(0x0B)), Lane.BULK); assertArrayEquals(byteArrayOf(0x0B), q.peek())
    }

    @Test fun caps() {
        val q = SendQueue()
        assertTrue(q.push(List(3000) { byteArrayOf(1) }, Lane.MEDIA)); assertFalse(q.push(listOf(byteArrayOf(1)), Lane.MEDIA))
        assertTrue(q.push(List(3000) { byteArrayOf(2) }, Lane.URGENT)); assertFalse(q.push(listOf(byteArrayOf(3)), Lane.URGENT))
        assertTrue(q.push(listOf(byteArrayOf(4)), Lane.CONTROL)); assertEquals(6001, q.size)
    }
}
