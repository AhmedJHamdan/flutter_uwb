package com.ahmedhamdan.flutter_uwb.oob

import java.security.KeyPairGenerator
import java.security.PrivateKey
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import java.security.spec.NamedParameterSpec
import java.security.interfaces.XECPublicKey
import java.security.spec.XECPublicKeySpec
import java.security.KeyFactory
import java.math.BigInteger

/**
 * X25519 ECDH + HKDF-SHA256 used to authenticate the BLE OOB token
 * swap on Android↔Android peer pairing. Keys derived here drive the
 * `RangingParameters.sessionKeyInfo` (Provisioned STS) for the UWB
 * radio session that follows.
 *
 * Two derived keys per session:
 * - [SessionKeys.sessionKey] — 16 bytes; fed into Jetpack UWB.
 * - [SessionKeys.macKey] — 16 bytes; HMAC-SHA256 key used to
 *   authenticate the token bytes sent over GATT so an attacker on the
 *   same BLE channel cannot inject a token under a known device id.
 *
 * Requires API 31+ at runtime (`KeyPairGenerator.getInstance("XDH")`).
 * 0.4.0's effective floor is API 31 because we already require the
 * Android 12 runtime BLE permissions.
 */
object OobHandshake {

    /** Length of an X25519 public key in bytes (RFC 7748). */
    const val PUBLIC_KEY_LENGTH = 32

    /** Length of the HMAC-SHA256 tag we prepend to every token write. */
    const val MAC_TAG_LENGTH = 16

    /** Length of the UWB session key fed into Provisioned STS. */
    const val SESSION_KEY_LENGTH = 16

    /** Length of the HMAC key derived alongside the session key. */
    const val MAC_KEY_LENGTH = 16

    private const val HKDF_INFO_SESSION = "flutter_uwb v1 session key"
    private const val HKDF_INFO_MAC = "flutter_uwb v1 mac key"
    private const val HKDF_SALT = "flutter_uwb v1 hkdf salt"

    data class SessionKeys(
        val sessionKey: ByteArray,
        val macKey: ByteArray,
    ) {
        init {
            require(sessionKey.size == SESSION_KEY_LENGTH)
            require(macKey.size == MAC_KEY_LENGTH)
        }
    }

    data class LocalKeyPair(
        val privateKey: PrivateKey,
        val publicKey: ByteArray,
    ) {
        init { require(publicKey.size == PUBLIC_KEY_LENGTH) }
    }

    /**
     * Generate an ephemeral X25519 keypair. The private key never leaves
     * the device; the [LocalKeyPair.publicKey] is what we send over BLE.
     */
    fun generateKeyPair(): LocalKeyPair {
        val gen = KeyPairGenerator.getInstance("XDH")
        gen.initialize(NamedParameterSpec("X25519"))
        val pair = gen.generateKeyPair()
        val pub = (pair.public as XECPublicKey).u
        return LocalKeyPair(pair.private, encodeXdhPublic(pub))
    }

    /**
     * Derive the shared session and MAC keys from [localPrivate] and the
     * peer's 32-byte X25519 public key.
     */
    fun derive(localPrivate: PrivateKey, peerPublicBytes: ByteArray): SessionKeys {
        require(peerPublicBytes.size == PUBLIC_KEY_LENGTH) {
            "peer public key must be $PUBLIC_KEY_LENGTH bytes"
        }
        val peerPub = decodeXdhPublic(peerPublicBytes)
        val ka = KeyAgreement.getInstance("XDH")
        ka.init(localPrivate)
        ka.doPhase(peerPub, true)
        val shared = ka.generateSecret()
        val sessionKey = hkdfSha256(
            ikm = shared,
            salt = HKDF_SALT.toByteArray(),
            info = HKDF_INFO_SESSION.toByteArray(),
            length = SESSION_KEY_LENGTH,
        )
        val macKey = hkdfSha256(
            ikm = shared,
            salt = HKDF_SALT.toByteArray(),
            info = HKDF_INFO_MAC.toByteArray(),
            length = MAC_KEY_LENGTH,
        )
        return SessionKeys(sessionKey, macKey)
    }

    /**
     * Wrap [token] with an HMAC-SHA256 tag truncated to
     * [MAC_TAG_LENGTH] bytes. Wire layout: `[16-byte tag || token]`.
     */
    fun wrapToken(macKey: ByteArray, token: ByteArray): ByteArray {
        val tag = hmacSha256(macKey, token).copyOf(MAC_TAG_LENGTH)
        return tag + token
    }

    /**
     * Verify and strip the HMAC tag. Returns the original token bytes
     * on success or `null` if the MAC check fails.
     */
    fun unwrapToken(macKey: ByteArray, payload: ByteArray): ByteArray? {
        if (payload.size <= MAC_TAG_LENGTH) return null
        val tag = payload.copyOfRange(0, MAC_TAG_LENGTH)
        val token = payload.copyOfRange(MAC_TAG_LENGTH, payload.size)
        val expected = hmacSha256(macKey, token).copyOf(MAC_TAG_LENGTH)
        if (!constantTimeEquals(tag, expected)) return null
        return token
    }

    // --- internals ---

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun hkdfSha256(
        ikm: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        length: Int,
    ): ByteArray {
        val prk = hmacSha256(salt, ikm)
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val toCopy = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, toCopy)
            pos += toCopy
            counter++
        }
        return out
    }

    private fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].toInt() xor b[i].toInt())
        return diff == 0
    }

    /**
     * Encode an X25519 raw 32-byte public key from a `BigInteger u`
     * coordinate. RFC 7748 §5: little-endian, masked.
     */
    private fun encodeXdhPublic(u: BigInteger): ByteArray {
        val raw = u.toByteArray()
        val out = ByteArray(PUBLIC_KEY_LENGTH)
        // raw is big-endian; copy into the low bytes of `out` then reverse
        // to little-endian.
        val src = if (raw.size > PUBLIC_KEY_LENGTH) {
            // Drop a leading sign byte if any.
            raw.copyOfRange(raw.size - PUBLIC_KEY_LENGTH, raw.size)
        } else {
            ByteArray(PUBLIC_KEY_LENGTH - raw.size) + raw
        }
        for (i in 0 until PUBLIC_KEY_LENGTH) {
            out[i] = src[PUBLIC_KEY_LENGTH - 1 - i]
        }
        return out
    }

    private fun decodeXdhPublic(raw: ByteArray): java.security.PublicKey {
        // Reverse to big-endian for BigInteger.
        val be = ByteArray(PUBLIC_KEY_LENGTH)
        for (i in 0 until PUBLIC_KEY_LENGTH) {
            be[i] = raw[PUBLIC_KEY_LENGTH - 1 - i]
        }
        val u = BigInteger(1, be)
        val spec = XECPublicKeySpec(NamedParameterSpec("X25519"), u)
        return KeyFactory.getInstance("XDH").generatePublic(spec)
    }
}
