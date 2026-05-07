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

/**
 * Sub-interface for accessory-mode controlee strategies — strategies
 * that are driven by inbound BLE writes from an iPhone NI host. The
 * dispatcher in `UwbHostApiImpl.onAccessoryRequest` casts the active
 * strategy to this type so it can route bytes to either the Jetpack
 * implementation ([AndroidControleeStrategy]) on Android < 16 or the
 * `android.ranging` implementation ([AndroidControleeStrategyRanging])
 * on Android 16+.
 */
interface AccessoryControleeStrategy : RangingStrategy {
    /**
     * Update the BLE central id this strategy notifies on. iOS hosts
     * connect with a random resolvable private address that may not
     * match the MAC the user originally tapped; the dispatcher calls
     * this on each inbound write so subsequent `accessoryNotify` calls
     * go back to the right central.
     */
    fun retarget(newDeviceId: String)

    /**
     * Handle an inbound Apple-protocol message from the iPhone host.
     * The dispatcher already routed the bytes here; the strategy
     * decodes the message id and drives its state machine.
     */
    suspend fun handleAccessoryRequest(bytes: ByteArray)
}
