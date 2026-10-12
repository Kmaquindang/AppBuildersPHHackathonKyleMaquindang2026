// MeshController.kt: the Android side of MeshService (pure Kotlin, no Android imports, so it is
// unit tested on the JVM with a fake link). It owns identity, rooms, timelines and the relay,
// and talks to the radio through [Link] (BleTransport on a phone).
//
// What it does, as on iPhone:
// - Every packet goes through RelayEngine: duplicates dropped by id, path appended, forwarded
//   with ttl - 1 to linked devices not on the path (other rooms' packets too, unread).
// - Room packets are opened with the room's key for their epoch. Chat, answers, tasks, rules and
//   Knowledge titles are shown; asks go to the AI role (the Mac answers them).
// - Code rooms: the phone sends a signed join request (with the code proof) sealed with the
//   room's base key, and asks for the manifest, until an admin admits it; then it opens its key
//   box from the signed manifest and can read and write.
// Android never answers asks, never acts as an admin, and does not send photos or voice notes.
package app.libre.mesh

import app.libre.core.AssistantMention
import app.libre.core.Bytes
import app.libre.core.Destination
import app.libre.core.Lane
import app.libre.core.RelayScheduler
import app.libre.core.DeviceIdentity
import app.libre.core.Governor
import app.libre.core.Kind
import app.libre.core.LibraryListing
import app.libre.core.MeshCodec
import app.libre.core.MeshMessage
import app.libre.core.Packet
import app.libre.core.RelayEngine
import app.libre.core.RoomControl
import app.libre.core.RoomEnvelope
import app.libre.core.RoomState
import app.libre.core.RuleItem
import app.libre.core.SyncPayload
import app.libre.core.TaskItem
import app.libre.core.AnswerStreams
import app.libre.core.PeerSync
import app.libre.core.ModerationState
import app.libre.core.SignedBlob
import app.libre.core.PasaSign
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import java.io.File

/** The radio as the controller sees it. */
interface Link {
    /** Names of devices linked right now. */
    val linkedPeers: Set<String>
    /** Sends to these peers at a Bluetooth priority lane; returns who it was handed to. */
    fun send(data: ByteArray, to: Set<String>, lane: Lane = Lane.of(null, data.size)): Set<String>
}

@Serializable
data class DocChip(val title: String, val page: Int? = null, val version: Int = 1, val excerpt: String = "") {
    val label: String get() = listOfNotNull(title, page?.let { "p.$it" }, "v$version").joinToString(", ")
}

@Serializable
data class Entry(
    val id: String,
    val kind: String,
    val body: String,
    val origin: String,
    val senderName: String? = null,
    val createdAt: Long,
    val receivedAt: Long,
    val mine: Boolean,
    val hops: List<String> = emptyList(),
    /** "Bluetooth" for everything Android sends and receives. */
    val link: String? = null,
    val sentTo: List<String> = emptyList(),
    val replyTo: String? = null,
    val rulesUsed: List<String> = emptyList(),
    val unverifiedRules: List<String> = emptyList(),
    val docRefs: List<DocChip> = emptyList(),
    val noRule: Boolean = false,
    val model: String? = null,
    val proofLine: String? = null,
    val backfilled: Boolean = false,
) {
    val isAnswer: Boolean get() = kind == Kind.ANSWER
}

@Serializable
data class Profile(val personName: String = "", val meshName: String = "", val onboarded: Boolean = false)

@Serializable
private data class SavedIdentity(val signSecret: String, val boxSecret: String)

@Serializable
private data class SavedRooms(val rooms: List<RoomState>, val activeId: String)

@Serializable
data class RoomCache(val tasks: List<TaskItem> = emptyList(), val rules: List<RuleItem> = emptyList(), val library: List<LibraryListing> = emptyList())

class MeshController(private val dir: File, private val now: () -> Long = { System.currentTimeMillis() }) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = false }
    var link: Link? = null

    val identity: DeviceIdentity
    private val _profile = MutableStateFlow(Profile())
    val profile: StateFlow<Profile> = _profile

    private val _rooms = MutableStateFlow<List<RoomState>>(emptyList())
    val rooms: StateFlow<List<RoomState>> = _rooms
    private val _activeId = MutableStateFlow("")
    val activeId: StateFlow<String> = _activeId

    private val timelines = HashMap<String, MutableList<Entry>>()
    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    /** Timeline of the active room, oldest first. */
    val entries: StateFlow<List<Entry>> = _entries

    private val caches = HashMap<String, RoomCache>()
    private val _cache = MutableStateFlow(RoomCache())
    val cache: StateFlow<RoomCache> = _cache

    private val _peers = MutableStateFlow<Set<String>>(emptySet())
    val peers: StateFlow<Set<String>> = _peers
    private val _problem = MutableStateFlow<String?>(null)
    val problem: StateFlow<String?> = _problem
    private val _lastAiHeard = MutableStateFlow(0L)
    val lastAiHeard: StateFlow<Long> = _lastAiHeard
    /** Asks sent from here that have no answer yet (ids). */
    private val _waiting = MutableStateFlow<Set<String>>(emptySet())
    val waiting: StateFlow<Set<String>> = _waiting
    /** Streamed answers still being written in the active room (issue #2): ask id and text so far. */
    private val streams = AnswerStreams()
    private val _partials = MutableStateFlow<List<PartialAnswer>>(emptyList())
    val partials: StateFlow<List<PartialAnswer>> = _partials
    /** When each waiting ask was sent, for the measured round trip. */
    private val askSentAt = HashMap<String, Long>()
    /** One line per received chat or answer for device tests (issue #1, same format as the
     *  iPhone's ble-log.txt): link, hops, round trip, AI time. Numbers only, never text.
     *  LibreApp sends it to logcat (tag LibreMesh). */
    var timingLog: (String) -> Unit = {}

    private val engine: RelayEngine
    private val outbox = mutableListOf<Pair<ByteArray, Long>>()
    private val lastJoin = HashMap<String, Long>()
    private val lastWant = HashMap<String, Long>()
    private var lastBackfill = 0L

    val activeRoom: RoomState get() = _rooms.value.firstOrNull { it.id == _activeId.value } ?: _rooms.value.first()

    init {
        dir.mkdirs()
        identity = load("identity.json", SavedIdentity.serializer())?.let { DeviceIdentity(Bytes.unhex(it.signSecret), Bytes.unhex(it.boxSecret)) }
            ?: DeviceIdentity.generate().also { save("identity.json", SavedIdentity.serializer(), SavedIdentity(Bytes.hex(it.signSecret), Bytes.hex(it.boxSecret))) }
        _profile.value = load("profile.json", Profile.serializer()) ?: Profile()
        val saved = load("rooms.json", SavedRooms.serializer())
        val list = saved?.rooms?.takeIf { it.isNotEmpty() } ?: listOf(RoomState.townSquare())
        _rooms.value = list
        _activeId.value = saved?.activeId?.takeIf { id -> list.any { it.id == id } } ?: list.first().id
        engine = RelayEngine(meshName())
        for (r in list) {
            timelines[r.id] = (load("timeline-${r.id}.json", ListSerializer(Entry.serializer())) ?: emptyList()).toMutableList()
            caches[r.id] = load("cache-${r.id}.json", RoomCache.serializer()) ?: RoomCache()
        }
        publish()
    }

    // MARK: Profile

    fun meshName(): String = _profile.value.meshName.ifEmpty { "Android" }

    /** Onboarding: the person's name, and a mesh device name ("<model>-<4 hex>") unique on the mesh. */
    fun completeOnboarding(personName: String, model: String) {
        val mesh = _profile.value.meshName.ifEmpty { sanitize(model.ifBlank { "Android" }) + "-" + Bytes.hex(identity.signKey).take(4).uppercase() }
        _profile.value = Profile(personName.trim().take(40), mesh, true)
        engine.selfName = mesh
        save("profile.json", Profile.serializer(), _profile.value)
    }

    private fun sanitize(raw: String): String {
        var s = raw.trim().ifEmpty { "Android" }
        while (Bytes.utf8(s).size > 50) s = s.dropLast(1)
        return s
    }

    private fun displayLabel(): String = _profile.value.personName.ifEmpty { meshName() }

    // MARK: Rooms

    fun activate(id: String) {
        if (_rooms.value.none { it.id == id }) return
        _activeId.value = id
        saveRooms(); publish(); publishPartials()
        afterJoin(id)
    }

    /** Adds (or refreshes) a room and makes it active. Slow key derivation happens before this. */
    fun join(room: RoomState) {
        val existing = _rooms.value.firstOrNull { it.id == room.id }
        val merged = if (existing != null) existing.copy(codeKeyHex = room.codeKeyHex ?: existing.codeKeyHex,
            removed = false, pending = existing.manifest?.member(identity.signKey) == null) else room
        _rooms.value = _rooms.value.filter { it.id != room.id } + merged
        timelines.getOrPut(room.id) { mutableListOf() }
        caches.getOrPut(room.id) { RoomCache() }
        _activeId.value = room.id
        lastJoin.remove(room.id); lastWant.remove(room.id)
        saveRooms(); publish()
        afterJoin(room.id)
    }

    fun leave(id: String) {
        val r = _rooms.value.firstOrNull { it.id == id } ?: return
        if (r.isDefault) return
        _rooms.value = _rooms.value.filter { it.id != id }
        if (_activeId.value == id) _activeId.value = _rooms.value.first().id
        saveRooms(); publish()
    }

    private fun update(id: String, f: (RoomState) -> RoomState) {
        _rooms.value = _rooms.value.map { if (it.id == id) f(it) else it }
        saveRooms()
    }

    private fun afterJoin(id: String) {
        val room = _rooms.value.firstOrNull { it.id == id } ?: return
        if (room.isDefault) { requestBackfill(); return }
        requestManifest(id, force = true)
        sendJoinRequestIfNeeded(id, force = true)
        if (room.contentKey != null) requestBackfill()
    }

    private fun requestManifest(id: String, force: Boolean = false) {
        val room = _rooms.value.firstOrNull { it.id == id } ?: return
        if (room.isDefault || room.removed) return
        if (!force && now() - (lastWant[id] ?: 0) < 10_000) return
        lastWant[id] = now()
        val body = RoomControl("want", haveSeq = room.seq).encoded()
        transmit(engine.makeOutgoing(Kind.ROOM_CONTROL, body, senderName = displayLabel(), now = now()), room, queue = false)
    }

    private fun sendJoinRequestIfNeeded(id: String, force: Boolean = false) {
        val room = _rooms.value.firstOrNull { it.id == id } ?: return
        if (!Governor.wantsAdmission(room, identity)) return
        if (!force && now() - (lastJoin[id] ?: 0) < 15_000) return
        lastJoin[id] = now()
        val blob = Governor.joinRequest(room, identity, meshName(), displayLabel(), now())
        val body = RoomControl("join", blob = blob).encoded()
        transmit(engine.makeOutgoing(Kind.ROOM_CONTROL, body, senderName = displayLabel(), now = now()), room, queue = false)
    }

    // MARK: Sending

    /** One composer: "@libre ..." asks the AI laptop, anything else is team chat. */
    fun send(raw: String): Boolean {
        var text = raw.trim()
        if (text.isEmpty()) return false
        val room = activeRoom
        room.sendBlocker?.let { _problem.value = it; return false }
        var kind = Kind.CHAT
        AssistantMention.strip(text)?.let { q -> if (q.isEmpty()) return false; kind = Kind.ASK; text = q }
        val dest = if (kind == Kind.ASK) Destination.Role(Destination.AI_ROLE) else null
        val m = engine.makeOutgoing(kind, text, dest, displayLabel(), now())
        val sentTo = transmit(m, room, queue = true)
        addEntry(room.id, Entry(id = m.id, kind = kind, body = text, origin = m.origin, senderName = m.senderName, createdAt = m.createdAt,
            receivedAt = now(), mine = true, hops = m.hops, link = if (sentTo.isEmpty()) null else "Bluetooth", sentTo = sentTo.sorted()))
        if (kind == Kind.ASK) { _waiting.value = _waiting.value + m.id; askSentAt[m.id] = now() }
        return true
    }

    /** Seals [plain] for [room] (room control with the base key, content with the epoch key) and sends it. */
    private fun transmit(plain: MeshMessage, room: RoomState, queue: Boolean, excluding: Set<String> = emptySet()): Set<String> {
        val control = plain.kind == Kind.ROOM_CONTROL
        val key = if (control) room.key else room.contentKey ?: return emptySet()
        val epoch = if (control) 0 else room.epoch
        val data = MeshCodec.encode(RoomEnvelope.seal(plain, room.id, key, epoch))
        return sendRaw(data, excluding, queue, Lane.of(plain.kind, data.size))
    }

    private fun sendRaw(data: ByteArray, excluding: Set<String>, queue: Boolean, lane: Lane = Lane.of(null, data.size)): Set<String> {
        val l = link
        val targets = (l?.linkedPeers ?: emptySet()) - excluding
        val sent = if (l != null && targets.isNotEmpty()) l.send(data, targets, lane) else emptySet()
        if (sent.isEmpty() && queue) synchronized(outbox) { outbox.add(data to now()); while (outbox.size > 200) outbox.removeAt(0) }
        return sent
    }

    private fun flushOutbox() {
        val items = synchronized(outbox) { outbox.toList().also { outbox.clear() } }
        val cutoff = now() - 86_400_000
        for ((data, at) in items) if (at >= cutoff) sendRaw(data, emptySet(), queue = true)
        // Entries sent while nobody was in range: mark them handed over now.
        val peers = link?.linkedPeers ?: emptySet()
        if (items.isNotEmpty() && peers.isNotEmpty()) {
            for ((id, list) in timelines) {
                var changed = false
                for (i in list.indices) if (list[i].mine && list[i].sentTo.isEmpty()) { list[i] = list[i].copy(sentTo = peers.sorted(), link = "Bluetooth"); changed = true }
                if (changed) saveTimeline(id)
            }
            publish()
        }
    }

    private fun requestBackfill() {
        val room = activeRoom
        if (room.contentKey == null || now() - lastBackfill < 10_000) return
        lastBackfill = now()
        val list = timelines[room.id] ?: emptyList()
        val body = SyncPayload.request(list.maxOfOrNull { it.createdAt }, list.map { it.id })
        transmit(engine.makeOutgoing(Kind.SYNC, body, Destination.Role(Destination.AI_ROLE), displayLabel(), now()), room, queue = false)
    }

    // MARK: Link events

    fun peerLinked(name: String) {
        _peers.value = _peers.value + name
        flushOutbox()
        for (r in _rooms.value) if (!r.isDefault) { requestManifest(r.id); sendJoinRequestIfNeeded(r.id) }
        lastBackfill = 0
        requestBackfill()
        requestPeerSync(name)
        sendHides(name)
    }

    // MARK: Town Square moderation (issue #9)

    private val moderationFile get() = dir.resolve("moderation.json")
    private val moderation: ModerationState by lazy { runCatching { ModerationState.fromJson(moderationFile.readText()) }.getOrDefault(ModerationState()) }
    private val _aiMacKey = MutableStateFlow<String?>(null)
    /** Key (hex) that signs the AI Mac's status beacon, once one was heard. */
    val aiMacKey: StateFlow<String?> = _aiMacKey
    private val _trustsAiMac = MutableStateFlow(false)
    /** The person lets the AI Mac in view hide Town Square messages. */
    val trustsAiMac: StateFlow<Boolean> = _trustsAiMac

    fun setTrustAiMac(on: Boolean) {
        val key = _aiMacKey.value ?: return
        moderation.setTrusted(key, on)
        _trustsAiMac.value = moderation.trusts(key)
        saveModeration()
    }

    private fun saveModeration() { runCatching { moderationFile.writeText(moderation.toJson()) } }

    private fun receiveHide(m: MeshMessage, roomId: String) {
        val town = _rooms.value.firstOrNull { it.isDefault } ?: return
        if (roomId != town.id) return
        val blob = SignedBlob.fromJson(MeshCodec.parseObject(Bytes.utf8(m.body))) ?: return
        val adminKeys = _rooms.value.mapNotNull { it.adminKeyHex }.toSet()
        val id = moderation.apply(blob, town.id, adminKeys, Bytes.hex(identity.signKey)) ?: return
        timelines[roomId]?.removeAll { it.id == id }
        saveModeration(); saveTimeline(roomId); publish()
    }

    /** Passes the hide records this phone accepted to a newly linked device (newest 50). */
    private fun sendHides(device: String) {
        val town = _rooms.value.firstOrNull { it.isDefault } ?: return
        for (blob in moderation.records.takeLast(50)) {
            transmit(engine.makeOutgoing(Kind.MODERATION, blob.toJson().toString(), Destination.Peer(device), displayLabel(), now()), town, queue = false)
        }
    }

    /** Phone-to-phone sync (PeerSync, issue #6): when each peer was last asked and answered. */
    private val peerSyncAsked = HashMap<String, Long>()
    private val peerSyncAnswered = HashMap<String, Long>()

    /** Asks a newly linked device for the active room's recent team chat this phone lacks. */
    private fun requestPeerSync(device: String) {
        val room = activeRoom
        if (room.contentKey == null || now() - (peerSyncAsked[device] ?: Long.MIN_VALUE / 2) < PeerSync.ASK_EVERY_MS) return
        peerSyncAsked[device] = now()
        val body = PeerSync.requestBody(teamChat(room.id), now())
        transmit(engine.makeOutgoing(Kind.SYNC, body, Destination.Peer(device), displayLabel(), now()), room, queue = false)
    }

    /** Answers a phone's sync request with the team chat it is missing (bulk lane), once a minute per asker. */
    private fun servePeerSync(device: String, roomId: String, req: PeerSync.Request) {
        val room = _rooms.value.firstOrNull { it.id == roomId } ?: return
        if (device == meshName() || now() - (peerSyncAnswered[device] ?: Long.MIN_VALUE / 2) < PeerSync.ANSWER_EVERY_MS) return
        peerSyncAnswered[device] = now()
        val missing = PeerSync.select(teamChat(roomId), req, now())
        for (body in PeerSync.batchBodies(missing)) {
            transmit(engine.makeOutgoing(Kind.SYNC, body, Destination.Peer(device), displayLabel(), now()), room, queue = false)
        }
    }

    /** Team chat in a room's timeline, as messages (Android keeps no private chat). */
    private fun teamChat(roomId: String): List<MeshMessage> = (timelines[roomId] ?: emptyList()).filter { it.kind == Kind.CHAT }.map {
        MeshMessage(id = it.id, origin = it.origin, kind = Kind.CHAT, body = it.body, hops = it.hops.ifEmpty { listOf(it.origin) },
            createdAt = it.createdAt, senderName = it.senderName, v = MeshMessage.PROTOCOL_VERSION)
    }

    fun peerUnlinked(name: String) { _peers.value = _peers.value - name }

    /** Every few seconds: retry joins and manifest requests, send what waits. */
    fun tick() {
        for (r in _rooms.value) if (!r.isDefault && Governor.wantsAdmission(r, identity)) { requestManifest(r.id); sendJoinRequestIfNeeded(r.id) }
        if (synchronized(outbox) { outbox.isNotEmpty() } && (link?.linkedPeers?.isNotEmpty() == true)) flushOutbox()
        if (streams.expire(now()).isNotEmpty()) publishPartials()
    }

    private fun publishPartials() {
        val room = _activeId.value
        val now = streams.open(room).mapNotNull { id -> streams.text(id)?.let { PartialAnswer(id, it) } }
        if (now != _partials.value) _partials.value = now
    }

    // MARK: Receiving

    /** Runs a relay after a delay in ms (the app posts it on the mesh thread). Null: relay at once (tests). */
    var postDelayed: ((Long, () -> Unit) -> Unit)? = null
    private class RelayJob(val data: ByteArray, val excluding: Set<String>)
    private val relays = RelayScheduler<RelayJob>()
    /** Relays not sent because every neighbor (or enough of a crowd) already had the packet. */
    val relaysSaved: Int get() = relays.cancelled

    /** Waits a short random time before relaying so a neighbor's copy can make ours unnecessary. */
    private fun scheduleRelay(id: String, data: ByteArray, excluding: Set<String>, broadcast: Boolean) {
        val peers = link?.linkedPeers ?: emptySet()
        val targets = peers - excluding
        val post = postDelayed
        if (targets.isEmpty() || post == null) { sendRaw(data, excluding, queue = false); return }
        val delay = relays.schedule(id, RelayJob(data, excluding), targets, broadcast, peers.size, now())
        post(delay) { fireRelays() }
    }

    @Synchronized
    fun fireRelays() {
        for (p in relays.due(now())) sendRaw(p.item.data, p.item.excluding + p.heardFrom, queue = false)
    }

    @Synchronized
    fun receive(data: ByteArray, from: String, viaLink: String = "Bluetooth") {
        val packet = Packet.parse(data) ?: return
        val d = engine.handleIncoming(packet, from, now(), link?.linkedPeers?.size ?: 0)
        if (d.isDuplicate) { packet.id?.let { relays.heardDuplicate(it, from) }; return }
        d.forward?.let { scheduleRelay(packet.id ?: "", it, d.forwardExcluding, packet.destination == null) }
        val delivered = d.deliver?.message ?: return
        val message = delivered.copy(hops = d.deliverHops)
        when (message.kind) {
            Kind.AI_STATUS -> {
                _lastAiHeard.value = now()
                SignedBlob.fromJson(MeshCodec.parseObject(Bytes.utf8(message.body)))?.takeIf { it.domain == "ai-status" && PasaSign.verify(it) }?.let {
                    val key = Bytes.hex(it.signer)
                    if (_aiMacKey.value != key) { _aiMacKey.value = key; _trustsAiMac.value = moderation.trusts(key) }
                }
                return
            }
            Kind.BEACON -> return
            Kind.SEALED -> {
                val room = _rooms.value.firstOrNull { it.id == message.room } ?: return
                val key = room.openKey(message.epoch ?: 0, now()) ?: return
                val inner = RoomEnvelope.open(message, room.id, key) ?: return
                if (inner.kind == Kind.ROOM_CONTROL) { handleRoomControl(inner, room.id); return }
                if ((message.epoch ?: 0) == 0 && room.epoch > 0) return
                // Joined by passcode, no manifest yet, and the room still uses the passcode key: a room from before admin keys.
                if (room.pending && room.manifestBlob == null && (message.epoch ?: 0) == 0 && !room.isDefault) update(room.id) { it.copy(pending = false) }
                handleContent(inner, room.id, viaLink, backfilled = false)
            }
            else -> {
                // Plaintext from builds before rooms belongs to Town Square.
                val town = _rooms.value.firstOrNull { it.isDefault } ?: return
                handleContent(message, town.id, viaLink, backfilled = false)
            }
        }
    }

    private fun handleRoomControl(m: MeshMessage, roomId: String) {
        val control = RoomControl.decode(m.body) ?: return
        if (control.type != "manifest") return   // join and want are for admins
        val blob = control.blob ?: return
        val room = _rooms.value.firstOrNull { it.id == roomId } ?: return
        when (val r = Governor.accept(blob, room, identity, now())) {
            is Governor.Acceptance.Applied -> {
                update(roomId) { r.room }
                if (r.removed) problem("An admin removed this phone from ${room.displayName}.")
                if (r.admitted) {
                    if (roomId == _activeId.value) _problem.value = null
                    lastBackfill = 0
                    requestBackfill()
                }
                if (r.firstPin && roomId == _activeId.value) {
                    r.room.manifest?.let { problem("Room admin ${it.adminName}, fingerprint ${fingerprint(it.adminKey)}. Compare it with the admin's screen.") }
                }
                publish()
                sendJoinRequestIfNeeded(roomId)
            }
            is Governor.Acceptance.Rejected -> if (roomId == _activeId.value) {
                problem(if (r.why == "the room code does not match") "That code does not match room ${room.displayName}. Check the code and try again."
                        else "Ignored a room update for ${room.displayName}: ${r.why}.")
            }
            Governor.Acceptance.Stale -> {}
        }
    }

    private fun handleContent(m: MeshMessage, roomId: String, viaLink: String, backfilled: Boolean) {
        when (m.kind) {
            Kind.MODERATION -> receiveHide(m, roomId)
            Kind.ANSWER_PART -> {
                // Shown in place of the typing line until the whole answer arrives; never in the timeline.
                val ask = m.replyTo ?: return
                val seq = m.part ?: return
                if (backfilled || timelines[roomId]?.any { it.kind == Kind.ANSWER && it.replyTo == ask } == true) return
                if (streams.add(ask, seq, m.body, roomId, now())) publishPartials()
            }
            Kind.CHAT, Kind.ANSWER -> {
                if (m.silent == true) return
                if (m.kind == Kind.ANSWER) m.replyTo?.let { streams.finish(it, now()); publishPartials() }
                val mine = m.origin == meshName()
                val proof = m.proof?.let { p ->
                    listOfNotNull((p["mac"] as? JsonPrimitive)?.content?.let { "On-device: $it" }, (p["model"] as? JsonPrimitive)?.content,
                        (p["latencyMs"] as? JsonPrimitive)?.content?.let { "$it ms" }).joinToString(" · ")
                }
                addEntry(roomId, Entry(id = m.id, kind = m.kind, body = m.body, origin = m.origin, senderName = m.senderName,
                    createdAt = m.createdAt, receivedAt = now(), mine = mine && !backfilled, hops = m.hops, link = if (backfilled) null else viaLink,
                    replyTo = m.replyTo, rulesUsed = m.rulesUsed ?: emptyList(), unverifiedRules = m.unverifiedRules ?: emptyList(),
                    docRefs = m.docRefs?.map { DocChip(it.title, it.page, it.version, it.excerpt) } ?: emptyList(), noRule = m.noRule == true,
                    model = m.model ?: (m.proof?.get("model") as? JsonPrimitive)?.content, proofLine = proof, backfilled = backfilled))
                m.replyTo?.let { _waiting.value = _waiting.value - it }
                if (!backfilled) {
                    val rtt = m.replyTo?.takeIf { m.kind == Kind.ANSWER }?.let { askSentAt.remove(it) }?.let { now() - it }
                    timingLog(buildString {
                        append("MSG ${m.kind} link=${viaLink.lowercase()} hops=${maxOf(0, m.hops.size - 1)}")
                        rtt?.let { append(" rtt_ms=$it") }
                        m.latencyMs?.let { append(" ai_ms=$it") }
                    })
                }
            }
            Kind.MEDIA -> addEntry(roomId, Entry(id = m.id, kind = m.kind, body = "Photo or voice note. Open Libre on an iPhone or Mac to see it.",
                origin = m.origin, senderName = m.senderName, createdAt = m.createdAt, receivedAt = now(), mine = false, hops = m.hops, link = viaLink))
            Kind.TASK -> TaskItem.decode(m.body)?.let { t ->
                updateCache(roomId) { c -> c.copy(tasks = (c.tasks.filter { it.id != t.id } + t)) }
            }
            Kind.RULE -> RuleItem.decode(m.body)?.let { r ->
                updateCache(roomId) { c -> c.copy(rules = c.rules.filter { it.id != r.id } + r) }
            }
            Kind.SYNC -> {
                if (!backfilled) MeshCodec.parseObject(Bytes.utf8(m.body))?.let(PeerSync::parseRequest)?.let { servePeerSync(m.origin, roomId, it) }
                val p = SyncPayload.decode(m.body) ?: return
                updateCache(roomId) { c ->
                    c.copy(
                        tasks = p.taskIds?.let { ids -> c.tasks.filter { it.id in ids } } ?: c.tasks,
                        rules = p.ruleIds?.let { ids -> c.rules.filter { it.id in ids } } ?: c.rules,
                        library = p.library ?: c.library,
                    )
                }
                p.batch?.forEach { handleContent(it, roomId, viaLink, backfilled = true) }
            }
            else -> {}
        }
    }

    // MARK: State

    private fun addEntry(roomId: String, e: Entry) {
        if (moderation.isHidden(e.id)) return   // hidden for everyone in Town Square (issue #9)
        val list = timelines.getOrPut(roomId) { mutableListOf() }
        if (list.any { it.id == e.id }) return
        list.add(e)
        list.sortBy { it.createdAt }
        while (list.size > 500) list.removeAt(0)
        saveTimeline(roomId)
        publish()
    }

    private fun updateCache(roomId: String, f: (RoomCache) -> RoomCache) {
        caches[roomId] = f(caches[roomId] ?: RoomCache())
        save("cache-$roomId.json", RoomCache.serializer(), caches[roomId]!!)
        publish()
    }

    private fun publish() {
        val id = _activeId.value
        _entries.value = timelines[id]?.toList() ?: emptyList()
        _cache.value = caches[id] ?: RoomCache()
    }

    fun problem(text: String?) { _problem.value = text }
    fun entry(id: String): Entry? = timelines[_activeId.value]?.firstOrNull { it.id == id }

    companion object {
        fun fingerprint(key: ByteArray): String = app.libre.core.Crypto.sha256(key).take(6).joinToString("") { "%02X".format(it) }.chunked(4).joinToString("-")
    }

    // MARK: Files

    private fun saveRooms() = save("rooms.json", SavedRooms.serializer(), SavedRooms(_rooms.value, _activeId.value))
    private fun saveTimeline(id: String) = save("timeline-$id.json", ListSerializer(Entry.serializer()), timelines[id] ?: emptyList())

    private fun <T> save(name: String, s: kotlinx.serialization.KSerializer<T>, value: T) {
        try {
            val tmp = File(dir, "$name.tmp")
            tmp.writeText(json.encodeToString(s, value))
            tmp.renameTo(File(dir, name))
        } catch (e: Exception) { }
    }

    private fun <T> load(name: String, s: kotlinx.serialization.KSerializer<T>): T? = try {
        File(dir, name).takeIf { it.exists() }?.readText()?.let { json.decodeFromString(s, it) }
    } catch (e: Exception) { null }
}

/** One streamed answer on screen: the ask it answers and the text so far. */
data class PartialAnswer(val askId: String, val text: String)
