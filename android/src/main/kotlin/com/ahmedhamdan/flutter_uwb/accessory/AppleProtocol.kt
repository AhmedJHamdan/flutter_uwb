package com.ahmedhamdan.flutter_uwb.accessory

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Kotlin mirror of `lib/src/accessory/apple_protocol.dart`.
 *
 * The Dart codec is the spec contract; this Kotlin twin exists so the
 * Android-side strategies can dispatch on byte 0 without paying a Pigeon
 * round-trip per BLE notification.
 *
 * Wire format
 * - Every message is `[messageId: u8] [payload: bytes...]`.
 * - Empty-payload messages are exactly 1 byte.
 * - `AccessoryConfigurationData` and `ConfigureAndStart` carry opaque
 *   variable-length payloads; this codec does not interpret them at the
 *   FiRa level — that's the controlee strategy's job.
 *
 * Message id values come from Apple's WWDC 2022 `NIAccessory.swift`
 * sample. Verify against Apple's published reference if upstream changes.
 */
object AppleProtocol {

    enum class MessageId(val value: Byte) {
        AccessoryConfigurationData(0x01),
        AccessoryUwbDidStart(0x02),
        AccessoryUwbDidStop(0x03),
        Initialize(0x0A),
        ConfigureAndStart(0x0B),
        Stop(0x0C);

        companion object {
            fun fromByte(byte: Byte): MessageId? =
                values().firstOrNull { it.value == byte }
        }
    }

    /** Encode an empty-body message (id only). */
    fun encodeIdOnly(id: MessageId): ByteArray = byteArrayOf(id.value)

    /** Encode a payload-bearing message (`[id, ...payload]`). */
    fun encodeWithPayload(id: MessageId, payload: ByteArray): ByteArray {
        val out = ByteArray(1 + payload.size)
        out[0] = id.value
        System.arraycopy(payload, 0, out, 1, payload.size)
        return out
    }

    /** Decode just the message id off the wire (or `null` if unknown). */
    fun decodeId(bytes: ByteArray): MessageId? =
        if (bytes.isEmpty()) null else MessageId.fromByte(bytes[0])

    /** Slice the payload portion of a message. */
    fun decodePayload(bytes: ByteArray): ByteArray =
        if (bytes.size <= 1) ByteArray(0) else bytes.copyOfRange(1, bytes.size)

    /**
     * Build an `AccessoryConfigurationData` body per Apple's
     * "Nearby Interaction Accessory Protocol Specification R2", Section 3.4.
     *
     * Wire format (37 bytes total, excluding the 0x01 message-id byte the
     * caller prepends via [encodeWithPayload]):
     *
     * ```
     * Offset  Size  Field                Value
     * 0..1    u16   MajorVersion (LE)    1
     * 2..3    u16   MinorVersion (LE)    0
     * 4       u8    PreferredUpdateRate  20  (User Interactive)
     * 5..14   10B   RFU                  zeros
     * 15      u8    UWBConfigDataLength  21
     * 16..36  21B   UWBConfigData        FiRa middleware blob (see below)
     * ```
     *
     * The inner 21-byte `UWBConfigData` is intentionally opaque per the spec
     * ("provided by the UWB middleware to the embedded application"). Apple
     * defers its definition to the FiRa Consortium UCI layer. The template
     * below is a working frame captured from a real Apple-FiRa accessory
     * (DWM3001 + Qorvo NI middleware) and shared on the Qorvo Tech Forum
     * (`forum.qorvo.com/t/apple-ni-configuration-data-frame/10796`). Bytes
     * 17-18 within `UWBConfigData` (= 33-34 of the full payload) carry the
     * controlee's 2-byte short address; the rest is treated as a constant
     * capability advertisement. The iPhone replies in `ConfigureAndStart`
     * (0x0B) with an `AppleUWBConfigData` blob that overrides our
     * advertised params, so the constant template is sufficient to clear
     * `NINearbyAccessoryConfiguration(data:)` and proceed to the
     * Apple-shareable-config exchange.
     */
    fun buildAccessoryConfigurationData(
        @Suppress("UNUSED_PARAMETER") sessionId: Int,
        @Suppress("UNUSED_PARAMETER") channel: Byte,
        @Suppress("UNUSED_PARAMETER") preambleIndex: Byte,
        shortAddress: ByteArray,
    ): ByteArray {
        require(shortAddress.size >= 2) {
            "shortAddress must be at least 2 bytes, got ${shortAddress.size}"
        }
        val out = ByteArray(37)

        // 16-byte spec wrapper.
        out[0] = 0x01; out[1] = 0x00            // MajorVersion = 1 (u16 LE)
        out[2] = 0x00; out[3] = 0x00            // MinorVersion = 0 (u16 LE)
        out[4] = 0x14                           // PreferredUpdateRate = 20
        // bytes 5..14 left as zero (RFU)
        out[15] = 0x15                          // UWBConfigDataLength = 21

        // 21-byte UWBConfigData FiRa blob (constant template + short addr).
        val uwb = byteArrayOf(
            0x01, 0x00, 0x01, 0x00, 0x3F.toByte(), 0xF5.toByte(), 0x03, 0x00,
            0xB8.toByte(), 0x0B, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01,
            0x01, 0x00 /* short addr lo */, 0x00 /* short addr hi */, 0x19, 0x00,
        )
        // Splice short address at UWBConfigData offsets 17-18.
        uwb[17] = shortAddress[0]
        uwb[18] = shortAddress[1]
        System.arraycopy(uwb, 0, out, 16, 21)

        return out
    }

    /**
     * Parsed view of the 30-byte `AppleUWBConfigData` blob the iPhone
     * sends inside `ConfigureAndStart` (message id 0x0B).
     *
     * Field offsets follow NXP's `shareable_data_t` reference struct
     * (`nxp-uwb/sr250-uwbiot-zephyr` /
     * `uwbiot-top/demos/SR2XX/demo_nearby_interaction/inc/TLV_Types_i.h`)
     * and the byte-by-byte annotation in maa-x's ESP32-DW3000 community
     * port. See `docs/agents/research/2026-05-03-apple-uwb-config-data-decoded.md`
     * for the full layout, evidence, and source citations.
     */
    data class ParsedAppleUwbConfig(
        /** FiRa session id, u32 LE from offsets 7..10. */
        val sessionId: Int,
        /** FiRa channel number, byte 12 (= 9 in all observed captures). */
        val channel: Int,
        /**
         * FiRa preamble code index, byte 11. Apple selects from the BPRF
         * set {9, 10, 11, 12} per session.
         */
        val preambleIndex: Int,
        /**
         * 6-byte Static-STS initialisation vector, bytes 20..25.
         * Jetpack's `CONFIG_UNICAST_DS_TWR` expects an 8-byte
         * `sessionKeyInfo` formed as `vendorId(2B) || stsIv(6B)` — this
         * field carries only the IV; the strategy layer prepends the
         * vendor id.
         */
        val stsIv: ByteArray,
        /**
         * iPhone-controller short address, bytes 26..27 (LE u16),
         * presented MSB-first for `androidx.core.uwb.UwbAddress`.
         */
        val peerShortAddress: ByteArray,
        /** Verbatim 30-byte payload, kept for diagnostics and logging. */
        val raw: ByteArray,
    )

    /**
     * Decode the `AppleUWBConfigData` payload into the fields that
     * `androidx.core.uwb.RangingParameters` needs. Throws
     * [IllegalArgumentException] on payloads shorter than 30 bytes.
     * Trailing bytes beyond offset 29 are ignored (forward-compat).
     */
    fun parseAppleUWBConfigData(payload: ByteArray): ParsedAppleUwbConfig {
        require(payload.size >= 30) {
            "AppleUWBConfigData payload too short: ${payload.size} bytes (need ≥30)"
        }
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        val sessionId = buf.getInt(7)
        val preambleIndex = payload[11].toInt() and 0xFF
        val channel = payload[12].toInt() and 0xFF
        val stsIv = payload.copyOfRange(20, 26)
        // dest_address is u16 LE on the wire. UwbAddress takes the bytes
        // in MSB-first order, so swap.
        val peerShortAddress = byteArrayOf(payload[27], payload[26])
        return ParsedAppleUwbConfig(
            sessionId = sessionId,
            channel = channel,
            preambleIndex = preambleIndex,
            stsIv = stsIv,
            peerShortAddress = peerShortAddress,
            raw = payload.copyOfRange(0, 30),
        )
    }
}
