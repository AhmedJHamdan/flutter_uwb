package com.ahmedhamdan.flutter_uwb.oob

/**
 * 1-byte capability flag advertised in BLE service-data alongside the
 * symmetric flutter_uwb service UUID.
 *
 * flutter_uwb 1.0.0 ranges Android↔Android only. The byte lets a
 * scanning Android peer recognise another Android flutter_uwb peer and
 * ignore everything else on the shared service UUID: this side always
 * advertises [ANDROID_PEER], and an advertisement that carries no
 * service-data is treated as [IOS_PEER] and dropped at the discovery
 * layer (iOS BLE advertisements cannot carry service-data).
 */
object OobCapability {
    const val IOS_PEER: Byte = 0x01
    const val ANDROID_PEER: Byte = 0x02

    /**
     * Single-byte service-data payload to advertise alongside the
     * `BleOob` service UUID. Always [ANDROID_PEER] from this side.
     */
    fun localServiceData(): ByteArray = byteArrayOf(ANDROID_PEER)
}
