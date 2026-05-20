package com.ahmedhamdan.flutter_uwb.strategy

/**
 * One per-peer UWB ranging strategy on Android.
 *
 * Mirror of the iOS-side `RangingStrategy.swift`: each implementation
 * owns its own Jetpack-UWB session scope, runs the appropriate FiRa
 * configuration for the peer, and emits samples / errors through the
 * host's `UwbFlutterApi`.
 *
 * Selection lives in `UwbHostApiImpl.startRanging` and keys off
 * `UwbDevice.platform`. flutter_uwb 1.0.0 ranges Android↔Android only,
 * so the sole routed kind is another Android phone
 * ("android" -> [AndroidPeerStrategy]); any other platform is rejected
 * before a strategy is created.
 */
interface RangingStrategy {
    /** Stable peer id used for sample routing on the Dart side. */
    val deviceId: String

    /**
     * Begin ranging. The strategy builds its
     * [androidx.core.uwb.RangingParameters] and starts the session.
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
