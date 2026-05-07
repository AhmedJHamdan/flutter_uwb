package com.ahmedhamdan.flutter_uwb.accessory

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
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
    fun goldenFixtureInitializeDecodes() {
        val bytes = readFixture("initialize.bin")
        assertEquals(AppleProtocol.MessageId.Initialize, AppleProtocol.decodeId(bytes))
    }

    @Test
    fun goldenFixtureStopDecodes() {
        val bytes = readFixture("stop.bin")
        assertEquals(AppleProtocol.MessageId.Stop, AppleProtocol.decodeId(bytes))
    }

    @Test
    fun goldenFixtureAccessoryUwbDidStartDecodes() {
        val bytes = readFixture("accessory_uwb_did_start.bin")
        assertEquals(
            AppleProtocol.MessageId.AccessoryUwbDidStart,
            AppleProtocol.decodeId(bytes),
        )
    }

    @Test
    fun goldenFixtureSyntheticAccessoryConfigurationDataRoundTrips() {
        val bytes = readFixture("accessory_configuration_data_synthetic.bin")
        assertEquals(
            AppleProtocol.MessageId.AccessoryConfigurationData,
            AppleProtocol.decodeId(bytes),
        )
        val payload = AppleProtocol.decodePayload(bytes)
        val reEncoded = AppleProtocol.encodeWithPayload(
            AppleProtocol.MessageId.AccessoryConfigurationData,
            payload,
        )
        assertContentEquals(bytes, reEncoded)
    }

    @Test
    fun goldenFixtureSyntheticConfigureAndStartRoundTrips() {
        val bytes = readFixture("configure_and_start_synthetic.bin")
        assertEquals(
            AppleProtocol.MessageId.ConfigureAndStart,
            AppleProtocol.decodeId(bytes),
        )
        val payload = AppleProtocol.decodePayload(bytes)
        val reEncoded = AppleProtocol.encodeWithPayload(
            AppleProtocol.MessageId.ConfigureAndStart,
            payload,
        )
        assertContentEquals(bytes, reEncoded)
    }

    private fun readFixture(name: String): ByteArray {
        val stream = javaClass.classLoader!!
            .getResourceAsStream("apple_protocol/$name")
            ?: error("Fixture not on classpath: apple_protocol/$name")
        return stream.use { it.readBytes() }
    }

    @Test
    fun parseAppleUWBConfigDataExtractsKnownFields() {
        // capture_001 = run 4 in the diff doc, forced short addr AABB.
        val payload = readFixture("apple_uwb_config_data_capture_001.bin")
        val parsed = AppleProtocol.parseAppleUWBConfigData(payload)
        assertEquals(0x00004F4F, parsed.sessionId)
        assertEquals(9, parsed.channel)
        assertEquals(11, parsed.preambleIndex)
        // dest_address (LE u16) at bytes 26..27 = `D8 91` → 0x91D8.
        // UwbAddress takes MSB-first bytes, so the stored array is
        // `0x91, 0xD8`.
        assertContentEquals(
            byteArrayOf(0x91.toByte(), 0xD8.toByte()),
            parsed.peerShortAddress,
        )
        // 6-byte Static-STS IV at bytes 20..25.
        val stsIv = byteArrayOf(
            0x1B, 0xAF.toByte(), 0x75, 0x65, 0x52, 0x38,
        )
        assertContentEquals(stsIv, parsed.stsIv)
        assertContentEquals(payload, parsed.raw)
    }

    @Test
    fun parseAppleUWBConfigDataAcrossCaptures() {
        val parsed1 = AppleProtocol.parseAppleUWBConfigData(
            readFixture("apple_uwb_config_data_capture_001.bin"),
        )
        val parsed2 = AppleProtocol.parseAppleUWBConfigData(
            readFixture("apple_uwb_config_data_capture_002.bin"),
        )
        val parsed3 = AppleProtocol.parseAppleUWBConfigData(
            readFixture("apple_uwb_config_data_capture_003.bin"),
        )
        // Session ids are random per iOS NI session — must all differ.
        assertNotEquals(parsed1.sessionId, parsed2.sessionId)
        assertNotEquals(parsed2.sessionId, parsed3.sessionId)
        assertNotEquals(parsed1.sessionId, parsed3.sessionId)
        // Channel + preamble are profile-fixed across all captures.
        assertEquals(parsed1.channel, parsed2.channel)
        assertEquals(parsed2.channel, parsed3.channel)
        assertEquals(parsed1.preambleIndex, parsed2.preambleIndex)
        assertEquals(parsed2.preambleIndex, parsed3.preambleIndex)
        // STS IVs differ per session.
        assertNotEquals(parsed1.stsIv.toList(), parsed2.stsIv.toList())
        assertNotEquals(parsed2.stsIv.toList(), parsed3.stsIv.toList())
        // Each IV is 6 bytes per Static-STS layout.
        assertEquals(6, parsed1.stsIv.size)
        assertEquals(6, parsed2.stsIv.size)
        assertEquals(6, parsed3.stsIv.size)
        // peerShortAddress (iPhone dest_address) differs per session.
        // Verifies our forced AABB (capture 001) didn't leak into the
        // parsed peer — Apple uses its own per-session short MAC.
        assertNotEquals(
            byteArrayOf(0xAA.toByte(), 0xBB.toByte()).toList(),
            parsed1.peerShortAddress.toList(),
        )
        assertNotEquals(
            parsed1.peerShortAddress.toList(),
            parsed2.peerShortAddress.toList(),
        )
    }

    @Test
    fun parseAppleUWBConfigDataRejectsTruncated() {
        assertFailsWith<IllegalArgumentException> {
            AppleProtocol.parseAppleUWBConfigData(byteArrayOf(0x01, 0x02, 0x03, 0x04))
        }
    }

    @Test
    fun parseAppleUWBConfigDataAcceptsTrailingBytes() {
        val base = readFixture("apple_uwb_config_data_capture_001.bin")
        val extended = base + ByteArray(16) // 16 trailing zero bytes
        val parsed = AppleProtocol.parseAppleUWBConfigData(extended)
        val parsedBase = AppleProtocol.parseAppleUWBConfigData(base)
        assertEquals(parsedBase.sessionId, parsed.sessionId)
        assertEquals(parsedBase.channel, parsed.channel)
        assertContentEquals(parsedBase.stsIv, parsed.stsIv)
        // raw is truncated to the spec-bound 30 bytes.
        assertEquals(30, parsed.raw.size)
    }

    @Test
    fun parseAppleUWBConfigDataPreservesShortAddressEndianness() {
        // Capture 001 dest_address bytes (LE u16, offsets 26..27) are
        // `D8 91`. UwbAddress is MSB-first so the parsed array must
        // be `0x91 0xD8`, equal to the FiRa short MAC value 0x91D8.
        val parsed = AppleProtocol.parseAppleUWBConfigData(
            readFixture("apple_uwb_config_data_capture_001.bin"),
        )
        assertContentEquals(
            byteArrayOf(0x91.toByte(), 0xD8.toByte()),
            parsed.peerShortAddress,
        )
    }

    @Test
    fun parseAppleUWBConfigDataExtractsSlotDurationFromLiveCapture() {
        // 30-byte ConfigureAndStart payload captured from iPhone
        // 26.4.1 ↔ Galaxy S22 Ultra Android 16 in
        // docs/agents/research/captures/cross_os_20260506_231622/.
        // Bytes 15..16 LE = 0x0E10 = 3600 RSTU = 3 ms (Apple's required
        // slot duration that motivated the android.ranging migration).
        val payload = byteArrayOf(
            0x01, 0x00, 0x01, 0x00, 0x19, 0x45, 0x55, 0x51,
            0xF4.toByte(), 0x00, 0x00, 0x0B, 0x09, 0x06, 0x00,
            0x10, 0x0E, 0xB4.toByte(), 0x00, 0x03, 0x71, 0xBB.toByte(),
            0x76, 0xAA.toByte(), 0x16, 0xF9.toByte(), 0xD5.toByte(),
            0x9F.toByte(), 0xC8.toByte(), 0x00,
        )
        val parsed = AppleProtocol.parseAppleUWBConfigData(payload)
        assertEquals(3600, parsed.slotDurationRstu)
        // Sanity-check the rest of the live capture decoded identically
        // to what the runtime saw and logged.
        assertEquals(0x0000F451, parsed.sessionId)
        assertEquals(9, parsed.channel)
        assertEquals(11, parsed.preambleIndex)
    }

    @Test
    fun parseAppleUWBConfigDataReadsSlotDurationLittleEndian() {
        // Synthetic payload with bytes 15..16 = 0xD0 0x07 (LE u16 = 2000).
        // Verifies byte order — a big-endian read would yield 0xD007 = 53255.
        val payload = ByteArray(30).apply {
            this[15] = 0xD0.toByte()
            this[16] = 0x07
        }
        val parsed = AppleProtocol.parseAppleUWBConfigData(payload)
        assertEquals(2000, parsed.slotDurationRstu)
    }

    @Test
    fun accessoryConfigurationDataMatchesAppleSpecWrapper() {
        val sa0 = 0xAB.toByte()
        val sa1 = 0xCD.toByte()
        val data = AppleProtocol.buildAccessoryConfigurationData(
            sessionId = 0,
            channel = 0,
            preambleIndex = 0,
            shortAddress = byteArrayOf(sa0, sa1),
        )
        // Apple NI Accessory Protocol Spec R2 §3.4: 16-byte wrapper +
        // 21-byte UWBConfigData = 37 bytes total (excluding the 0x01
        // message-id byte the framing layer prepends).
        assertEquals(37, data.size)
        assertEquals(0x01.toByte(), data[0]); assertEquals(0x00.toByte(), data[1]) // Major=1
        assertEquals(0x00.toByte(), data[2]); assertEquals(0x00.toByte(), data[3]) // Minor=0
        assertEquals(0x14.toByte(), data[4]) // PreferredUpdateRate=20
        for (i in 5..14) assertEquals(0x00.toByte(), data[i], "RFU byte $i must be zero")
        assertEquals(0x15.toByte(), data[15]) // UWBConfigDataLength=21
        // Short address spliced at UWBConfigData offsets 17-18 (full payload offsets 33-34).
        assertEquals(sa0, data[33])
        assertEquals(sa1, data[34])
    }
}
