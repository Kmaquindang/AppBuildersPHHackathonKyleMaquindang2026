// Governance.kt: rooms on Android, and the member side of Libre/Sources/Core/RoomGovernance.swift:
// verify and accept the admin's signed manifest, open this device's key box, and ask to join
// (signed join request, with the code proof for code rooms). Android never acts as a room admin.
package app.libre.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull

data class RoomMember(val device: String, val name: String, val signKey: ByteArray, val boxKey: ByteArray) {
    val id: String get() = Bytes.b64url(signKey)
}

data class RoomManifest(
    val room: String, val label: String, val seq: Int, val adminKey: ByteArray, val adminName: String,
    val coAdmins: List<ByteArray>, val epoch: Int, val cap: Int, val state: String, val listed: Boolean,
    val members: List<RoomMember>, val banned: List<ByteArray>, val boxes: Map<String, ByteArray>,
    val codeCheck: ByteArray?, val creatorKey: ByteArray?, val codeEpoch: Int?,
) {
    val isFull: Boolean get() = members.size >= cap
    fun member(signKey: ByteArray) = members.firstOrNull { it.signKey.contentEquals(signKey) }
    fun isCoAdmin(k: ByteArray) = coAdmins.any { it.contentEquals(k) }
    fun isBanned(k: ByteArray) = banned.any { it.contentEquals(k) }

    companion object {
        fun parse(o: JsonObject?): RoomManifest? {
            o ?: return null
            fun s(k: String) = (o[k] as? JsonPrimitive)?.content
            fun i(k: String) = (o[k] as? JsonPrimitive)?.intOrNull
            fun b(k: String) = s(k)?.let { Bytes.unb64(it) }
            fun bl(k: String) = (o[k] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content?.let(Bytes::unb64) } ?: emptyList()
            return try {
                RoomManifest(
                    room = s("room") ?: return null, label = s("label") ?: "", seq = i("seq") ?: return null,
                    adminKey = b("adminKey") ?: return null, adminName = s("adminName") ?: "", coAdmins = bl("coAdmins"),
                    epoch = i("epoch") ?: return null, cap = i("cap") ?: return null, state = s("state") ?: "open",
                    listed = (o["listed"] as? JsonPrimitive)?.booleanOrNull ?: false,
                    members = (o["members"] as? JsonArray)?.mapNotNull { e ->
                        val m = e as? JsonObject ?: return@mapNotNull null
                        RoomMember((m["device"] as? JsonPrimitive)?.content ?: return@mapNotNull null,
                            (m["name"] as? JsonPrimitive)?.content ?: "",
                            (m["signKey"] as? JsonPrimitive)?.content?.let(Bytes::unb64) ?: return@mapNotNull null,
                            (m["boxKey"] as? JsonPrimitive)?.content?.let(Bytes::unb64) ?: return@mapNotNull null)
                    } ?: emptyList(),
                    banned = bl("banned"),
                    boxes = (o["boxes"] as? JsonObject)?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.content?.let(Bytes::unb64)?.let { k to it } }?.toMap() ?: emptyMap(),
                    codeCheck = b("codeCheck"), creatorKey = b("creatorKey"), codeEpoch = i("codeEpoch"),
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

/** A joined room, as saved on this phone. Byte fields are hex so the JSON stays readable. */
@Serializable
data class RoomState(
    val label: String,
    val keyHex: String,
    /** "code", "passcode", or null (Town Square). */
    val keySource: String? = null,
    val adminKeyHex: String? = null,
    /** The accepted signed manifest (SignedBlob JSON). */
    val manifestBlob: String? = null,
    val epochKeys: Map<String, String> = emptyMap(),
    val pending: Boolean = false,
    val removed: Boolean = false,
    val rotatedAt: Long? = null,
    /** Code rooms: key of the code this phone typed. Local only, never sent. */
    val codeKeyHex: String? = null,
) {
    val key: ByteArray get() = Bytes.unhex(keyHex)
    val id: String get() = RoomKeys.tag(key)
    val isDefault: Boolean get() = keyHex == Bytes.hex(RoomKeys.defaultKey)
    val displayName: String get() = if (isDefault) RoomNames.TOWN_SQUARE else label
    val usesCode: Boolean get() = keySource == "code"
    val signed: SignedBlob? get() = manifestBlob?.let { SignedBlob.fromJson(MeshCodec.parseObject(Bytes.utf8(it))) }
    val manifest: RoomManifest? get() = signed?.let { RoomManifest.parse(it.bodyJson()) }
    val epoch: Int get() = manifest?.epoch ?: 0
    val seq: Int get() = manifest?.seq ?: 0

    /** Key for sealing new content, or null while waiting for admission (Room.contentKey). */
    val contentKey: ByteArray? get() {
        val e = epoch
        if (e == 0) {
            if (!isDefault && manifestBlob == null && pending) return null
            return key
        }
        return epochKeys[e.toString()]?.let(Bytes::unhex)
    }

    fun openKey(e: Int, now: Long = System.currentTimeMillis()): ByteArray? {
        val current = epoch
        if (e == current) return if (e == 0) key else epochKeys[e.toString()]?.let(Bytes::unhex)
        val rotated = rotatedAt ?: return null
        if (e < current && (e > 0 || current == 0) && now - rotated <= Governor.PREVIOUS_EPOCH_GRACE_MS) {
            return epochKeys[e.toString()]?.let(Bytes::unhex)
        }
        return null
    }

    val isClosed: Boolean get() = manifest?.state == "closed"

    /** Why this phone cannot write here, or null. */
    val sendBlocker: String? get() = when {
        removed -> "An admin removed this phone from $label."
        isClosed -> "$label is closed by its admin."
        contentKey == null -> manifest?.takeIf { it.isFull }?.let { "$label is full (${it.members.size}/${it.cap})." }
            ?: "Waiting for a $label admin to let you in. An admin device must be nearby with Libre open."
        else -> null
    }

    companion object {
        fun townSquare() = RoomState(label = RoomNames.DEFAULT_LABEL, keyHex = Bytes.hex(RoomKeys.defaultKey))

        /** Code room: tag and base key from the name, admission by the code (PBKDF2, slow). */
        fun fromCode(name: String, code: String, rounds: Int = RoomKeys.ROUNDS): RoomState? {
            val label = RoomNames.cleanLabel(name)
            if (label.isEmpty() || RoomNames.isReserved(label)) return null
            val ck = CodeRoom.codeKey(label, code, rounds) ?: return null
            return RoomState(label = label, keyHex = Bytes.hex(CodeRoom.baseKey(label)), keySource = "code", pending = true,
                codeKeyHex = Bytes.hex(ck))
        }

        /** Passcode room (older Libre rooms): key from name and passcode (PBKDF2, slow). */
        fun fromPasscode(name: String, passcode: String, rounds: Int = RoomKeys.ROUNDS): RoomState? {
            val label = RoomNames.cleanLabel(name)
            if (label.isEmpty() || RoomNames.isReserved(label) || RoomNames.normalizedPasscode(passcode).length < 6) return null
            return RoomState(label = label, keyHex = Bytes.hex(RoomKeys.passcodeKey(label, passcode, rounds)), keySource = "passcode", pending = true)
        }
    }
}

/** Body of a .roomControl message (always sealed with the base key). */
data class RoomControl(val type: String, val blob: SignedBlob? = null, val haveSeq: Int? = null) {
    fun encoded(): String = JsonObject(buildMap {
        blob?.let { put("blob", it.toJson()) }
        haveSeq?.let { put("haveSeq", JsonPrimitive(it)) }
        put("type", JsonPrimitive(type))
    }.toSortedMap()).toString()

    companion object {
        fun decode(body: String): RoomControl? {
            val o = MeshCodec.parseObject(Bytes.utf8(body)) ?: return null
            val type = (o["type"] as? JsonPrimitive)?.content ?: return null
            return RoomControl(type, SignedBlob.fromJson(o["blob"] as? JsonObject), (o["haveSeq"] as? JsonPrimitive)?.intOrNull)
        }
    }
}

object Governor {
    const val MANIFEST_DOMAIN = "manifest"
    const val JOIN_DOMAIN = "join"
    const val PREVIOUS_EPOCH_GRACE_MS = 120_000L

    sealed class Acceptance {
        data class Applied(val room: RoomState, val admitted: Boolean, val removed: Boolean, val rekeyed: Boolean, val firstPin: Boolean) : Acceptance()
        object Stale : Acceptance()
        data class Rejected(val why: String) : Acceptance()
    }

    /** RoomGovernor.accept: signature, room, pinned admin (code check on first pin), seq up, epoch not down. */
    fun accept(blob: SignedBlob, room: RoomState, identity: DeviceIdentity, now: Long = System.currentTimeMillis()): Acceptance {
        if (blob.domain != MANIFEST_DOMAIN || !blob.isValid) return Acceptance.Rejected("bad signature")
        val m = RoomManifest.parse(blob.bodyJson()) ?: return Acceptance.Rejected("unreadable manifest")
        if (m.room != room.id) return Acceptance.Rejected("another room")
        var firstPin = false
        val pinned = room.adminKeyHex?.let(Bytes::unhex)
        if (pinned != null) {
            if (!m.adminKey.contentEquals(pinned)) return Acceptance.Rejected("admin key does not match the pinned admin")
        } else {
            if (!blob.signer.contentEquals(m.adminKey)) return Acceptance.Rejected("first manifest must be signed by its admin")
            if (room.usesCode) {
                val ck = room.codeKeyHex?.let(Bytes::unhex)
                val check = m.codeCheck
                if (ck == null || check == null || !CodeRoom.same(check, CodeRoom.check(ck, m.adminKey))) {
                    return Acceptance.Rejected("the room code does not match")
                }
            }
            firstPin = true
        }
        val current = room.manifest
        val byAdmin = blob.signer.contentEquals(m.adminKey)
        val byCoAdmin = current?.let { it.isCoAdmin(blob.signer) && it.member(blob.signer) != null } ?: false
        if (!byAdmin && !byCoAdmin) return Acceptance.Rejected("not signed by a room admin")
        if (current != null) {
            if (m.seq <= current.seq) return Acceptance.Stale
            if (m.epoch < current.epoch) return Acceptance.Rejected("epoch went backwards")
        }
        if (m.cap < 2 || m.cap > 30 || m.seq <= 0 || m.epoch < 0) return Acceptance.Rejected("out of range")

        val keys = room.epochKeys.toMutableMap()
        val me = m.member(identity.signKey)
        val wasMember = current?.member(identity.signKey) != null
        if (m.epoch > 0 && me != null && keys[m.epoch.toString()] == null) {
            m.boxes[Bytes.b64url(identity.signKey)]?.let { KeyBox.open(it, identity.boxSecret, room.id, m.epoch) }?.let {
                keys[m.epoch.toString()] = Bytes.hex(it)
            }
        }
        var rotatedAt = room.rotatedAt
        var rekeyed = false
        if (current != null && m.epoch > current.epoch) { rekeyed = true; rotatedAt = now }
        var pending = room.pending
        var removed = room.removed
        var removedNow = false
        var admitted = false
        if (me == null) {
            if (wasMember || m.isBanned(identity.signKey)) { removedNow = !removed; removed = true; pending = false } else pending = true
        } else {
            admitted = pending || removed
            pending = false
            removed = false
        }
        val keep = (maxOf(0, m.epoch - 2)..m.epoch).map { it.toString() }.toSet()
        val next = room.copy(
            adminKeyHex = Bytes.hex(m.adminKey), manifestBlob = blob.toJson().toString(),
            epochKeys = keys.filterKeys { it in keep }, pending = pending, removed = removed, rotatedAt = rotatedAt,
        )
        return Acceptance.Applied(next, admitted, removedNow, rekeyed, firstPin)
    }

    /** Signed join request (sorted-key JSON, dates in ms, bytes base64), as RoomGovernor.joinRequest. */
    fun joinRequest(room: RoomState, identity: DeviceIdentity, device: String, name: String, now: Long = System.currentTimeMillis()): SignedBlob {
        val fields = sortedMapOf<String, kotlinx.serialization.json.JsonElement>(
            "at" to JsonPrimitive(now), "boxKey" to JsonPrimitive(Bytes.b64(identity.boxKey)), "device" to JsonPrimitive(device),
            "name" to JsonPrimitive(name), "room" to JsonPrimitive(room.id), "signKey" to JsonPrimitive(Bytes.b64(identity.signKey)),
        )
        if (room.usesCode) room.codeKeyHex?.let {
            fields["proof"] = JsonPrimitive(Bytes.b64(CodeRoom.proof(Bytes.unhex(it), room.id, identity.signKey)))
        }
        return identity.sign(Bytes.utf8(JsonObject(fields).toString()), JOIN_DOMAIN)
    }

    /** RoomGovernor.wantsAdmission. */
    fun wantsAdmission(room: RoomState, identity: DeviceIdentity): Boolean {
        if (room.isDefault || room.removed) return false
        val m = room.manifest ?: return room.pending
        if (m.member(identity.signKey) != null) return false
        return m.state == "open" && !m.isFull && !m.isBanned(identity.signKey)
    }
}
