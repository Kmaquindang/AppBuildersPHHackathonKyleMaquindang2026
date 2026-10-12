// BleHandshake.kt: signed Bluetooth hello, proof and link book, byte for byte as
// Libre/Sources/Core/BLEHandshake.swift (Oct 12, 2026). Our own design.
//   hello: [2][Ed25519 key 32][challenge 16][flags 1 (bit 0 hub)][name length 1][name][sig 64],
//          sig over "libre-ble-hello-v2|" + everything before it.
//   proof: Ed25519 sig over "libre-ble-proof-v2|" + peer challenge + my key + peer key.
// A link counts only after the peer's hello verifies AND its proof signs our fresh challenge.
// Links are keyed by the peer's key; one name per key while linked; blocking follows the key;
// the device with the greater key (unsigned bytes) drops its own scanner link.
package app.libre.core

data class BleHello(val signKey: ByteArray, val nonce: ByteArray, val isHub: Boolean, val name: String, val signature: ByteArray) {
    val keyId: String get() = Bytes.hex(signKey)

    companion object {
        const val VERSION = 2
        const val NONCE = 16
        const val MAX_NAME = 64
        private val HELLO = Bytes.utf8("libre-ble-hello-v2|")
        private val PROOF = Bytes.utf8("libre-ble-proof-v2|")

        fun make(identity: DeviceIdentity, name: String, nonce: ByteArray, hub: Boolean = false): ByteArray? {
            val n = Bytes.utf8(name)
            if (n.isEmpty() || n.size > MAX_NAME || nonce.size != NONCE) return null
            val body = byteArrayOf(VERSION.toByte()) + identity.signKey + nonce + byteArrayOf(if (hub) 1 else 0, n.size.toByte()) + n
            return body + Crypto.ed25519Sign(identity.signSecret, HELLO + body)
        }

        fun open(data: ByteArray): BleHello? {
            if (data.size < 51 + 1 + 64 || (data[0].toInt() and 0xff) != VERSION) return null
            val n = data[50].toInt() and 0xff
            if (n < 1 || n > MAX_NAME || data.size != 51 + n + 64) return null
            val key = data.copyOfRange(1, 33)
            val sig = data.copyOfRange(51 + n, data.size)
            if (!Crypto.ed25519Verify(key, HELLO + data.copyOfRange(0, 51 + n), sig)) return null
            val name = try {
                Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(data, 51, n)).toString()
            } catch (e: Exception) { return null }
            return BleHello(key, data.copyOfRange(33, 49), (data[49].toInt() and 1) == 1, name, sig)
        }

        private fun proofMessage(challenge: ByteArray, signer: ByteArray, verifier: ByteArray) = PROOF + challenge + signer + verifier

        fun proof(identity: DeviceIdentity, peer: BleHello): ByteArray =
            Crypto.ed25519Sign(identity.signSecret, proofMessage(peer.nonce, identity.signKey, peer.signKey))

        fun checkProof(proof: ByteArray, peer: BleHello, myChallenge: ByteArray, myKey: ByteArray): Boolean =
            proof.size == 64 && Crypto.ed25519Verify(peer.signKey, proofMessage(myChallenge, peer.signKey, myKey), proof)

        fun keyGreater(a: ByteArray, b: ByteArray): Boolean {
            for (i in 0 until minOf(a.size, b.size)) {
                val x = a[i].toInt() and 0xff; val y = b[i].toInt() and 0xff
                if (x != y) return x > y
            }
            return a.size > b.size
        }
    }
}

/** Trust on first use for Bluetooth device keys (issue #12), as BLETrustStore in BLEHandshake.swift.
 *  The first key verified for a device name is remembered (BleTransport saves it to
 *  ble-trust.json); later, that name with a different key is refused and listed as a conflict until
 *  the person trusts the new key. */
class TrustStore(keys: Map<String, String> = emptyMap(), conflicts: Map<String, String> = emptyMap()) {
    sealed class Check { object Trusted : Check(); object FirstUse : Check(); data class Changed(val trustedKey: String) : Check() }

    private val keys = HashMap(keys)
    private val conflicts = HashMap(conflicts)
    val trusted: Map<String, String> get() = keys.toMap()
    val conflictNames: Map<String, String> get() = conflicts.toMap()

    fun check(name: String, keyId: String): Check {
        val known = keys[name] ?: return Check.FirstUse
        return if (known == keyId) Check.Trusted else Check.Changed(known)
    }

    fun remember(name: String, keyId: String): Boolean { if (name in keys) return false; keys[name] = keyId; return true }
    fun flag(name: String, keyId: String): Boolean { if (conflicts[name] == keyId) return false; conflicts[name] = keyId; return true }
    fun reset(name: String) { keys.remove(name); conflicts.remove(name) }

    fun toJson(): String = kotlinx.serialization.json.JsonObject(mapOf(
        "keys" to kotlinx.serialization.json.JsonObject(keys.mapValues { kotlinx.serialization.json.JsonPrimitive(it.value) }),
        "conflicts" to kotlinx.serialization.json.JsonObject(conflicts.mapValues { kotlinx.serialization.json.JsonPrimitive(it.value) }),
    )).toString()

    companion object {
        /** Reads toJson() output (and the Swift BLETrustStore JSON, which has the same two maps). */
        fun fromJson(text: String): TrustStore {
            val o = MeshCodec.parseObject(Bytes.utf8(text)) ?: return TrustStore()
            fun map(k: String) = (o[k] as? kotlinx.serialization.json.JsonObject)?.mapNotNull { (n, v) ->
                (v as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { n to it } }?.toMap() ?: emptyMap()
            return TrustStore(map("keys"), map("conflicts"))
        }
    }
}

class PeerBook(val identity: DeviceIdentity) {
    /** Keys remembered per device name. BleTransport loads and saves it. */
    var trust = TrustStore()

    enum class Role { CENTRAL, PERIPHERAL }
    class Link(val role: Role, val challenge: ByteArray) { var hello: BleHello? = null; var verified = false }

    sealed class HelloResult { data class SendProof(val proof: ByteArray) : HelloResult(); data class Rejected(val why: String) : HelloResult() }
    sealed class ProofResult {
        data class Verified(val name: String, val keyId: String, val newPeer: Boolean, val dropLink: String?, val replaced: String? = null) : ProofResult()
        data class Rejected(val why: String) : ProofResult()
    }

    private val myKey = identity.signKey
    private val links = HashMap<String, Link>()
    private var blockedNames: Set<String> = emptySet()
    private val blockedKeys = HashSet<String>()

    @Synchronized
    fun opened(id: String, role: Role, challenge: ByteArray = Crypto.randomBytes(BleHello.NONCE)): ByteArray =
        links.getOrPut(id) { Link(role, challenge) }.challenge

    @Synchronized
    fun receivedHello(data: ByteArray, id: String): HelloResult {
        val link = links[id] ?: return HelloResult.Rejected("no link")
        if (link.hello != null) return HelloResult.Rejected("second hello")
        val h = BleHello.open(data) ?: return HelloResult.Rejected("bad signature")
        if (h.signKey.contentEquals(myKey)) return HelloResult.Rejected("own key")
        if (isBlocked(h.keyId, h.name)) return HelloResult.Rejected("blocked")
        for ((oid, o) in links) {
            if (oid == id || !o.verified) continue
            val oh = o.hello ?: continue
            if (oh.name == h.name && !oh.signKey.contentEquals(h.signKey)) return HelloResult.Rejected("name ${h.name} is linked to another key")
            if (oh.signKey.contentEquals(h.signKey) && oh.name != h.name) return HelloResult.Rejected("key already linked as ${oh.name}")
        }
        // Trust on first use: a known name with a different key, even when nobody is linked.
        if (trust.check(h.name, h.keyId) is TrustStore.Check.Changed) {
            trust.flag(h.name, h.keyId)
            return HelloResult.Rejected("key changed for ${h.name}")
        }
        link.hello = h
        return HelloResult.SendProof(BleHello.proof(identity, h))
    }

    @Synchronized
    fun receivedProof(proof: ByteArray, id: String): ProofResult {
        val link = links[id] ?: return ProofResult.Rejected("proof before hello")
        val h = link.hello ?: return ProofResult.Rejected("proof before hello")
        if (link.verified) return ProofResult.Rejected("already verified")
        if (!BleHello.checkProof(proof, h, link.challenge, myKey)) return ProofResult.Rejected("bad proof")
        val newPeer = links.values.none { it.verified && it.hello?.signKey?.contentEquals(h.signKey) == true }
        // Same key, same role, older link: the peer's radio address changed (iPhones rotate theirs)
        // or the old link is stale. The new link takes over.
        val replaced = links.entries.firstOrNull { it.key != id && it.value.verified && it.value.role == link.role &&
            it.value.hello?.signKey?.contentEquals(h.signKey) == true }?.key
        if (replaced != null) links.remove(replaced)
        link.verified = true
        trust.remember(h.name, h.keyId)
        val mine = links.filter { it.value.verified && it.value.hello?.signKey?.contentEquals(h.signKey) == true }
        var drop: String? = null
        val central = mine.entries.firstOrNull { it.value.role == Role.CENTRAL }?.key
        if (central != null && mine.values.any { it.role == Role.PERIPHERAL } && BleHello.keyGreater(myKey, h.signKey)) {
            drop = central; links.remove(central)
        }
        return ProofResult.Verified(h.name, h.keyId, newPeer && replaced == null, drop, replaced)
    }

    data class Closed(val name: String, val keyId: String, val stillLinked: Boolean)

    @Synchronized
    fun closed(id: String): Closed? {
        val l = links.remove(id) ?: return null
        val h = l.hello ?: return null
        if (!l.verified) return null
        return Closed(h.name, h.keyId, links.values.any { it.verified && it.hello?.signKey?.contentEquals(h.signKey) == true })
    }

    @Synchronized fun isVerified(id: String) = links[id]?.verified == true
    @Synchronized fun peer(id: String): BleHello? = links[id]?.takeIf { it.verified }?.hello

    @Synchronized
    fun linkIds(name: String): List<String> = links.entries.filter { it.value.verified && it.value.hello?.name == name }
        .sortedWith(compareBy({ if (it.value.role == Role.CENTRAL) 0 else 1 }, { it.key })).map { it.key }

    @Synchronized
    fun linkedNames(): Set<String> = links.values.mapNotNull { l -> l.hello?.takeIf { l.verified && !isBlocked(it.keyId, it.name) }?.name }.toSet()

    @Synchronized
    fun keyIdFor(name: String): String? = links.values.firstOrNull { it.verified && it.hello?.name == name }?.hello?.keyId

    @Synchronized
    fun isHub(name: String) = links.values.any { it.verified && it.hello?.name == name && it.hello?.isHub == true }

    @Synchronized
    fun setBlocked(names: Set<String>): List<String> {
        blockedNames = names
        for (l in links.values) l.hello?.let { if (it.name in names) blockedKeys.add(it.keyId) }
        return links.entries.filter { e -> e.value.hello?.let { isBlocked(it.keyId, it.name) } == true }.map { it.key }.sorted()
    }

    @Synchronized fun isBlocked(keyId: String, name: String) = name in blockedNames || keyId in blockedKeys
    @Synchronized fun reset() = links.clear()
}
