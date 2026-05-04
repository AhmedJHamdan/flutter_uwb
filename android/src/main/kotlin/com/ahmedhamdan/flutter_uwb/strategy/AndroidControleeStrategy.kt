package com.ahmedhamdan.flutter_uwb.strategy

import android.util.Log
import androidx.core.uwb.RangingParameters
import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbComplexChannel
import androidx.core.uwb.UwbControleeSessionScope
import androidx.core.uwb.UwbManager
import androidx.core.uwb.UwbDevice as JetpackUwbDevice
import com.ahmedhamdan.flutter_uwb.RangingError
import com.ahmedhamdan.flutter_uwb.RangingSample
import com.ahmedhamdan.flutter_uwb.UwbErrorCode
import com.ahmedhamdan.flutter_uwb.UwbFlutterApi
import com.ahmedhamdan.flutter_uwb.accessory.AppleProtocol
import com.ahmedhamdan.flutter_uwb.oob.BleOob
import java.security.SecureRandom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/**
 * Android-as-controlee against an iPhone host speaking Apple's FiRa
 * accessory BLE protocol. Mirrors [IosAccessoryStrategy] on the accessory
 * side.
 *
 * The controlee runs FiRa Static-STS DS-TWR
 * ([RangingParameters.CONFIG_UNICAST_DS_TWR]). Apple's NI Accessory
 * Protocol uses Static STS — the bytes that look like a session key in
 * `AppleUWBConfigData` are vendor-specific material, not a Provisioned-STS
 * sessionKeyInfo, and passing them through `sessionKeyInfo` on Android
 * causes the session to be DEINIT'd with `reasonCode=0` immediately.
 *
 * ## Pairing flow
 *
 * 1. [start] acquires a [UwbControleeSessionScope] and waits for BLE.
 * 2. iPhone writes `Initialize` (0x0A) → reply with `AccessoryConfigurationData`
 *    (0x01) containing session id, channel, preamble, and short address.
 * 3. iPhone writes `ConfigureAndStart` (0x0B + shareable config) →
 *    [runControleeSession] starts the UWB radio; notify `AccessoryUwbDidStart`
 *    (0x02).
 * 4. UWB ranging runs; samples stream through [emitRangingResult].
 * 5. iPhone writes `Stop` (0x0C) → [stop] is called; reply with
 *    `AccessoryUwbDidStop` (0x03).
 */
class AndroidControleeStrategy(
    initialDeviceId: String,
    private val ble: BleOob,
    private val uwbManager: UwbManager,
    private val flutterApi: UwbFlutterApi,
    private val rangingScope: CoroutineScope,
) : RangingStrategy {

    /**
     * iOS centrals connect using a random resolvable private address
     * that may not match the MAC the user originally tapped. The host
     * calls [retarget] when the inbound Apple-host write arrives so
     * subsequent `accessoryNotify` calls go back to the right central.
     */
    override var deviceId: String = initialDeviceId
        private set

    fun retarget(newDeviceId: String) {
        deviceId = newDeviceId
    }

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
        // Acquire scope before iPhone connects.
        controleeScope = uwbManager.controleeSessionScope()
        sessionId = SecureRandom().nextInt(Int.MAX_VALUE - 1) + 1
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

    suspend fun handleAccessoryRequest(bytes: ByteArray) {
        try {
            handleAccessoryRequestInner(bytes)
        } catch (t: Throwable) {
            Log.e(tag, "handleAccessoryRequest threw, state=$state", t)
            flutterApi.onRangingError(
                deviceId,
                RangingError(
                    code = UwbErrorCode.SESSIONINITFAILED,
                    message = "accessory dispatch failed: ${t.message}",
                ),
            ) {}
        }
    }

    private suspend fun handleAccessoryRequestInner(bytes: ByteArray) {
        val id = AppleProtocol.decodeId(bytes)
        val payload = AppleProtocol.decodePayload(bytes)
        Log.i(tag, "handleAccessoryRequest id=$id state=$state payloadLen=${payload.size}")
        when (state to id) {
            State.AwaitingInitialize to AppleProtocol.MessageId.Initialize -> {
                replyAccessoryConfigurationData()
                state = State.AwaitingConfigureAndStart
            }
            State.AwaitingConfigureAndStart to AppleProtocol.MessageId.ConfigureAndStart -> {
                Log.i(tag, "iPhone ConfigureAndStart hex=${payload.toHex()}")
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
        val scope = controleeScope
        if (scope == null) {
            Log.w(tag, "replyAccessoryConfigurationData: no controlee scope")
            return
        }
        // Debug-only override for the Phase-1 capture campaign: lets us
        // pin a known short address (e.g. AABB) into the
        // AccessoryConfigurationData so the iPhone's reply can be
        // diff'd byte-for-byte against the value we forced.
        val forced = readForcedShortAddr()
        val shortAddr = forced ?: scope.localAddress.address
        if (forced != null) {
            Log.i(tag, "short-addr override active: ${forced.toHex()}")
        }
        val data = AppleProtocol.buildAccessoryConfigurationData(
            sessionId = sessionId,
            channel = 0,
            preambleIndex = 0,
            shortAddress = shortAddr,
        )
        val wire = AppleProtocol.encodeWithPayload(
            AppleProtocol.MessageId.AccessoryConfigurationData,
            data,
        )
        Log.i(tag, "tx AccessoryConfigurationData (${wire.size}B) hex=${wire.toHex()}")
        ble.accessoryNotify(deviceId = deviceId, bytes = wire)
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02X".format(it) }

    /**
     * Debug-only hook for the AppleUWBConfigData capture campaign. Reads
     * `debug.flutter_uwb.force_short_addr` from Android system properties
     * (set via `adb shell setprop debug.flutter_uwb.force_short_addr AABB`).
     * The `debug.` prefix is required so non-rooted Galaxy shells can
     * write the value. Returns
     * `null` if the property is unset, malformed, or the SystemProperties
     * reflection call fails.
     */
    private fun readForcedShortAddr(): ByteArray? = runCatching {
        val cls = Class.forName("android.os.SystemProperties")
        val get = cls.getMethod("get", String::class.java)
        val raw = (get.invoke(null, "debug.flutter_uwb.force_short_addr") as? String)
            ?.trim()
            ?.removePrefix("0x")
            ?.removePrefix("0X")
        if (raw.isNullOrEmpty() || raw.length % 2 != 0) return@runCatching null
        raw.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }.getOrNull()

    private fun runControleeSession(shareableConfig: ByteArray) {
        val scope = controleeScope
        if (scope == null) {
            Log.w(tag, "runControleeSession: no controlee scope")
            return
        }
        val parsed = AppleProtocol.parseAppleUWBConfigData(shareableConfig)
        // Jetpack CONFIG_UNICAST_DS_TWR sessionKeyInfo layout is
        // vendorId(2B) || stsIv(6B). Apple does not transmit the
        // vendor id — its NI middleware injects a fixed value on the
        // iPhone side. 0x0807 is the value the NXP UWBJetpackExample
        // uses against NXP/Qorvo silicon and what most open-source
        // accessory firmwares default to; it is the most likely match
        // for Apple's MFi-bound vendor assignment.
        val sessionKeyInfo = byteArrayOf(0x08, 0x07) + parsed.stsIv
        Log.i(
            tag,
            "parsed Apple config sessionId=${parsed.sessionId} " +
                "ch=${parsed.channel} pre=${parsed.preambleIndex} " +
                "peerShort=${parsed.peerShortAddress.toHex()} " +
                "stsIv=${parsed.stsIv.toHex()}",
        )
        val params = RangingParameters(
            uwbConfigType = RangingParameters.CONFIG_UNICAST_DS_TWR,
            sessionId = parsed.sessionId,
            subSessionId = 0,
            sessionKeyInfo = sessionKeyInfo,
            subSessionKeyInfo = null,
            complexChannel = UwbComplexChannel(
                parsed.channel,
                parsed.preambleIndex,
            ),
            peerDevices = listOf(
                JetpackUwbDevice(UwbAddress(parsed.peerShortAddress)),
            ),
            updateRateType = RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
            // Apple uses 3 ms slot duration (3600 RSTU per byte 15..16
            // of AppleUWBConfigData). androidx.core.uwb's public API
            // restricts slotDurationMillis to {1, 2} and rejects any
            // other value with "The selected slot duration is not a
            // valid slot duration." Sticking with 2 ms — slot edges
            // still partially align (we observed continuous ~5 Hz
            // onRangingResult callbacks on hardware), but the per-frame
            // ToF measurement on Galaxy never converges to a non-null
            // distance because the slot offset drifts. Closing this
            // gap requires the AOSP UWB-support library's lower-level
            // FiraOpenSessionParams API which exposes arbitrary slot
            // durations in RSTU.
        )
        rangingJob?.cancel()
        rangingJob = rangingScope.launch {
            scope.prepareSession(params)
                .onEach { result -> emitRangingResult(result) }
                .catch { t ->
                    Log.e(tag, "controlee ranging flow error", t)
                    flutterApi.onRangingError(
                        deviceId,
                        RangingError(
                            code = UwbErrorCode.UNKNOWN,
                            message = t.message ?: "ranging error",
                        ),
                    ) {}
                }
                .collect { /* drained by onEach */ }
        }
    }

    private fun emitRangingResult(result: RangingResult) {
        when (result) {
            is RangingResult.RangingResultPosition -> {
                val pos = result.position
                val distance = pos.distance?.value?.toDouble() ?: return
                val sample = RangingSample(
                    deviceId = deviceId,
                    distanceMeters = distance,
                    azimuthDegrees = pos.azimuth?.value?.toDouble(),
                    elevationDegrees = pos.elevation?.value?.toDouble(),
                    elapsedRealtimeNanos = pos.elapsedRealtimeNanos,
                )
                flutterApi.onRangingSample(sample) {}
            }
            is RangingResult.RangingResultPeerDisconnected -> {
                flutterApi.onPeerLost(deviceId) {}
            }
            is RangingResult.RangingResultInitialized -> {
                Log.d(tag, "controlee ranging session initialized for $deviceId")
            }
            is RangingResult.RangingResultFailure -> {
                Log.w(tag, "controlee ranging failure for $deviceId reason=${result.reason}")
                flutterApi.onRangingError(
                    deviceId,
                    RangingError(
                        code = UwbErrorCode.UNKNOWN,
                        message = "ranging failure (reason=${result.reason})",
                    ),
                ) {}
            }
        }
    }
}
