package com.ahmedhamdan.flutter_uwb.oob

/**
 * 1-byte capability flag advertised in BLE service-data alongside the
 * symmetric flutter_uwb service UUID.
 *
 * In flutter_uwb 1.0.0 the only routed peer kind on Android is another
 * Android phone running flutter_uwb. The remaining values are kept on
 * the wire so a peer that advertises [IOS_PEER] (or no service-data,
 * which is interpreted the same way) is dropped at the discovery
 * layer rather than treated as an Android peer.
 */
object OobCapability {
    const val IOS_PEER: Byte = 0x01
    const val ANDROID_PEER: Byte = 0x02

    /** Applied to peers whose advertisement omits service-data. */
    const val UNKNOWN_DEFAULT: Byte = ANDROID_PEER

    /**
     * Single-byte service-data payload to advertise alongside the
     * `BleOob` service UUID. Always [ANDROID_PEER] from this side.
     */
    fun localServiceData(): ByteArray = byteArrayOf(ANDROID_PEER)

    /**
     * Decode the first byte of an advertised service-data payload. Falls
     * back to [UNKNOWN_DEFAULT] when missing or empty.
     */
    fun parse(serviceData: ByteArray?): Byte {
        if (serviceData == null || serviceData.isEmpty()) return UNKNOWN_DEFAULT
        return serviceData[0]
    }

    /**
     * Map a remote capability byte to the `UwbDevice.platform` string
     * surfaced through Pigeon. Only Android peers reach the strategy
     * dispatcher in 1.0.0.
     */
    fun toAndroidPlatform(@Suppress("UNUSED_PARAMETER") capability: Byte): String =
        "android"
}
