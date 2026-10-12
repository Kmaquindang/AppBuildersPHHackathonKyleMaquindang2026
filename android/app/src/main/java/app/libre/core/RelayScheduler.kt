// RelayScheduler.kt: relay jitter, cancel on duplicate, adaptive hop budget, same rules as
// Libre/Sources/Core/RelayScheduler.swift (Oct 12, 2026). Our own design.
package app.libre.core

import kotlin.random.Random

object RelayPolicy {
    const val DENSE_LINKS = 5
    const val CROWD_LINKS = 6
    const val CROWD_BROADCAST_TTL = 4
    const val DENSE_CANCEL_COPIES = 2

    fun forwardTtl(ttl: Int, links: Int, broadcast: Boolean) = if (broadcast && links >= CROWD_LINKS) minOf(ttl, CROWD_BROADCAST_TTL) else ttl

    fun jitterRange(broadcast: Boolean, links: Int): IntRange = when {
        !broadcast -> 0..30
        links >= DENSE_LINKS -> 30..250
        else -> 10..120
    }
}

class RelayScheduler<T> {
    class Pending<T>(val id: String, val item: T, val due: Long, val broadcast: Boolean, val links: Int, val targets: MutableSet<String>) {
        val heardFrom = HashSet<String>()
        var copiesHeard = 0
    }

    private val pending = HashMap<String, Pending<T>>()
    var cancelled = 0
        private set

    @Synchronized fun isPending(id: String) = pending.containsKey(id.uppercase())
    @Synchronized fun pending(id: String) = pending[id.uppercase()]

    /** Returns the delay in ms. */
    @Synchronized
    fun schedule(id: String, item: T, targets: Set<String>, broadcast: Boolean, links: Int, now: Long = System.currentTimeMillis(),
                 random: (IntRange) -> Int = { Random.nextInt(it.first, it.last + 1) }): Long {
        val ms = random(RelayPolicy.jitterRange(broadcast, links)).toLong()
        pending[id.uppercase()] = Pending(id.uppercase(), item, now + ms, broadcast, links, targets.toMutableSet())
        return ms
    }

    @Synchronized
    fun heardDuplicate(id: String, from: String): Boolean {
        val p = pending[id.uppercase()] ?: return false
        p.targets.remove(from); p.heardFrom.add(from); p.copiesHeard++
        val crowd = p.broadcast && p.links >= RelayPolicy.DENSE_LINKS && p.copiesHeard >= RelayPolicy.DENSE_CANCEL_COPIES
        if (p.targets.isEmpty() || crowd) { pending.remove(p.id); cancelled++; return true }
        return false
    }

    @Synchronized
    fun due(now: Long = System.currentTimeMillis()): List<Pending<T>> {
        val ready = pending.values.filter { it.due <= now }.sortedBy { it.due }
        for (p in ready) pending.remove(p.id)
        return ready
    }
}
