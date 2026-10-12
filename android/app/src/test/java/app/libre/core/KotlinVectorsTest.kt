// Writes (with -Dlibre.writeVectors=true) or checks kotlin_vectors.json: bytes made by Kotlin that
// the Swift suite (runAndroidInteropTests) verifies: a signed join request with a code proof, a
// Town Square packet sealed in Kotlin, an @libre ask sealed with the epoch key, and BLE frames.
// Kotlin output is deterministic (Ed25519 signatures are deterministic, nonces fixed here).
package app.libre.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class KotlinVectorsTest {
    private fun build(): JsonObject {
        val v = Vectors
        val room = RoomState(label = "BOHOL-7", keyHex = v.s("codeBaseKey"), keySource = "code", pending = true, codeKeyHex = v.s("codeKey"))
        val join = Governor.joinRequest(room, v.joiner, "Pixel-A1", "Ben", Vectors.T0)
        val town = RoomState.townSquare()
        val chat = MeshMessage(id = "7A7A7A7A-1111-4222-8333-444444444444", origin = "Pixel-A1", kind = Kind.CHAT,
            body = "Hello from Android, PATIENT_A placeholder", createdAt = Vectors.T0, senderName = "Ben", v = 2)
        val sealed = RoomEnvelope.seal(chat, town.id, town.key, 0, ByteArray(12) { it.toByte() })
        val ask = MeshMessage(id = "7B7B7B7B-1111-4222-8333-444444444444", origin = "Pixel-A1", destination = Destination.Role("ai"),
            kind = Kind.ASK, body = "what is the site rule", createdAt = Vectors.T0, senderName = "Ben", v = 2)
        val epochKey = Bytes.unhex(v.s("epochKey"))
        val epochAsk = RoomEnvelope.seal(ask, room.id, epochKey, v.v["manifestEpoch"].toString().toInt(), ByteArray(12) { (it + 1).toByte() })
        val data = ByteArray(700) { (it * 13 + 3).toByte() }
        val frames = BleChunker.frames(data, 0x01020304, 185)!!
        val joinerHello = BleHello.make(v.joiner, "Pixel-A1", v.h("joinerNonce"))!!
        val macHello = BleHello.open(v.h("signedHello"))!!
        return JsonObject(sortedMapOf(
            "joinRequestBlob" to JsonPrimitive(join.toJson().toString()),
            "townSealedJSON" to JsonPrimitive(String(MeshCodec.encode(sealed))),
            "epochAskJSON" to JsonPrimitive(String(MeshCodec.encode(epochAsk))),
            "epochKeyUsed" to JsonPrimitive(v.s("epochKey")),
            "frames" to JsonArray(frames.map { JsonPrimitive(Bytes.hex(it)) }),
            "framesData" to JsonPrimitive(Bytes.hex(data)),
            "signedHello" to JsonPrimitive(Bytes.hex(joinerHello)),
            "proofForAdmin" to JsonPrimitive(Bytes.hex(BleHello.proof(v.joiner, macHello))),
            "adminNonce" to JsonPrimitive(v.s("helloNonce")),
        ))
    }

    @Test fun kotlinVectorsUpToDate() {
        val out = build().toString()
        val file = File("src/test/resources/kotlin_vectors.json")
        if (System.getProperty("libre.writeVectors") == "true" || !file.exists()) file.writeText(out)
        assertEquals("kotlin_vectors.json is stale: rerun with -Plibre.writeVectors", out, file.readText())
    }
}
