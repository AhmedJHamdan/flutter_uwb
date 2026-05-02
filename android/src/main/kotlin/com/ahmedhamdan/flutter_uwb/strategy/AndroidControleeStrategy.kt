package com.ahmedhamdan.flutter_uwb.strategy

import android.util.Log
import androidx.core.uwb.RangingParameters
import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbComplexChannel
import androidx.core.uwb.UwbControleeSessionScope
import androidx.core.uwb.UwbManager
import androidx.core.uwb.UwbDevice as JetpackUwbDevice
import com.ahmedhamdan.flutter_uwb.RangingSample
import com.ahmedhamdan.flutter_uwb.UwbFlutterApi
import com.ahmedhamdan.flutter_uwb.accessory.AppleProtocol
import com.ahmedhamdan.flutter_uwb.oob.BleOob
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/**
 * Android-as-controlee against an iPhone host (or any host that speaks
 * Apple's FiRa accessory BLE protocol).
 *
 * In this mode the iPhone is the *controller* and Android is the
 * *controlee*. Android advertises on the registered accessory service
 * UUID; the iPhone scans, connects, and drives the multi-message
 * exchange. Android replies and runs `controleeSessionScope.prepareSession`
 * on its end.
 *
 * ## Pairing flow
 *
 * 1. Android registers an [com.ahmedhamdan.flutter_uwb.AccessoryProfile]
 *    via `registerAccessoryProfile`. `BleOob` advertises the service +
 *    Tx/Rx characteristics.
 * 2. iPhone connects, subscribes to Tx, writes `Initialize` (0x0A) to Rx.
 * 3. `BleOob` invokes [handleAccessoryRequest] with the bytes. Strategy
 *    builds an `AccessoryConfigurationData` (0x01) payload describing
 *    Android's UWB session params and pushes it back via
 *    [BleOob.accessoryNotify].
 * 4. iPhone runs its `NISession` to derive shareable config bytes, then
 *    writes `ConfigureAndStart` (0x0B) to Rx.
 * 5. Strategy parses the shareable bytes into `RangingParameters` and
 *    runs `controleeSessionScope.prepareSession(params).collect`.
 * 6. Android pushes `AccessoryUwbDidStart` (0x02) once the radio is up.
 * 7. Samples flow through `flutterApi.onRangingSample`.
 *
 * ## Hardware verification gap
 *
 * The byte layouts for `AccessoryConfigurationData` and the shareable
 * portion of `ConfigureAndStart` are not formally documented by Apple
 * — they are defined by what `NINearbyAccessoryConfiguration(data:)`
 * accepts and emits. Until verified against an iPhone↔Android UWB
 * pairing, the mapping below is a best-effort placeholder. Look for
 * `TODO(verify)` markers in [AppleProtocol] and below.
 */
class AndroidControleeStrategy(
    override val deviceId: String,
    private val ble: BleOob,
    private val uwbManager: UwbManager,
    private val flutterApi: UwbFlutterApi,
    private val rangingScope: CoroutineScope,
) : RangingStrategy {

    private val tag = "flutter_uwb"

    private enum class State {
        Idle,
        AwaitingInitialize,
        AwaitingConfigureAndStart,
        Ranging,
        Stopping,
    }

    private var state: State = State.Idle
    private var controleeScope: UwbControleeSessionScope? = null
    private var rangingJob: Job? = null
    /** Session id used in the AccessoryConfigurationData payload. */
    private var sessionId: Int = 0

    override suspend fun start() {
        // Ensure we have a UWB controlee scope ready before iPhone
        // connects, so the AccessoryConfigurationData payload reflects
        // real radio state.
        controleeScope = uwbManager.controleeSessionScope()
        sessionId = Random.nextInt(1, Int.MAX_VALUE)
        state = State.AwaitingInitialize
    }

    override fun stop() {
        val wasActive = state != State.Idle && state != State.Stopping
        state = State.Stopping
        rangingJob?.cancel()
        rangingJob = null
        if (wasActive) {
            // Best-effort Stop notification to the host. Failures here
            // are non-fatal — the BLE link may already be torn down.
            try {
                ble.accessoryNotify(
                    deviceId = deviceId,
                    bytes = AppleProtocol.encodeIdOnly(AppleProtocol.MessageId.Stop),
                )
            } catch (_: Throwable) {}
        }
        state = State.Idle
    }

    /**
     * Called by the host when the iPhone writes Apple-protocol bytes to
     * Android's Rx characteristic. Bytes are a fully-reassembled
     * message; this method dispatches on byte 0.
     */
    suspend fun handleAccessoryRequest(bytes: ByteArray) {
        val id = AppleProtocol.decodeId(bytes)
        val payload = AppleProtocol.decodePayload(bytes)
        when (state to id) {
            State.AwaitingInitialize to AppleProtocol.MessageId.Initialize -> {
                replyAccessoryConfigurationData()
                state = State.AwaitingConfigureAndStart
            }
            State.AwaitingConfigureAndStart to AppleProtocol.MessageId.ConfigureAndStart -> {
                runControleeSession(payload)
                ble.accessoryNotify(
                    deviceId = deviceId,
                    bytes = AppleProtocol.encodeIdOnly(
                        AppleProtocol.MessageId.AccessoryUwbDidStart,
                    ),
                )
                state = State.Ranging
            }
            State.Ranging to AppleProtocol.MessageId.Stop -> {
                stop()
                ble.accessoryNotify(
                    deviceId = deviceId,
                    bytes = AppleProtocol.encodeIdOnly(
                        AppleProtocol.MessageId.AccessoryUwbDidStop,
                    ),
                )
            }
            else -> {
                Log.w(tag, "Unexpected accessory message id=$id in state=$state")
            }
        }
    }

    private fun replyAccessoryConfigurationData() {
        val scope = controleeScope ?: return
        val data = AppleProtocol.buildAccessoryConfigurationData(
            sessionId = sessionId,
            // TODO(verify): channel/preamble for controlee mode are
            // negotiated from the host's ConfigureAndStart payload, not
            // chosen here. Until verified, surface zeros so the iPhone
            // overrides them with its own values.
            channel = 0,
            preambleIndex = 0,
            shortAddress = scope.localAddress.address,
        )
        ble.accessoryNotify(
            deviceId = deviceId,
            bytes = AppleProtocol.encodeWithPayload(
                AppleProtocol.MessageId.AccessoryConfigurationData,
                data,
            ),
        )
    }

    private fun runControleeSession(shareableConfig: ByteArray) {
        val scope = controleeScope ?: return
        val parsed = try {
            AppleProtocol.parseAccessoryConfigurationData(shareableConfig)
        } catch (t: Throwable) {
            // TODO(verify): the shareable config payload format from
            // iPhone's NISession isn't necessarily symmetric with our
            // AccessoryConfigurationData layout. This decode is a
            // placeholder until hardware verification.
            flutterApi.onRangingError(
                deviceId,
                "Could not parse ConfigureAndStart payload: ${t.message}",
            ) {}
            return
        }

        val params = RangingParameters(
            /* uwbConfigType  */ RangingParameters.CONFIG_UNICAST_DS_TWR,
            /* sessionId      */ parsed.sessionId,
            /* subSessionId   */ 0,
            /* sessionKeyInfo */ null,
            /* subSessionKey  */ null,
            /* complexChannel */ UwbComplexChannel(
                parsed.channel.toInt(),
                parsed.preambleIndex.toInt(),
            ),
            /* peerDevices    */ listOf(
                JetpackUwbDevice(UwbAddress(parsed.shortAddress)),
            ),
            /* updateRateType */ RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
        )

        rangingJob?.cancel()
        rangingJob = rangingScope.launch {
            scope.prepareSession(params)
                .onEach { result -> emitRangingResult(result) }
                .catch { t ->
                    Log.e(tag, "controlee ranging flow error", t)
                    flutterApi.onRangingError(
                        deviceId,
                        t.message ?: "ranging error",
                    ) {}
                }
                .collect { /* drained by onEach */ }
        }
    }

    private fun emitRangingResult(result: RangingResult) {
        when (result) {
            is RangingResult.RangingResultPosition -> {
                val pos = result.position
                val sample = RangingSample(
                    deviceId = deviceId,
                    distanceMeters = pos.distance?.value?.toDouble(),
                    azimuthDegrees = pos.azimuth?.value?.toDouble(),
                    elevationDegrees = pos.elevation?.value?.toDouble(),
                    elapsedRealtimeNanos = pos.elapsedRealtimeNanos,
                )
                flutterApi.onRangingSample(sample) {}
            }
            is RangingResult.RangingResultPeerDisconnected -> {
                flutterApi.onPeerLost(deviceId) {}
            }
        }
    }
}
