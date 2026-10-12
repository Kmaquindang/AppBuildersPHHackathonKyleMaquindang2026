// PowerPolicy.kt: how hard Android scans and advertises over Bluetooth, chosen from whether Libre
// is on screen, whether the screen is on, and the battery (issue #4). Our own design.
//
// Scanning only finds new devices; links already open stay open in every profile. So the slower
// profiles cost discovery time, not existing links:
//   foreground        Libre on screen: continuous low-latency scan, fast advertising, high power.
//   foreground saver  Libre on screen, battery under 20% and not charging: continuous balanced scan.
//   background        Libre hidden, screen on: balanced scan 10 s of every 30 s.
//   screen off        balanced advertising, low-power scan 10 s of every 60 s.
//   low battery       Libre hidden, under 20% and not charging: low-power scan 5 s of every 2 min,
//                     low-power advertising, low transmit power.
// Every duty-cycled profile starts a scan at most once per 30 s, well under Android's limit of
// five scan starts per 30 s per app. Battery use of each profile is not measured yet (issue #7).
package app.libre.core

object PowerPolicy {
    enum class Scan { LOW_LATENCY, BALANCED, LOW_POWER }
    enum class Advertise { LOW_LATENCY, BALANCED, LOW_POWER }
    enum class Tx { HIGH, MEDIUM, LOW }

    data class State(val appVisible: Boolean, val screenOn: Boolean, val batteryPct: Int?, val charging: Boolean)

    /** [scanOffMs] 0 means scan all the time (restarted every 25 s to refresh results). */
    data class Profile(val name: String, val scan: Scan, val scanOnMs: Long, val scanOffMs: Long, val advertise: Advertise, val tx: Tx) {
        val continuous: Boolean get() = scanOffMs == 0L
        val periodMs: Long get() = scanOnMs + scanOffMs
    }

    const val LOW_BATTERY_PCT = 20
    const val REFRESH_MS = 25_000L

    val FOREGROUND = Profile("foreground", Scan.LOW_LATENCY, REFRESH_MS, 0, Advertise.LOW_LATENCY, Tx.HIGH)
    val FOREGROUND_SAVER = Profile("foreground saver", Scan.BALANCED, REFRESH_MS, 0, Advertise.BALANCED, Tx.MEDIUM)
    val BACKGROUND = Profile("background", Scan.BALANCED, 10_000, 20_000, Advertise.BALANCED, Tx.MEDIUM)
    val SCREEN_OFF = Profile("screen off", Scan.LOW_POWER, 10_000, 50_000, Advertise.BALANCED, Tx.MEDIUM)
    val LOW_BATTERY = Profile("low battery", Scan.LOW_POWER, 5_000, 115_000, Advertise.LOW_POWER, Tx.LOW)
    val ALL = listOf(FOREGROUND, FOREGROUND_SAVER, BACKGROUND, SCREEN_OFF, LOW_BATTERY)

    fun lowBattery(s: State): Boolean = !s.charging && s.batteryPct != null && s.batteryPct < LOW_BATTERY_PCT

    fun choose(s: State): Profile = when {
        s.appVisible && s.screenOn -> if (lowBattery(s)) FOREGROUND_SAVER else FOREGROUND
        lowBattery(s) -> LOW_BATTERY
        !s.screenOn -> SCREEN_OFF
        else -> BACKGROUND
    }
}
