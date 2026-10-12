// RelayEngine.kt: multi-hop relay, same rules as Libre/Sources/Core/RelayEngine.swift.
// 1. Drop ids already seen (5 minute memory, at most 1000 ids).
// 2. Append this device to the path.
// 3. Deliver if broadcast, addressed to this device, or to a role it holds (Android holds none).
// 4. Forward broadcasts and messages not for us with ttl - 1 (ttl starts at 7), never to devices
//    already on the path.
package app.libre.core

class RelayEngine(var selfName: String, private val seenLifetimeMs: Long = 300_000, private val maxSeen: Int = 1000) {
    data class Decision(val isDuplicate: Boolean, val deliver: Packet?, val deliverHops: List<String>, val forward: ByteArray?, val forwardExcluding: Set<String>)

    private val seen = LinkedHashMap<String, Long>()
    var roles: Set<String> = emptySet()

    @Synchronized
    fun markSeen(id: String, now: Long = System.currentTimeMillis()) {
        prune(now)
        seen[id.uppercase()] = now
        while (seen.size > maxSeen) seen.remove(seen.keys.first())
    }

    @Synchronized
    fun hasSeen(id: String, now: Long = System.currentTimeMillis()): Boolean { prune(now); return seen.containsKey(id.uppercase()) }

    private fun prune(now: Long) { seen.entries.removeIf { now - it.value > seenLifetimeMs } }

    fun isAddressedToMe(p: Packet): Boolean = when (val d = p.destination) {
        null -> true
        is Destination.Peer -> d.name == selfName
        is Destination.Role -> d.role in roles
    }

    @Synchronized
    fun handleIncoming(p: Packet, sender: String, now: Long = System.currentTimeMillis()): Decision {
        val dup = Decision(true, null, emptyList(), null, emptySet())
        val id = p.id ?: return dup
        if (hasSeen(id, now)) return dup
        markSeen(id, now)
        if (p.origin == selfName) return dup
        val hops = (p.hops ?: emptyList()).toMutableList()
        if (hops.lastOrNull() != sender && sender != selfName && sender !in hops) hops.add(sender)
        hops.add(selfName)
        val forMe = isAddressedToMe(p)
        val ttl = p.ttl ?: 0
        val needsToTravel = p.destination == null || !forMe
        val forward = if (needsToTravel && ttl > 1) p.rewritten(ttl - 1, hops) else null
        return Decision(false, if (forMe) p else null, hops, forward, hops.toSet())
    }

    /** New message from this device, remembered so its echo is dropped. */
    fun makeOutgoing(kind: String, body: String, destination: Destination? = null, senderName: String? = null, now: Long = System.currentTimeMillis()): MeshMessage {
        val m = MeshMessage(origin = selfName, destination = destination, kind = kind, body = body, createdAt = now,
            senderName = senderName, v = MeshMessage.PROTOCOL_VERSION)
        markSeen(m.id, now)
        return m
    }
}
