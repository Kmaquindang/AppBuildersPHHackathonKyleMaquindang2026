// AdvertiseWatch.kt: keeps the Bluetooth advertiser alive, same rules as
// Libre/Sources/Core/AdvertiseWatch.swift (Oct 12, 2026). Our own design.
package app.libre.core

class AdvertiseWatch(isHub: Boolean = false, private val maxDelayMs: Long = 30_000) {
    enum class Action { NONE, RESTART }

    val firstDelayMs: Long = if (isHub) 1_000 else 2_000
    var failures = 0
        private set
    var lastAttempt: Long? = null
        private set

    val delayMs: Long get() = minOf(maxDelayMs, firstDelayMs shl minOf(20, maxOf(0, failures - 1)))

    fun attempted(now: Long = System.currentTimeMillis()) { lastAttempt = now }
    fun failed(now: Long = System.currentTimeMillis()) { failures++; lastAttempt = now }
    fun started() { failures = 0 }

    fun check(poweredOn: Boolean, advertising: Boolean, now: Long = System.currentTimeMillis()): Action {
        if (!poweredOn) { failures = 0; lastAttempt = null; return Action.NONE }
        if (advertising) { failures = 0; return Action.NONE }
        val last = lastAttempt ?: return Action.RESTART
        val wait = if (failures == 0) firstDelayMs else delayMs
        return if (now - last >= wait) Action.RESTART else Action.NONE
    }
}
