package com.ahmedhamdan.flutter_uwb.oob

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BleFramerTest {

    @Test
    fun singleFragmentMessageFitsInsideTheMtuWindow() {
        val payload = ByteArray(20) { it.toByte() }
        val frags = BleFramer.fragments(payload, mtu = 247)
        assertEquals(1, frags.size)
        assertTrue((frags[0][0].toInt() and 0x80) != 0, "single fragment must be marked last")
    }

    @Test
    fun emptyPayloadStillEmitsAFinalFragment() {
        val frags = BleFramer.fragments(ByteArray(0), mtu = 23)
        assertEquals(1, frags.size)
        assertEquals(0x80.toByte(), frags[0][0])
        assertEquals(1, frags[0].size)
    }

    @Test
    fun chunksOversizedPayloadAtMtuBoundaries() {
        // MTU 23 → 20 ATT bytes → 19 payload-bytes per fragment.
        val payload = ByteArray(50) { (it + 1).toByte() }
        val frags = BleFramer.fragments(payload, mtu = 23)
        assertEquals(3, frags.size)
        for ((i, f) in frags.withIndex()) {
            val header = f[0].toInt() and 0xFF
            val isLast = (header and 0x80) != 0
            val seq = header and 0x7F
            assertEquals(i, seq, "fragments must be sequential")
            assertEquals(i == frags.size - 1, isLast)
        }
    }

    @Test
    fun reassemblerRoundTripsFragmentationForSeveralMtus() {
        val payload = ByteArray(200) { (it * 7).toByte() }
        for (mtu in listOf(23, 50, 100, 247)) {
            val frags = BleFramer.fragments(payload, mtu)
            val r = BleFramer.Reassembler()
            var out: ByteArray? = null
            for (f in frags) out = r.feed(f)
            assertNotNull(out, "MTU $mtu must reassemble")
            assertTrue(out.contentEquals(payload), "MTU $mtu must round-trip")
        }
    }

    @Test
    fun reassemblerResetsOnOutOfSequenceFragment() {
        val r = BleFramer.Reassembler()
        // Skip seq=0 and feed seq=1 directly; reassembler should reject.
        assertNull(r.feed(byteArrayOf(0x01, 0x99.toByte())))
    }
}
