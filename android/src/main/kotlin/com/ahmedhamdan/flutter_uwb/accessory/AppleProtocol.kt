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
     * Build an `AccessoryConfigurationData` body advertising Android's
     * UWB controlee parameters.
     *
     * **TODO(verify):** the FiRa-encoded byte layout that
     * `NINearbyAccessoryConfiguration(data:)` accepts is not formally
     * documented by Apple; the empirical contract is in Apple's WWDC 2022
     * sample. Until validated against a real iPhone↔Android pairing the
     * bytes below are best-effort: a minimal 16-byte preamble carrying
     * sessionId (u32 LE), channel (u8), preambleIndex (u8), and the
     * controlee's 2-byte short address. Real Apple-spec accessories ship
     * vendor-specific TLV layouts; production-grade interop will likely
     * require capturing reference bytes from a working accessory firmware.
     */
    fun buildAccessoryConfigurationData(
        sessionId: Int,
        channel: Byte,
        preambleIndex: Byte,
        shortAddress: ByteArray,
    ): ByteArray {
        require(shortAddress.size >= 2) {
            "shortAddress must be at least 2 bytes, got ${shortAddress.size}"
        }
        val buf = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(sessionId)
        buf.put(channel)
        buf.put(preambleIndex)
        buf.put(shortAddress[0])
        buf.put(shortAddress[1])
        return buf.array()
    }

    /**
     * Inverse of [buildAccessoryConfigurationData]. Used when this codec
     * is reading bytes pulled from an upstream accessory.
     *
     * **TODO(verify):** see the encode-side note. This is a placeholder
     * layout pending hardware verification.
     */
    data class ParsedAccessoryConfig(
        val sessionId: Int,
        val channel: Byte,
        val preambleIndex: Byte,
        val shortAddress: ByteArray,
    )

    fun parseAccessoryConfigurationData(payload: ByteArray): ParsedAccessoryConfig {
        require(payload.size >= 8) {
            "AccessoryConfigurationData payload too short: ${payload.size}"
        }
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        val sessionId = buf.int
        val channel = buf.get()
        val preambleIndex = buf.get()
        val short = ByteArray(2).also {
            it[0] = buf.get()
            it[1] = buf.get()
        }
        return ParsedAccessoryConfig(sessionId, channel, preambleIndex, short)
    }
}
