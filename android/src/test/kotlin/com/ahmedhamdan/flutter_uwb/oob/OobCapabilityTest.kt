package com.ahmedhamdan.flutter_uwb.oob

import kotlin.test.Test
import kotlin.test.assertEquals

class OobCapabilityTest {

    @Test
    fun localServiceDataAdvertisesAndroidPeer() {
        val payload = OobCapability.localServiceData()
        assertEquals(1, payload.size)
        assertEquals(OobCapability.ANDROID_PEER, payload[0])
    }

    @Test
    fun parseFallsBackToUnknownDefaultForMissingOrEmpty() {
        assertEquals(OobCapability.UNKNOWN_DEFAULT, OobCapability.parse(null))
        assertEquals(OobCapability.UNKNOWN_DEFAULT, OobCapability.parse(ByteArray(0)))
    }

    @Test
    fun parseReadsFirstByte() {
        assertEquals(
            OobCapability.IOS_PEER,
            OobCapability.parse(byteArrayOf(OobCapability.IOS_PEER)),
        )
        assertEquals(
            OobCapability.ACCESSORY_HOST,
            OobCapability.parse(byteArrayOf(OobCapability.ACCESSORY_HOST, 0x77)),
        )
    }

    @Test
    fun iosPeerRoutesToAccessoryControleeStrategyOnAndroid() {
        assertEquals(
            "accessory:ios",
            OobCapability.toAndroidPlatform(OobCapability.IOS_PEER),
        )
        assertEquals(
            "android",
            OobCapability.toAndroidPlatform(OobCapability.ANDROID_PEER),
        )
        assertEquals(
            "android",
            OobCapability.toAndroidPlatform(OobCapability.UNKNOWN_DEFAULT),
        )
    }
}
