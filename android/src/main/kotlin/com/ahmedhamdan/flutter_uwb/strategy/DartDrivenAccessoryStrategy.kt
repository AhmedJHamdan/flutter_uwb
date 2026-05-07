package com.ahmedhamdan.flutter_uwb.strategy

import android.os.SystemClock
import android.util.Log
import androidx.core.uwb.RangingParameters
import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbControleeSessionScope
import androidx.core.uwb.UwbControllerSessionScope
import androidx.core.uwb.UwbManager
import androidx.core.uwb.UwbDevice as JetpackUwbDevice
import com.ahmedhamdan.flutter_uwb.AccessoryHandshakeEvent
import com.ahmedhamdan.flutter_uwb.AccessoryHandshakeEventKind
import com.ahmedhamdan.flutter_uwb.FiraSessionParams
import com.ahmedhamdan.flutter_uwb.RangingError
import com.ahmedhamdan.flutter_uwb.RangingSample
import com.ahmedhamdan.flutter_uwb.UwbErrorCode
import com.ahmedhamdan.flutter_uwb.UwbFlutterApi
import com.ahmedhamdan.flutter_uwb.oob.BleOob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/**
 * Single Android entry point for accessory-controller ranging when a
 * Dart-side [com.ahmedhamdan.flutter_uwb.AccessoryAdapter] drives the
 * BLE-OOB exchange.
 *
 * Lifecycle:
 *   1. [start] opens [BleOob.accessoryConnect]; on ready fires
 *      `onAccessoryHandshakeEvent(deviceId, kind=connected)`.
 *   2. Inbound BLE notifies arrive through [handleNotify] and become
 *      `onAccessoryHandshakeEvent(kind=notifyBytes, bytes=...)`.
 *   3. The Dart adapter writes back via [accessoryProtocolWrite] (which
 *      goes to [BleOob.accessoryWrite]) and eventually returns
 *      [FiraSessionParams] via [completeAccessoryHandshake] — at which
 *      point we open the FiRa session.
 *   4. [failAccessoryHandshake] tears the strategy down on adapter
 *      failure or timeout.
 *   5. [stop] tears the strategy down on host stopRanging or BLE drop.
 *
 * The BLE link stays open across handshake → ranging → teardown so the
 * adapter can implement application-level keep-alive without a
 * dedicated heartbeat API.
 */
class DartDrivenAccessoryStrategy(
    initialDeviceId: String,
    private val vendorTag: String,
    private val ble: BleOob,
    private val uwbManager: UwbManager,
    private val flutterApi: UwbFlutterApi,
    private val rangingScope: CoroutineScope,
) : RangingStrategy {

    override var deviceId: String = initialDeviceId
        private set

    private val tag = "flutter_uwb"

    private enum class State {
        Idle,
        AwaitingConnect,
        Handshaking,
        Ranging,
        Stopping,
    }

    private var state: State = State.Idle
    private var controllerScope: UwbControllerSessionScope? = null
    private var controleeScope: UwbControleeSessionScope? = null
    private var rangingJob: Job? = null

    override suspend fun start() {
        state = State.AwaitingConnect
        Log.i(
            tag,
            "DIAG dart-driven-handshake-info ts=${SystemClock.elapsedRealtimeNanos()} " +
                "deviceId=$deviceId vendorTag=$vendorTag",
        )
        // Synthetic devices (e.g. the static-pair Qorvo tile seeded
        // from Dart) have no real BLE accessory to connect to. Fire
        // CONNECTED immediately so the Dart adapter can return its
        // hardcoded FiRa params without a transport layer in between.
        if (!ble.hasAccessoryDevice(deviceId)) {
            Log.i(
                tag,
                "dart-driven: $deviceId is synthetic (no BLE profile match) " +
                    "— firing CONNECTED directly",
            )
            state = State.Handshaking
            flutterApi.onAccessoryHandshakeEvent(
                deviceId,
                AccessoryHandshakeEvent(kind = AccessoryHandshakeEventKind.CONNECTED),
            ) {}
            return
        }
        // BleOob fires onReady on the BLE binder thread. Hop to
        // rangingScope (main) before touching flutterApi.
        ble.accessoryConnect(deviceId) { ready ->
            rangingScope.launch {
                if (state == State.Stopping || state == State.Idle) return@launch
                if (!ready) {
                    fail("BLE not ready for $deviceId")
                    return@launch
                }
                state = State.Handshaking
                flutterApi.onAccessoryHandshakeEvent(
                    deviceId,
                    AccessoryHandshakeEvent(kind = AccessoryHandshakeEventKind.CONNECTED),
                ) {}
            }
        }
    }

    override fun stop() {
        val wasActive = state != State.Idle && state != State.Stopping
        state = State.Stopping
        rangingJob?.cancel()
        rangingJob = null
        if (wasActive) {
            // Notify the Dart adapter so it can cancel pending work.
            try {
                flutterApi.onAccessoryHandshakeEvent(
                    deviceId,
                    AccessoryHandshakeEvent(
                        kind = AccessoryHandshakeEventKind.STOPREQUESTED,
                    ),
                ) {}
            } catch (_: Throwable) {}
        }
        ble.accessoryDisconnect(deviceId)
        state = State.Idle
    }

    /** Called by the BLE host callback when the accessory pushes notify
     *  bytes on the matched profile's `txUuid` characteristic. */
    fun handleNotify(bytes: ByteArray) {
        if (state != State.Handshaking && state != State.Ranging) return
        flutterApi.onAccessoryHandshakeEvent(
            deviceId,
            AccessoryHandshakeEvent(
                kind = AccessoryHandshakeEventKind.NOTIFYBYTES,
                bytes = bytes,
            ),
        ) {}
    }

    /** Called by the BLE host callback when the GATT link drops. */
    fun handleDisconnected() {
        if (state == State.Idle || state == State.Stopping) return
        try {
            flutterApi.onAccessoryHandshakeEvent(
                deviceId,
                AccessoryHandshakeEvent(
                    kind = AccessoryHandshakeEventKind.DISCONNECTED,
                ),
            ) {}
        } catch (_: Throwable) {}
        // Treat as a fatal error so the host clears activeStrategy.
        fail("BLE disconnected for $deviceId")
    }

    // ---------------- HostApi entry points (called from UwbHostApiImpl) ----------------

    /** Adapter → accessory bytes. */
    fun accessoryProtocolWrite(bytes: ByteArray) {
        ble.accessoryWrite(deviceId, bytes)
    }

    /**
     * Adapter delivered the FiRa params it negotiated. Open the
     * Jetpack scope, build [RangingParameters], and start the session.
     */
    fun completeAccessoryHandshake(params: FiraSessionParams): String? {
        val validationError = validateParams(params)
        if (validationError != null) {
            fail(validationError)
            return validationError
        }
        rangingScope.launch {
            try {
                val scope = uwbManager.controllerSessionScope().also { controllerScope = it }
                runControllerSession(scope, params)
            } catch (t: Throwable) {
                Log.e(tag, "completeAccessoryHandshake failed", t)
                fail(t.message ?: "completeAccessoryHandshake failed")
            }
        }
        return null
    }

    /** Adapter signals failure. */
    fun failAccessoryHandshake(message: String) {
        fail(message)
    }

    private fun runControllerSession(
        scope: UwbControllerSessionScope,
        params: FiraSessionParams,
    ) {
        // Apple-NI compatibility: the adapter often sends a placeholder
        // session-key vendor + STS IV. Pass it through verbatim.
        val rangingParams = RangingParameters(
            uwbConfigType = RangingParameters.CONFIG_UNICAST_DS_TWR,
            // Pigeon emits Long for Dart int (64-bit); Jetpack's
            // RangingParameters.sessionId is Int. Truncate to the low
            // 32 bits — adapters generating session ids beyond the
            // signed-Int range get wraparound, which is documented in
            // the Dart-side `FiraSessionParams.sessionId`.
            sessionId = params.sessionId.toInt(),
            subSessionId = 0,
            sessionKeyInfo = params.sessionKeyInfo,
            subSessionKeyInfo = null,
            complexChannel = scope.uwbComplexChannel,
            peerDevices = listOf(
                JetpackUwbDevice(UwbAddress(params.peerShortAddress)),
            ),
            updateRateType = RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
        )
        val myAddr = scope.localAddress.address
        Log.i(
            tag,
            "DIAG static-pair-info ts=${SystemClock.elapsedRealtimeNanos()} " +
                "myAddr=${myAddr.toHex()} ch=${scope.uwbComplexChannel.channel} " +
                "pre=${scope.uwbComplexChannel.preambleIndex} " +
                "sessionId=${params.sessionId} " +
                "peerShort=${params.peerShortAddress.toHex()} " +
                "vendorTag=$vendorTag",
        )
        Log.i(
            tag,
            "DIAG session-start ts=${SystemClock.elapsedRealtimeNanos()} " +
                "sessionId=${params.sessionId} ch=${scope.uwbComplexChannel.channel} " +
                "preamble=${scope.uwbComplexChannel.preambleIndex} " +
                "peerShort=${params.peerShortAddress.toHex()} " +
                "config=CONFIG_UNICAST_DS_TWR updateRate=AUTOMATIC " +
                "role=controller mode=dart-driven",
        )
        state = State.Ranging
        rangingJob?.cancel()
        rangingJob = rangingScope.launch {
            scope.prepareSession(rangingParams)
                .onEach { result -> emitRangingResult(result) }
                .catch { t ->
                    Log.e(tag, "dart-driven ranging flow error", t)
                    fail(t.message ?: "ranging error")
                }
                .collect { /* drained by onEach */ }
        }
    }

    private fun emitRangingResult(result: RangingResult) {
        val nowTs = SystemClock.elapsedRealtimeNanos()
        when (result) {
            is RangingResult.RangingResultPosition -> {
                val pos = result.position
                val dist = pos.distance?.value
                val az = pos.azimuth?.value
                val el = pos.elevation?.value
                Log.i(
                    tag,
                    "DIAG cb-pos ts=$nowTs " +
                        "dist=${dist ?: "null"} az=${az ?: "null"} " +
                        "el=${el ?: "null"} rt=${pos.elapsedRealtimeNanos}",
                )
                if (dist == null) return
                flutterApi.onRangingSample(
                    RangingSample(
                        deviceId = deviceId,
                        distanceMeters = dist.toDouble(),
                        azimuthDegrees = az?.toDouble(),
                        elevationDegrees = el?.toDouble(),
                        elapsedRealtimeNanos = pos.elapsedRealtimeNanos,
                    ),
                ) {}
            }
            is RangingResult.RangingResultPeerDisconnected -> {
                Log.w(tag, "DIAG cb-peer-disc ts=$nowTs for $deviceId")
                flutterApi.onPeerLost(deviceId) {}
            }
            is RangingResult.RangingResultInitialized -> {
                Log.i(tag, "DIAG cb-init ts=$nowTs for $deviceId")
            }
            is RangingResult.RangingResultFailure -> {
                Log.w(
                    tag,
                    "DIAG cb-failure ts=$nowTs reason=${result.reason} for $deviceId",
                )
                fail("ranging failure (reason=${result.reason})")
            }
        }
    }

    private fun fail(message: String) {
        if (state == State.Idle) return
        state = State.Stopping
        rangingJob?.cancel()
        rangingJob = null
        try {
            flutterApi.onRangingError(
                deviceId,
                RangingError(
                    code = UwbErrorCode.SESSIONINITFAILED,
                    message = message,
                ),
            ) {}
        } catch (_: Throwable) {}
        // Only tear down BLE when there was actually a BLE link to
        // close — synthetic devices never opened one.
        if (ble.hasAccessoryDevice(deviceId)) {
            try { ble.accessoryDisconnect(deviceId) } catch (_: Throwable) {}
        }
        state = State.Idle
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02X".format(it) }

    companion object {
        /**
         * Pure validation of FiRa params we can pass to the Jetpack
         * `RangingParameters` constructor. Returns `null` on success or
         * a human-readable error message describing why the params are
         * unsupported. Lifted out of [completeAccessoryHandshake] so unit
         * tests can pin the contract without spinning up a strategy.
         */
        fun validateParams(params: FiraSessionParams): String? {
            // Slot duration: Jetpack's IntDef gates {1, 2}. Adapters
            // that need 3+ ms must wait for android.ranging support.
            if (params.slotDurationMs !in 1L..2L) {
                return "slot duration ${params.slotDurationMs} ms " +
                    "unsupported on this Android version (Jetpack accepts " +
                    "1 or 2; android.ranging support is a follow-up)"
            }
            if (!params.roleIsController) {
                // v1 only supports controller role; controlee path is
                // the existing AndroidControleeStrategy{,Ranging} family.
                return "controlee role not supported by Dart-driven " +
                    "adapter framework in v1"
            }
            if (params.peerShortAddress.size < 2) {
                return "peerShortAddress must be at least 2 bytes, " +
                    "got ${params.peerShortAddress.size}"
            }
            return null
        }
    }
}
