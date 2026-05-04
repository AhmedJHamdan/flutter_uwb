package com.ahmedhamdan.flutter_uwb.oob

/**
 * 1-byte capability flag advertised in BLE service-data so the local
 * Android stack can route iOS↔Android pairs through accessory mode and
 * keep same-OS pairs on peer mode without guessing.
 *
 * Mirrors `lib/src/oob_capability.dart` and the iOS `OobCapability`
 * enum. Values `0x03`–`0xFF` are reserved; unknown values are treated
 * as [ANDROID_PEER] for back-compat with 0.3.x peers that did not
 * advertise this byte.
 */
object OobCapability {
    const val IOS_PEER: Byte = 0x01
    const val ANDROID_PEER: Byte = 0x02
    const val ACCESSORY_HOST: Byte = 0x03

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
     * used by the strategy dispatcher when the local stack is Android.
     *
     * - Remote iOS peer → `accessory:ios` so the existing dispatcher
     *   sends it to `AndroidControleeStrategy`.
     * - Anything else → `android` (peer mode).
     */
    fun toAndroidPlatform(capability: Byte): String = when (capability) {
        IOS_PEER -> "accessory:ios"
        else -> "android"
    }
}
