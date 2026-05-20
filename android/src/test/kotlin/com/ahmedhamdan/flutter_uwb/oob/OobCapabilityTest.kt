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
    fun peerBytesAreDistinct() {
        assertEquals(0x01.toByte(), OobCapability.IOS_PEER)
        assertEquals(0x02.toByte(), OobCapability.ANDROID_PEER)
    }
}
