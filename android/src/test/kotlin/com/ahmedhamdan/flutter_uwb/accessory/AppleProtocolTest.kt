package com.ahmedhamdan.flutter_uwb.accessory

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Kotlin twin of `test/apple_protocol_test.dart`. Pins the byte-level
 * spec-compliance contract on the Android side independent of the Dart
 * codec. Pure JVM — runs on any host.
 */
class AppleProtocolTest {

    @Test
    fun messageIdValuesMatchAppleSample() {
        assertEquals(0x01.toByte(), AppleProtocol.MessageId.AccessoryConfigurationData.value)
        assertEquals(0x02.toByte(), AppleProtocol.MessageId.AccessoryUwbDidStart.value)
        assertEquals(0x03.toByte(), AppleProtocol.MessageId.AccessoryUwbDidStop.value)
        assertEquals(0x0A.toByte(), AppleProtocol.MessageId.Initialize.value)
        assertEquals(0x0B.toByte(), AppleProtocol.MessageId.ConfigureAndStart.value)
        assertEquals(0x0C.toByte(), AppleProtocol.MessageId.Stop.value)
    }

    @Test
    fun fromByteResolvesAllKnownIds() {
        for (id in AppleProtocol.MessageId.values()) {
            assertEquals(id, AppleProtocol.MessageId.fromByte(id.value))
        }
    }

    @Test
    fun fromByteReturnsNullForUnknownIds() {
        for (b in listOf(0x00, 0x04, 0x09, 0x0D, 0x10, 0xFF)) {
            assertNull(
                AppleProtocol.MessageId.fromByte(b.toByte()),
                "id 0x${Integer.toHexString(b)} should be unknown",
            )
        }
    }

    @Test
    fun encodeIdOnlyProducesSingleByte() {
        assertContentEquals(
            byteArrayOf(0x0A),
            AppleProtocol.encodeIdOnly(AppleProtocol.MessageId.Initialize),
        )
        assertContentEquals(
            byteArrayOf(0x0C),
            AppleProtocol.encodeIdOnly(AppleProtocol.MessageId.Stop),
        )
        assertContentEquals(
            byteArrayOf(0x02),
            AppleProtocol.encodeIdOnly(AppleProtocol.MessageId.AccessoryUwbDidStart),
        )
    }

    @Test
    fun encodeWithPayloadPrependsId() {
        val payload = byteArrayOf(0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte())
        assertContentEquals(
            byteArrayOf(0x01, 0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte()),
            AppleProtocol.encodeWithPayload(
                AppleProtocol.MessageId.AccessoryConfigurationData,
                payload,
            ),
        )
    }

    @Test
    fun decodePayloadSlicesAfterByteZero() {
        val msg = byteArrayOf(0x0B, 0x11, 0x22, 0x33)
        assertContentEquals(byteArrayOf(0x11, 0x22, 0x33), AppleProtocol.decodePayload(msg))
    }

    @Test
    fun decodePayloadReturnsEmptyForIdOnly() {
        assertContentEquals(ByteArray(0), AppleProtocol.decodePayload(byteArrayOf(0x0A)))
    }

    @Test
    fun decodeIdReturnsNullForEmpty() {
        assertNull(AppleProtocol.decodeId(ByteArray(0)))
    }

    @Test
    fun roundTripAccessoryConfigurationData() {
        val data = AppleProtocol.buildAccessoryConfigurationData(
            sessionId = 0x12345678,
            channel = 9.toByte(),
            preambleIndex = 11.toByte(),
            shortAddress = byteArrayOf(0xAB.toByte(), 0xCD.toByte()),
        )
        val parsed = AppleProtocol.parseAccessoryConfigurationData(data)
        assertEquals(0x12345678, parsed.sessionId)
        assertEquals(9.toByte(), parsed.channel)
        assertEquals(11.toByte(), parsed.preambleIndex)
        assertContentEquals(byteArrayOf(0xAB.toByte(), 0xCD.toByte()), parsed.shortAddress)
    }
}
