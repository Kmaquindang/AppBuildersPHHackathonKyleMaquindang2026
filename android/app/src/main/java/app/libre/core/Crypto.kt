// Crypto.kt: the primitives Libre uses on iPhone and Mac (CryptoKit), built on Bouncy Castle's
// lightweight API so the same bytes come out on Android and in JVM tests:
// PBKDF2-HMAC-SHA256, HKDF-SHA256, HMAC-SHA256, SHA-256, ChaCha20-Poly1305 (nonce | ciphertext | tag),
// Ed25519 (CryptoKit Curve25519.Signing) and X25519 (Curve25519.KeyAgreement).
package app.libre.core

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.generators.PKCS5S2ParametersGenerator
import org.bouncycastle.crypto.macs.HMac
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.crypto.agreement.X25519Agreement
import java.security.SecureRandom

object Crypto {
    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun sha256(data: ByteArray): ByteArray {
        val d = SHA256Digest()
        d.update(data, 0, data.size)
        return ByteArray(32).also { d.doFinal(it, 0) }
    }

    fun hmacSha256(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = HMac(SHA256Digest())
        mac.init(KeyParameter(key))
        for (p in parts) mac.update(p, 0, p.size)
        return ByteArray(32).also { mac.doFinal(it, 0) }
    }

    fun pbkdf2(password: ByteArray, salt: ByteArray, rounds: Int, length: Int): ByteArray {
        val gen = PKCS5S2ParametersGenerator(SHA256Digest())
        gen.init(password, salt, rounds)
        return (gen.generateDerivedParameters(length * 8) as KeyParameter).key
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val gen = HKDFBytesGenerator(SHA256Digest())
        gen.init(HKDFParameters(ikm, salt, info))
        return ByteArray(length).also { gen.generateBytes(it, 0, length) }
    }

    /** ChaCha20-Poly1305 combined box: 12-byte nonce + ciphertext + 16-byte tag (CryptoKit `.combined`). */
    fun chachaSeal(plain: ByteArray, key: ByteArray, aad: ByteArray, nonce: ByteArray = randomBytes(12)): ByteArray {
        val c = ChaCha20Poly1305()
        c.init(true, AEADParameters(KeyParameter(key), 128, nonce, aad))
        val out = ByteArray(c.getOutputSize(plain.size))
        val n = c.processBytes(plain, 0, plain.size, out, 0)
        c.doFinal(out, n)
        return nonce + out
    }

    /** null when the box is short, tampered with, or the key or AAD is wrong. */
    fun chachaOpen(combined: ByteArray, key: ByteArray, aad: ByteArray): ByteArray? {
        if (combined.size < 12 + 16) return null
        return try {
            val c = ChaCha20Poly1305()
            c.init(false, AEADParameters(KeyParameter(key), 128, combined.copyOfRange(0, 12), aad))
            val body = combined.copyOfRange(12, combined.size)
            val out = ByteArray(c.getOutputSize(body.size))
            val n = c.processBytes(body, 0, body.size, out, 0)
            c.doFinal(out, n)
            out
        } catch (e: Exception) {
            null
        }
    }

    fun ed25519Public(secret: ByteArray): ByteArray = Ed25519PrivateKeyParameters(secret, 0).generatePublicKey().encoded

    fun ed25519Sign(secret: ByteArray, message: ByteArray): ByteArray {
        val s = Ed25519Signer()
        s.init(true, Ed25519PrivateKeyParameters(secret, 0))
        s.update(message, 0, message.size)
        return s.generateSignature()
    }

    fun ed25519Verify(publicKey: ByteArray, message: ByteArray, sig: ByteArray): Boolean {
        if (publicKey.size != 32 || sig.size != 64) return false
        return try {
            val v = Ed25519Signer()
            v.init(false, Ed25519PublicKeyParameters(publicKey, 0))
            v.update(message, 0, message.size)
            v.verifySignature(sig)
        } catch (e: Exception) {
            false
        }
    }

    fun x25519Public(secret: ByteArray): ByteArray = X25519PrivateKeyParameters(secret, 0).generatePublicKey().encoded

    fun x25519(secret: ByteArray, peerPublic: ByteArray): ByteArray? = try {
        val a = X25519Agreement()
        a.init(X25519PrivateKeyParameters(secret, 0))
        ByteArray(32).also { a.calculateAgreement(X25519PublicKeyParameters(peerPublic, 0), it, 0) }
    } catch (e: Exception) {
        null
    }
}
