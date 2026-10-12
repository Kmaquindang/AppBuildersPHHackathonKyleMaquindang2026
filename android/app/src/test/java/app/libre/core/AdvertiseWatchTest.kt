package app.libre.core

import org.junit.Assert.*
import org.junit.Test

class AdvertiseWatchTest {
    @Test fun retriesWithBackoff() {
        val w = AdvertiseWatch()
        assertEquals(AdvertiseWatch.Action.NONE, w.check(false, false, 0))
        assertEquals(AdvertiseWatch.Action.RESTART, w.check(true, false, 0))
        w.attempted(0)
        assertEquals(AdvertiseWatch.Action.NONE, w.check(true, false, 1_000))
        assertEquals(AdvertiseWatch.Action.RESTART, w.check(true, false, 2_000))
        repeat(3) { w.failed(0) }
        assertEquals(8_000L, w.delayMs)
        assertEquals(AdvertiseWatch.Action.NONE, w.check(true, false, 7_000))
        repeat(30) { w.failed(0) }
        assertEquals(30_000L, w.delayMs)
        assertEquals(AdvertiseWatch.Action.NONE, w.check(true, true, 0)); assertEquals(0, w.failures)
    }

    @Test fun hubRetriesFaster() {
        val h = AdvertiseWatch(isHub = true); h.attempted(0)
        assertEquals(AdvertiseWatch.Action.RESTART, h.check(true, false, 1_000))
    }
}
