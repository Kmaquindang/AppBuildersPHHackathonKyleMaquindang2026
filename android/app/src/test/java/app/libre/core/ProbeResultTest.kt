// ProbeResultTest.kt: same numbers as BLEProbeResult in Libre/Sources/Core/BLEFraming.swift.
package app.libre.core

import org.junit.Assert.assertEquals
import org.junit.Test

class ProbeResultTest {
    @Test fun speedFromRoundTrip() {
        assertEquals(8000.0, ProbeResult(4096, 182, 512).bytesPerSecond, 0.001)
        assertEquals(0.0, ProbeResult(4096, 182, 0).bytesPerSecond, 0.0)
    }

    @Test fun logLineMatchesTheIPhoneFormat() {
        assertEquals("probe Ben Mac role=central mtu=247 bytes=4096 rtt_ms=300 Bps=13653",
            ProbeResult(ProbeResult.PROBE_BYTES, 247, 300).logLine("Ben Mac", "central"))
    }
}
