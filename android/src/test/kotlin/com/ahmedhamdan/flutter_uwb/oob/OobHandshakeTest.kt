package com.ahmedhamdan.flutter_uwb.oob

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OobHandshakeTest {

    @Test
    fun bothPartiesDeriveTheSameSessionAndMacKeys() {
        val alice = OobHandshake.generateKeyPair()
        val bob = OobHandshake.generateKeyPair()

        val aliceKeys = OobHandshake.derive(alice.privateKey, bob.publicKey)
        val bobKeys = OobHandshake.derive(bob.privateKey, alice.publicKey)

        assertEquals(OobHandshake.SESSION_KEY_LENGTH, aliceKeys.sessionKey.size)
        assertEquals(OobHandshake.MAC_KEY_LENGTH, aliceKeys.macKey.size)
        assertTrue(
            aliceKeys.sessionKey.contentEquals(bobKeys.sessionKey),
            "session keys must match across parties",
        )
        assertTrue(
            aliceKeys.macKey.contentEquals(bobKeys.macKey),
            "mac keys must match across parties",
        )
    }

    @Test
    fun sessionAndMacKeysAreDistinct() {
        val pair = OobHandshake.generateKeyPair()
        val peer = OobHandshake.generateKeyPair()
        val keys = OobHandshake.derive(pair.privateKey, peer.publicKey)
        assertTrue(
            !keys.sessionKey.contentEquals(keys.macKey),
            "HKDF must produce independent session and mac keys",
        )
    }

    @Test
    fun wrappedTokenRoundTripsThroughTheSameMacKey() {
        val pair = OobHandshake.generateKeyPair()
        val peer = OobHandshake.generateKeyPair()
        val keys = OobHandshake.derive(pair.privateKey, peer.publicKey)
        val token = "the quick brown fox".toByteArray()
        val wrapped = OobHandshake.wrapToken(keys.macKey, token)
        assertEquals(OobHandshake.MAC_TAG_LENGTH + token.size, wrapped.size)
        val unwrapped = OobHandshake.unwrapToken(keys.macKey, wrapped)
        assertNotNull(unwrapped)
        assertTrue(unwrapped.contentEquals(token))
    }

    @Test
    fun unwrapRejectsTokenWrappedUnderADifferentMacKey() {
        val a = OobHandshake.generateKeyPair()
        val b = OobHandshake.generateKeyPair()
        val c = OobHandshake.generateKeyPair()
        val abKeys = OobHandshake.derive(a.privateKey, b.publicKey)
        val acKeys = OobHandshake.derive(a.privateKey, c.publicKey)
        val token = byteArrayOf(0x01, 0x02, 0x03, 0x04, 0x05)
        val wrapped = OobHandshake.wrapToken(abKeys.macKey, token)
        // C's keys should not validate a tag computed with B's keys.
        assertNull(OobHandshake.unwrapToken(acKeys.macKey, wrapped))
    }

    @Test
    fun unwrapRejectsTamperedPayload() {
        val pair = OobHandshake.generateKeyPair()
        val peer = OobHandshake.generateKeyPair()
        val keys = OobHandshake.derive(pair.privateKey, peer.publicKey)
        val wrapped = OobHandshake.wrapToken(keys.macKey, byteArrayOf(0x01, 0x02))
        wrapped[wrapped.size - 1] = (wrapped.last().toInt() xor 0x01).toByte()
        assertNull(OobHandshake.unwrapToken(keys.macKey, wrapped))
    }

    @Test
    fun unwrapRejectsTooShortPayload() {
        val pair = OobHandshake.generateKeyPair()
        val peer = OobHandshake.generateKeyPair()
        val keys = OobHandshake.derive(pair.privateKey, peer.publicKey)
        assertNull(OobHandshake.unwrapToken(keys.macKey, ByteArray(0)))
        assertNull(OobHandshake.unwrapToken(keys.macKey, ByteArray(8)))
    }
}
