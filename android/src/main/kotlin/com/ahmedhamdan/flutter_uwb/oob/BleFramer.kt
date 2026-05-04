package com.ahmedhamdan.flutter_uwb.oob

/**
 * 1-byte-header chunked framing used to split GATT writes/notifications
 * larger than the negotiated ATT payload window into multiple operations.
 *
 * Wire layout per fragment:
 *
 *     byte[0]    bit7 = isLast, bits6..0 = sequence number (0..127)
 *     byte[1..]  payload chunk
 *
 * A single-fragment message is encoded as `[0x80 | data...]`.
 *
 * The default GATT MTU is 23 bytes (20 byte ATT payload window). Once
 * `BluetoothGatt.requestMtu(247)` succeeds, we get a 244-byte window
 * and most messages fit in one fragment; the framer is used regardless
 * so the wire format does not change with the MTU.
 */
object BleFramer {

    /**
     * Split [payload] into fragments sized for the given ATT [mtu].
     *
     * Each fragment is at most `mtu - 3` bytes (the 3-byte ATT header)
     * minus one byte for the fragment header. An empty payload encodes
     * to a single `[0x80]` fragment so the receiver still observes the
     * end-of-message marker.
     */
    fun fragments(payload: ByteArray, mtu: Int): List<ByteArray> {
        val capacity = (mtu - 3 - 1).coerceAtLeast(1)
        val out = mutableListOf<ByteArray>()
        if (payload.isEmpty()) {
            out.add(byteArrayOf(0x80.toByte()))
            return out
        }
        var pos = 0
        var seq = 0
        while (pos < payload.size) {
            val end = minOf(pos + capacity, payload.size)
            val isLast = end == payload.size
            val header = ((seq and 0x7F) or (if (isLast) 0x80 else 0)).toByte()
            val chunk = ByteArray(1 + (end - pos))
            chunk[0] = header
            System.arraycopy(payload, pos, chunk, 1, end - pos)
            out.add(chunk)
            pos = end
            seq++
            check(seq <= 0x80) {
                "BleFramer: payload too large for chunked framing (seq=$seq)"
            }
        }
        return out
    }

    /**
     * Per-connection reassembler. Feed fragments in arrival order; the
     * fully assembled payload is returned on the last fragment, or
     * `null` while more fragments remain.
     *
     * Out-of-order or duplicate fragments reset the buffer and return
     * `null` so callers can surface a transport error.
     */
    class Reassembler {
        private val buf = ArrayList<Byte>()
        private var nextSeq = 0

        fun feed(fragment: ByteArray): ByteArray? {
            if (fragment.isEmpty()) return null
            val header = fragment[0].toInt() and 0xFF
            val seq = header and 0x7F
            val isLast = (header and 0x80) != 0
            if (seq != nextSeq) {
                reset()
                return null
            }
            for (i in 1 until fragment.size) buf.add(fragment[i])
            nextSeq++
            if (!isLast) return null
            val out = ByteArray(buf.size)
            for (i in buf.indices) out[i] = buf[i]
            reset()
            return out
        }

        fun reset() {
            buf.clear()
            nextSeq = 0
        }
    }
}
