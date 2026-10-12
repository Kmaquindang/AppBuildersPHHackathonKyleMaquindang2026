// Cross-language vectors: swift_vectors.json is written by the Swift core
// (`swift run PasaCoreTests --vectors android/app/src/test/resources/swift_vectors.json`).
// Every assertion here checks Kotlin makes or accepts the same bytes.
package app.libre.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

object Vectors {
    val v: JsonObject by lazy {
        val text = javaClass.classLoader!!.getResource("swift_vectors.json")!!.readText()
        MeshCodec.json.parseToJsonElement(text) as JsonObject
    }
    fun s(k: String) = (v[k] as JsonPrimitive).content
    fun h(k: String) = Bytes.unhex(s(k))
    const val ROOM = "Bohol 7"
    const val CODE = "K7QM-3XRF"
    const val T0 = 1_792_000_000_123L
    val joiner by lazy { DeviceIdentity(h("joinerSignSecret"), h("joinerBoxSecret")) }
}

class SwiftVectorsTest {
    private val v = Vectors

    @Test fun namesNormalizeLikeSwift() {
        val cl = v.v["cleanLabel"] as JsonObject
        for ((input, out) in cl) assertEquals("cleanLabel($input)", out.jsonPrimitive.content, RoomNames.cleanLabel(input))
        assertEquals(v.s("normalizedName"), RoomNames.normalizedName(Vectors.ROOM))
        assertEquals(v.s("codeNormalized"), JoinCode.normalize("k7qm 3xrf"))
    }

    @Test fun pbkdf2MatchesSwift() {
        assertEquals(v.s("pbkdf2_rfc"), Bytes.hex(Crypto.pbkdf2(Bytes.utf8("passwd"), Bytes.utf8("salt"), 1, 64)))
        assertEquals(v.s("pbkdf2_4096"), Bytes.hex(Crypto.pbkdf2(Bytes.utf8("password"), Bytes.utf8("salt"), 4096, 32)))
    }

    @Test fun passcodeKeyFullRoundsMatchesSwift() {
        assertEquals(v.s("passcodeKey"), Bytes.hex(RoomKeys.passcodeKey(Vectors.ROOM, " tide lamp 42 ")))
    }

    @Test fun codeKeyFullRoundsMatchesSwift() {
        assertEquals(v.s("codeKey"), Bytes.hex(CodeRoom.codeKey(Vectors.ROOM, "k7qm 3xrf")!!))
    }

    @Test fun roomKeysAndTagsMatchSwift() {
        assertEquals(v.s("defaultKey"), Bytes.hex(RoomKeys.defaultKey))
        assertEquals(v.s("defaultTag"), RoomKeys.tag(RoomKeys.defaultKey))
        assertEquals(v.s("codeBaseKey"), Bytes.hex(CodeRoom.baseKey(Vectors.ROOM)))
        assertEquals(v.s("codeRoomTag"), RoomKeys.tag(CodeRoom.baseKey(Vectors.ROOM)))
        assertEquals(v.s("sealingKeyDefault"), Bytes.hex(RoomKeys.sealingKey(RoomKeys.defaultKey)))
    }

    @Test fun chachaFixedNonceMatchesSwift() {
        val f = v.v["fixedSeal"] as JsonObject
        fun x(k: String) = Bytes.unhex(f[k]!!.jsonPrimitive.content)
        val combined = RoomKeys.seal(x("plain"), x("key"), x("aad"), x("nonce"))
        assertEquals(f["combined"]!!.jsonPrimitive.content, Bytes.hex(combined))
        assertArrayEquals(x("plain"), RoomKeys.open(x("combined"), x("key"), x("aad")))
        val bad = x("combined").also { it[20] = (it[20].toInt() xor 1).toByte() }
        assertNull(RoomKeys.open(bad, x("key"), x("aad")))
        assertNull(RoomKeys.open(x("combined"), x("key"), Bytes.utf8("other aad")))
    }

    @Test fun messageJsonDecodesAndRoundTrips() {
        val chat = MeshCodec.decode(Bytes.utf8(v.s("chatJSON")))!!
        assertEquals("6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", chat.id)
        assertEquals(Vectors.T0, chat.createdAt)
        assertEquals("Ana", chat.senderName)
        assertNull(chat.destination)
        val ask = MeshCodec.decode(Bytes.utf8(v.s("askJSON")))!!
        assertEquals(Destination.Role("ai"), ask.destination)
        val answer = MeshCodec.decode(Bytes.utf8(v.s("answerJSON")))!!
        assertEquals(Destination.Peer("Pixel-A1"), answer.destination)
        assertEquals(listOf("[Rule: Hard hats v2]"), answer.rulesUsed)
        assertEquals("Site safety, p.2, v1", answer.docRefs!!.single().chipLabel)
        assertEquals("qwen3:8b", answer.proof!!["model"]!!.jsonPrimitive.content)
        assertEquals(ask.id, answer.replyTo)
        // Kotlin's encoding of the same message is the same JSON object (key order aside).
        for (k in listOf("chatJSON", "askJSON", "answerJSON")) {
            val swift = MeshCodec.parseObject(Bytes.utf8(v.s(k)))!!
            val kotlin = MeshCodec.toJson(MeshCodec.fromJson(swift)!!)
            assertEquals(k, swift, kotlin)
        }
    }

    @Test fun swiftSealedTownSquarePacketOpens() {
        val outer = MeshCodec.decode(Bytes.utf8(v.s("townSealedJSON")))!!
        assertEquals(v.s("townAAD"), String(RoomEnvelope.aad(outer, outer.room!!)))
        val town = RoomState.townSquare()
        assertEquals(town.id, outer.room)
        val inner = RoomEnvelope.open(outer, town.id, town.key)!!
        assertEquals("Wi-Fi off test from PATIENT_A placeholder", inner.body)
        assertEquals("Ana", inner.senderName)
        assertNull(RoomEnvelope.open(outer.copy(origin = "someone else"), town.id, town.key))
    }

    @Test fun kotlinSealMatchesSwiftLayout() {
        val outer = MeshCodec.decode(Bytes.utf8(v.s("townSealedJSON")))!!
        val town = RoomState.townSquare()
        val inner = RoomEnvelope.open(outer, town.id, town.key)!!
        val box = Bytes.unb64url(outer.sealed!!)!!
        val again = RoomEnvelope.seal(inner.copy(hops = outer.hops), town.id, town.key, 0, box.copyOfRange(0, 12))
        // Same header and the same box, so the inner JSON Kotlin writes opens to the same message.
        assertEquals(outer.copy(sealed = null), again.copy(sealed = null))
        assertEquals(inner, RoomEnvelope.open(again, town.id, town.key))
    }

    @Test fun framesMatchSwift() {
        for (e in v.v["frames"] as JsonArray) {
            val o = e as JsonObject
            val data = Bytes.unhex(o["data"]!!.jsonPrimitive.content)
            val got = BleChunker.frames(data, o["id"]!!.jsonPrimitive.long, o["mtu"]!!.jsonPrimitive.int)!!.map(Bytes::hex)
            val want = (o["frames"] as JsonArray).map { it.jsonPrimitive.content }
            assertEquals(want, got)
            val r = BleReassembler()
            var out: ByteArray? = null
            for (f in want.reversed()) r.add(Bytes.unhex(f), "ios")?.let { out = it.data }
            assertArrayEquals(data, out)
        }
        assertEquals(v.s("hello"), Bytes.hex(BleFrame(FrameType.HELLO, 0, 0, 1, Bytes.utf8("iPhone 14")).encoded()))
    }

    @Test fun joinRequestProofAndKeysMatchSwift() {
        val j = Vectors.joiner
        assertEquals(v.s("joinerSignKey"), Bytes.hex(j.signKey))
        assertEquals(v.s("joinerBoxKey"), Bytes.hex(j.boxKey))
        val ck = Bytes.unhex(v.s("codeKey"))
        val room = RoomState(label = "BOHOL-7", keyHex = v.s("codeBaseKey"), keySource = "code", pending = true, codeKeyHex = v.s("codeKey"))
        assertEquals(v.s("joinProof"), Bytes.hex(CodeRoom.proof(ck, room.id, j.signKey)))
        val swiftBlob = SignedBlob.fromJson(MeshCodec.parseObject(Bytes.utf8(v.s("joinRequestBlob"))))!!
        assertTrue("Swift Ed25519 signature verifies in Kotlin", swiftBlob.isValid)
        val mine = Governor.joinRequest(room, j, "Pixel-A1", "Ben", Vectors.T0)
        assertEquals(swiftBlob.bodyJson(), mine.bodyJson())
        assertArrayEquals(swiftBlob.signer, mine.signer)
        assertTrue(mine.isValid)
    }

    @Test fun swiftManifestAcceptedKeyBoxOpensAndEpochChatOpens() {
        val j = Vectors.joiner
        var room = RoomState(label = "BOHOL-7", keyHex = v.s("codeBaseKey"), keySource = "code", pending = true, codeKeyHex = v.s("codeKey"))
        assertNull("no content key while waiting", room.contentKey)
        // The manifest arrives inside a roomControl packet sealed with the base key.
        val packet = MeshCodec.decode(Bytes.utf8(v.s("manifestPacketJSON")))!!
        val inner = RoomEnvelope.open(packet, room.id, room.key)!!
        assertEquals(Kind.ROOM_CONTROL, inner.kind)
        val control = RoomControl.decode(inner.body)!!
        assertEquals("manifest", control.type)
        val result = Governor.accept(control.blob!!, room, j) as Governor.Acceptance.Applied
        assertTrue(result.admitted && result.firstPin)
        room = result.room
        assertEquals(v.s("adminKey"), room.adminKeyHex)
        assertEquals(v.v["manifestEpoch"]!!.jsonPrimitive.int, room.epoch)
        assertEquals(v.s("epochKey"), Bytes.hex(room.contentKey!!))
        assertEquals(Governor.Acceptance.Stale, Governor.accept(control.blob!!, room, j))
        val chat = MeshCodec.decode(Bytes.utf8(v.s("epochSealedJSON")))!!
        val opened = RoomEnvelope.open(chat, room.id, room.openKey(chat.epoch ?: 0)!!)!!
        assertEquals("Welcome, Ben", opened.body)
        assertEquals("Kyle", opened.senderName)
        assertNull("base key does not open epoch content", RoomEnvelope.open(chat, room.id, room.key))
    }

    @Test fun wrongCodeRejectsTheManifest() {
        val j = Vectors.joiner
        val wrong = CodeRoom.codeKey(Vectors.ROOM, "2222-2222", rounds = 1)!!
        val room = RoomState(label = "BOHOL-7", keyHex = v.s("codeBaseKey"), keySource = "code", pending = true, codeKeyHex = Bytes.hex(wrong))
        val blob = SignedBlob.fromJson(MeshCodec.parseObject(Bytes.utf8(v.s("manifestBlob"))))!!
        assertEquals(Governor.Acceptance.Rejected("the room code does not match"), Governor.accept(blob, room, j))
        val tampered = blob.copy(body = blob.body.copyOf().also { it[10] = (it[10].toInt() xor 1).toByte() })
        assertEquals(Governor.Acceptance.Rejected("bad signature"), Governor.accept(tampered, room, j))
    }

    @Test fun orgPayloadsDecode() {
        val task = TaskItem.decode(v.s("taskJSON"))!!
        assertEquals("Order cement (Ben, due Friday)", task.shortLine)
        val sync = SyncPayload.decode(v.s("syncManifestJSON"))!!
        assertEquals("Site safety", sync.library!!.single().title)
        assertEquals(listOf(task.id), sync.taskIds)
        val rule = RuleItem.decode(v.s("ruleJSON"))!!
        assertEquals("[Rule: Hard hats v2]", rule.citation)
    }
}
