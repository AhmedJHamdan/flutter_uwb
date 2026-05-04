package com.ahmedhamdan.flutter_uwb.oob

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * Smoke-level scaffolding for BleOob unit tests. Real coverage lands in
 * later phases (capability flag, MTU negotiation, ECDH handshake).
 *
 * BleOob touches the platform Bluetooth stack directly, so the test will
 * grow a `FakeBluetoothManager` harness that fakes [BluetoothLeAdvertiser],
 * [BluetoothLeScanner], [BluetoothGatt], and [BluetoothGattServer] surfaces
 * once we need it.
 */
class BleOobFakeTest {

    @Test
    fun accessoryProfileEqualityIsByValue() {
        val uuid1 = java.util.UUID.fromString("0000180A-0000-1000-8000-00805F9B34FB")
        val uuid2 = java.util.UUID.fromString("00002A29-0000-1000-8000-00805F9B34FB")
        val uuid3 = java.util.UUID.fromString("00002A24-0000-1000-8000-00805F9B34FB")

        val a = BleOob.AccessoryProfile(uuid1, uuid2, uuid3)
        val b = BleOob.AccessoryProfile(uuid1, uuid2, uuid3)

        assertEquals(a, b, "AccessoryProfile is a data class; equality should be by value")
        assertNotNull(a.serviceUuid)
    }
}
