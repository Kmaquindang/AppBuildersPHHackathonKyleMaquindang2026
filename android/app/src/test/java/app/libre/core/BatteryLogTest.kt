// BatteryLogTest.kt: same cases as Tests/CoreTests/BatteryLogTests.swift (issue #7).
package app.libre.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BatteryLogTest {
    @Test fun lineFormatMatchesTheIPhone() {
        assertEquals("BAT pct=83 charging=0 links=2 bright=0.50 state=bg os=iOS 26.0 model=iPhone15,3",
            BatteryLog.line(83, false, 2, 0.5, false, "iOS 26.0", "iPhone15,3"))
        assertEquals("BAT pct=-1 charging=1 links=0 bright=-1 state=fg os=Android 15 model=Pixel 8",
            BatteryLog.line(null, true, 0, null, true, "Android 15", "Pixel 8"))
    }

    @Test fun everyFiveMinutes() {
        assertTrue(BatteryLog.due(null, 1_000))
        assertFalse(BatteryLog.due(1_000, 1_000 + 299_999))
        assertTrue(BatteryLog.due(1_000, 1_000 + 300_000))
    }
}
