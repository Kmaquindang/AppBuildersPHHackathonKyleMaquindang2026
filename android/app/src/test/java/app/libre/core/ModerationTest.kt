// ModerationTest.kt: same cases as Tests/CoreTests/ModerationTests.swift (issue #9).
package app.libre.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModerationTest {
    private fun id(seed: Int) = DeviceIdentity(ByteArray(32) { (it * 5 + seed).toByte() }, ByteArray(32) { seed.toByte() })
    private val mac = id(41); private val stranger = id(42); private val admin = id(43)
    private val town = RoomState.townSquare().id
    private val msg = "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8"

    @Test fun onlyTrustedKeysHide() {
        val hide = ModerationState.make(msg, town, 1_800_000_000_000, mac)
        val phone = ModerationState()
        assertNull("untrusted Mac ignored", phone.apply(hide, town, emptySet()))
        phone.setTrusted(Bytes.hex(mac.signKey), true)
        assertNull("another Mac ignored", phone.apply(ModerationState.make(msg, town, 0, stranger), town, emptySet()))
        assertEquals(msg, phone.apply(hide, town, emptySet())); assertTrue(phone.isHidden(msg))
        assertNull("repeat is not news", phone.apply(hide, town, emptySet()))
        assertEquals(msg, ModerationState().apply(ModerationState.make(msg, town, 0, admin), town, setOf(Bytes.hex(admin.signKey))))
    }

    @Test fun wrongRoomTamperAndDomainRefused() {
        val phone = ModerationState().also { it.setTrusted(Bytes.hex(mac.signKey), true) }
        assertNull(phone.accepts(ModerationState.make(msg, "a229470a9c620b6a00", 0, mac), town, emptySet()))
        val hide = ModerationState.make(msg, town, 0, mac)
        assertNull(phone.accepts(hide.copy(body = Bytes.utf8("""{"at":0,"message":"X","room":"$town"}""")), town, emptySet()))
        assertNull(phone.accepts(mac.sign(hide.body, "ai-status"), town, emptySet()))
        phone.setTrusted(Bytes.hex(mac.signKey), false)
        assertFalse(phone.trusts(Bytes.hex(mac.signKey)))
        assertNull(phone.apply(ModerationState.make("11111111-2222-4333-8444-555555555555", town, 0, mac), town, emptySet()))
    }

    @Test fun savedAndLoaded() {
        val s = ModerationState().also { it.setTrusted(Bytes.hex(mac.signKey), true); it.apply(ModerationState.make(msg, town, 0, mac), town, emptySet()) }
        val back = ModerationState.fromJson(s.toJson())
        assertTrue(back.isHidden(msg)); assertTrue(back.trusts(Bytes.hex(mac.signKey))); assertEquals(1, back.records.size)
        assertEquals(Lane.URGENT, Lane.of(Kind.MODERATION, 400))
    }
}
