package com.ahmedhamdan.flutter_uwb.strategy

/**
 * One per-peer UWB ranging strategy on Android.
 *
 * Mirror of the iOS-side `RangingStrategy.swift`: each implementation
 * owns its own Jetpack-UWB session scope, runs the appropriate FiRa
 * configuration for the peer kind, and emits samples / errors through
 * the host's `UwbFlutterApi`.
 *
 * Selection lives in `UwbHostApiImpl.startRanging` and keys off
 * `UwbDevice.platform`:
 * - "android" / "ios"   -> [AndroidPeerStrategy]
 * - "accessory"         -> [AndroidControleeStrategy]
 * - "accessory:<vendor>"-> currently routes to [AndroidControleeStrategy]
 *   too (the built-in Apple-protocol controlee role); a vendor adapter
 *   is a follow-up.
 */
interface RangingStrategy {
    /** Stable peer id used for sample routing on the Dart side. */
    val deviceId: String

    /**
     * Begin ranging. The strategy is responsible for any platform-side
     * handshake (peer mode: build [androidx.core.uwb.RangingParameters]
     * and run; controlee mode: drive the multi-message Apple-protocol
     * exchange before starting the session).
     *
     * Suspend-friendly because Jetpack UWB scope acquisition is itself
     * a `suspend` call.
     */
    suspend fun start()

    /**
     * Tear down ranging. After [stop] the strategy is dead — the host
     * allocates a new instance for the next session.
     */
    fun stop()
}
