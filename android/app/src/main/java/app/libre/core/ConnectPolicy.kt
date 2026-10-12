// ConnectPolicy.kt: who to connect to over Bluetooth and when, same rules as
// Libre/Sources/Core/BLEConnectPolicy.swift (Oct 12, 2026). Our own design.
// Cap (phones 7, AI Mac hub 12), signal floor -88 dBm (-95 for a device verified this session),
// strongest first, one connect at a time on Android, 10 s connect timeout, backoff 2..60 s, and
// three quick retries (0.5, 1, 2 s) for GATT status 133. Ids are radio addresses; identity is
// settled by the signed hello (PeerBook).
package app.libre.core

class ConnectPolicy(val config: Config = Config.ANDROID) {
    data class Config(val maxLinks: Int = 7, val maxPending: Int = 2, val rssiFloor: Int = -88, val knownRssiFloor: Int = -95,
                      val connectTimeoutMs: Long = 10_000, val candidateLifetimeMs: Long = 30_000) {
        companion object {
            val PHONE = Config()
            val ANDROID = Config(maxPending = 1)
            val HUB = Config(maxLinks = 12)
        }
    }

    enum class Failure { GATT_ERROR_133, OTHER }

    companion object {
        const val GATT_ERROR_133 = 133
        val QUICK_RETRIES_MS = longArrayOf(500, 1000, 2000)
        const val MAX_BACKOFF_MS = 60_000L
    }

    private class Candidate(var rssi: Int, var seen: Long)
    private class Backoff(var quick: Int = 0, var slow: Int = 0, var until: Long = 0)

    private val candidates = HashMap<String, Candidate>()
    private val pending = HashMap<String, Long>()
    private val backoff = HashMap<String, Backoff>()
    private val known = HashSet<String>()
    private val excluded = HashSet<String>()

    @Synchronized fun pendingIds() = pending.keys.sorted()

    @Synchronized
    fun discovered(id: String, rssi: Int, now: Long = System.currentTimeMillis()): Boolean {
        if (id in excluded || pending.containsKey(id)) return false
        val strength = if (rssi == 127) config.rssiFloor else rssi
        val floor = if (id in known) config.knownRssiFloor else config.rssiFloor
        if (strength < floor) { candidates.remove(id); return false }
        val b = backoff[id]
        if (b != null && b.until > now) return false
        candidates[id] = Candidate(strength, now)
        return true
    }

    @Synchronized
    fun next(linked: Int, now: Long = System.currentTimeMillis()): List<String> {
        candidates.entries.removeIf { now - it.value.seen >= config.candidateLifetimeMs }
        var room = minOf(config.maxLinks - linked - pending.size, config.maxPending - pending.size)
        if (room <= 0) return emptyList()
        val out = ArrayList<String>()
        for ((id, _) in candidates.entries.sortedWith(compareByDescending<Map.Entry<String, Candidate>> { it.value.rssi }.thenBy { it.key })) {
            if (room <= 0) break
            val b = backoff[id]
            if (b != null && b.until > now) continue
            out.add(id); room--
        }
        for (id in out) { candidates.remove(id); pending[id] = now }
        return out
    }

    @Synchronized fun connected(id: String) { pending.remove(id); backoff.remove(id); excluded.add(id) }
    @Synchronized fun verified(id: String) { known.add(id) }
    @Synchronized fun disconnected(id: String) { pending.remove(id); excluded.remove(id) }
    @Synchronized fun exclude(id: String) { excluded.add(id); candidates.remove(id) }
    @Synchronized fun include(id: String) { excluded.remove(id) }

    /** Milliseconds before [id] may be tried again. */
    @Synchronized
    fun failed(id: String, failure: Failure, now: Long = System.currentTimeMillis()): Long {
        pending.remove(id); excluded.remove(id)
        val b = backoff.getOrPut(id) { Backoff() }
        val delay = if (failure == Failure.GATT_ERROR_133 && b.quick < QUICK_RETRIES_MS.size) QUICK_RETRIES_MS[b.quick++]
        else minOf(MAX_BACKOFF_MS, 2000L shl minOf(b.slow++, 20))
        b.until = now + delay
        return delay
    }

    @Synchronized
    fun timedOut(now: Long = System.currentTimeMillis()): List<String> {
        val late = pending.filterValues { now - it >= config.connectTimeoutMs }.keys.sorted()
        for (id in late) failed(id, Failure.OTHER, now)
        return late
    }

    @Synchronized fun backingOff(id: String, now: Long = System.currentTimeMillis()) = (backoff[id]?.until ?: 0) > now
    @Synchronized fun reset() { candidates.clear(); pending.clear(); excluded.clear() }
}
