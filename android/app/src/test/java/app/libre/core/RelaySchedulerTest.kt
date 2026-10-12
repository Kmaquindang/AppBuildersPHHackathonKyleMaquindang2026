package app.libre.core

import org.junit.Assert.*
import org.junit.Test

class RelaySchedulerTest {
    @Test fun jitterRangesFollowDensity() {
        assertEquals(0..30, RelayPolicy.jitterRange(false, 9))
        assertEquals(10..120, RelayPolicy.jitterRange(true, 2))
        assertEquals(30..250, RelayPolicy.jitterRange(true, 5))
    }

    @Test fun crowdCapsBroadcastHopsOnly() {
        assertEquals(6, RelayPolicy.forwardTtl(6, 5, true))
        assertEquals(4, RelayPolicy.forwardTtl(6, 6, true))
        assertEquals(6, RelayPolicy.forwardTtl(6, 9, false))
        assertEquals(2, RelayPolicy.forwardTtl(2, 9, true))
    }

    @Test fun cancelsWhenEveryTargetHeardIt() {
        val s = RelayScheduler<Int>()
        s.schedule("a", 1, setOf("X", "Y"), true, 2, now = 0) { it.first }
        assertFalse(s.heardDuplicate("A", "X"))
        assertTrue(s.heardDuplicate("a", "Y"))
        assertFalse(s.isPending("a")); assertEquals(1, s.cancelled)
    }

    @Test fun crowdCancelsAfterTwoCopiesAndDueReleases() {
        val s = RelayScheduler<Int>()
        s.schedule("b", 1, setOf("1", "2", "3", "4", "5"), true, 5, now = 0) { it.first }
        assertFalse(s.heardDuplicate("b", "1")); assertTrue(s.heardDuplicate("b", "2"))
        val d = s.schedule("c", 2, setOf("Z"), false, 1, now = 0) { it.last }
        assertEquals(30L, d)
        assertTrue(s.due(now = 29).isEmpty()); assertEquals(1, s.due(now = 30).size)
    }
}
