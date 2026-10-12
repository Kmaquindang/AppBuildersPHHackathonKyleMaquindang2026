// PowerPolicyTest.kt: Bluetooth scan and advertise profiles by app state and battery (issue #4).
package app.libre.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PowerPolicyTest {
    private fun s(visible: Boolean, screen: Boolean, pct: Int?, charging: Boolean = false) = PowerPolicy.State(visible, screen, pct, charging)

    @Test fun onScreenIsFastUnlessBatteryLow() {
        assertEquals(PowerPolicy.FOREGROUND, PowerPolicy.choose(s(true, true, 80)))
        assertEquals(PowerPolicy.FOREGROUND, PowerPolicy.choose(s(true, true, null)))
        assertEquals(PowerPolicy.FOREGROUND_SAVER, PowerPolicy.choose(s(true, true, 19)))
        assertEquals("charging is never low", PowerPolicy.FOREGROUND, PowerPolicy.choose(s(true, true, 5, charging = true)))
        assertEquals("20% is not low yet", PowerPolicy.FOREGROUND, PowerPolicy.choose(s(true, true, 20)))
    }

    @Test fun hiddenIsSlowerAndSlowestOnLowBattery() {
        assertEquals(PowerPolicy.BACKGROUND, PowerPolicy.choose(s(false, true, 80)))
        assertEquals(PowerPolicy.SCREEN_OFF, PowerPolicy.choose(s(false, false, 80)))
        assertEquals("visible but screen off counts as screen off", PowerPolicy.SCREEN_OFF, PowerPolicy.choose(s(true, false, 80)))
        assertEquals(PowerPolicy.LOW_BATTERY, PowerPolicy.choose(s(false, false, 10)))
        assertEquals(PowerPolicy.LOW_BATTERY, PowerPolicy.choose(s(false, true, 10)))
        assertEquals(PowerPolicy.SCREEN_OFF, PowerPolicy.choose(s(false, false, 10, charging = true)))
    }

    @Test fun profilesGetSlowerAndStayUnderTheScanStartLimit() {
        val order = listOf(PowerPolicy.FOREGROUND, PowerPolicy.BACKGROUND, PowerPolicy.SCREEN_OFF, PowerPolicy.LOW_BATTERY)
        val dutyShare = order.map { it.scanOnMs.toDouble() / maxOf(it.periodMs, it.scanOnMs) }
        assertEquals("scan share never grows as the state gets quieter", dutyShare.sortedDescending(), dutyShare)
        for (p in PowerPolicy.ALL) {
            // Android allows five scan starts per 30 s per app; refresh and duty cycles use at most two.
            val startsPer30s = if (p.continuous) 30_000.0 / PowerPolicy.REFRESH_MS else 30_000.0 / p.periodMs
            assertTrue("${p.name}: $startsPer30s scan starts per 30 s", startsPer30s <= 2.0)
            assertTrue("${p.name}: scans for a while each time", p.scanOnMs >= 5_000)
        }
    }
}
