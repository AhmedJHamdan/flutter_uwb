package com.ahmedhamdan.flutter_uwb.strategy

import android.annotation.SuppressLint
import android.content.Context
import android.os.CancellationSignal
import android.os.SystemClock
import android.ranging.RangingData
import android.ranging.RangingDevice
import android.ranging.RangingManager
import android.ranging.RangingPreference
import android.ranging.RangingSession
import android.ranging.SessionConfig
import android.ranging.raw.RawRangingDevice
import android.ranging.raw.RawResponderRangingConfig
import android.ranging.uwb.UwbAddress
import android.ranging.uwb.UwbComplexChannel
import android.ranging.uwb.UwbRangingParams
import android.util.Log
import androidx.annotation.RequiresApi
import com.ahmedhamdan.flutter_uwb.RangingError
import com.ahmedhamdan.flutter_uwb.RangingSample
import com.ahmedhamdan.flutter_uwb.UwbErrorCode
import com.ahmedhamdan.flutter_uwb.UwbFlutterApi
import com.ahmedhamdan.flutter_uwb.accessory.AppleProtocol
import com.ahmedhamdan.flutter_uwb.oob.BleOob
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Android-as-controlee against an iPhone host speaking Apple's FiRa
 * accessory BLE protocol. Mirrors [AndroidControleeStrategy] but opens
 * the UWB session through the Android-16+ `android.ranging.*` API
 * instead of Jetpack `androidx.core.uwb`.
 *
 * The new API exposes [UwbRangingParams.Builder.setSlotDuration] without
 * the `{1, 2}` runtime gate Jetpack applies, so we can pass Apple's
 * required 3 ms slot duration verbatim. The chain
 * `setSlotDuration(ms) → system service → Utils.convertMsToRstu (×1200)
 * → FiraOpenSessionParams.setSlotDurationRstu → UCI tag 0x08` is
 * passthrough; see `docs/agents/research/2026-05-06-android-ranging-cross-os-path.md`
 * §C for the verified end-to-end trace.
 *
 * Apple's NI Accessory protocol uses Static STS — the bytes that look
 * like a session key in `AppleUWBConfigData` are vendor-specific
 * material (vendor id 0x0807 ‖ 6-byte STS IV), not a Provisioned-STS
 * sessionKeyInfo, and passing them through `setSessionKeyInfo` causes
 * the system service to configure the session as Static-STS DS-TWR.
 */
@RequiresApi(36)
class AndroidControleeStrategyRanging(
    initialDeviceId: String,
    appContext: Context,
    private val ble: BleOob,
    private val flutterApi: UwbFlutterApi,
    private val rangingScope: CoroutineScope,
) : AccessoryControleeStrategy {

    /**
     * iOS centrals connect using a random resolvable private address
     * that may not match the MAC the user originally tapped. The host
     * calls [retarget] when the inbound Apple-host write arrives so
     * subsequent `accessoryNotify` calls go back to the right central.
     */
    override var deviceId: String = initialDeviceId
        private set

    override fun retarget(newDeviceId: String) {
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

    private val rangingManager: RangingManager =
        appContext.getSystemService(RangingManager::class.java)
            ?: error("RangingManager unavailable — caller should have gated on rangingApiAvailable()")

    private val sessionExecutor = Executors.newSingleThreadExecutor()

    private var state: State = State.Idle
    private var session: RangingSession? = null
    private var cancellationSignal: CancellationSignal? = null

    /** Locally-generated 2-byte short address. Same value goes into the
     *  AccessoryConfigurationData reply (so the iPhone uses it as our
     *  identity) and into UwbRangingParams.deviceAddress. */
    private var localShortAddress: UwbAddress? = null

    override suspend fun start() {
        // Pre-generate our short address so the value spliced into the
        // AccessoryConfigurationData reply matches what we later pass
        // as deviceAddress in UwbRangingParams.
        localShortAddress = UwbAddress.createRandomShortAddress()
        state = State.AwaitingInitialize
    }

    override fun stop() {
        val wasActive = state != State.Idle && state != State.Stopping
        state = State.Stopping
        try { cancellationSignal?.cancel() } catch (_: Throwable) {}
        try { session?.close() } catch (_: Throwable) {}
        session = null
        cancellationSignal = null
        if (wasActive) {
            // Best-effort Stop notification to the host.
            try {
                ble.accessoryNotify(
                    deviceId = deviceId,
                    bytes = AppleProtocol.encodeIdOnly(AppleProtocol.MessageId.Stop),
                )
            } catch (_: Throwable) {}
        }
        state = State.Idle
    }

    override suspend fun handleAccessoryRequest(bytes: ByteArray) {
        try {
            handleAccessoryRequestInner(bytes)
        } catch (t: Throwable) {
            Log.e(tag, "handleAccessoryRequest threw, state=$state", t)
            // handleAccessoryRequest runs in mainScope (UwbHostApiImpl
            // dispatches via mainScope.launch), so this Pigeon call is
            // already on the main thread.
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
        Log.i(
            tag,
            "DIAG ble-rx ts=${SystemClock.elapsedRealtimeNanos()} " +
                "id=$id state=$state len=${payload.size}",
        )
        when (state to id) {
            State.AwaitingInitialize to AppleProtocol.MessageId.Initialize -> {
                replyAccessoryConfigurationData()
                state = State.AwaitingConfigureAndStart
            }
            State.AwaitingConfigureAndStart to AppleProtocol.MessageId.ConfigureAndStart -> {
                Log.i(tag, "iPhone ConfigureAndStart hex=${payload.toHex()}")
                runControleeSession(payload)
                Log.i(
                    tag,
                    "DIAG ble-tx ts=${SystemClock.elapsedRealtimeNanos()} " +
                        "id=AccessoryUwbDidStart",
                )
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
                Log.i(
                    tag,
                    "DIAG ble-tx ts=${SystemClock.elapsedRealtimeNanos()} " +
                        "id=AccessoryUwbDidStop",
                )
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
        val shortAddrBytes = localShortAddress?.addressBytes
            ?: run {
                Log.w(tag, "replyAccessoryConfigurationData: no local short address")
                return
            }
        val data = AppleProtocol.buildAccessoryConfigurationData(
            sessionId = 0,
            channel = 0,
            preambleIndex = 0,
            shortAddress = shortAddrBytes,
        )
        val wire = AppleProtocol.encodeWithPayload(
            AppleProtocol.MessageId.AccessoryConfigurationData,
            data,
        )
        Log.i(tag, "tx AccessoryConfigurationData (${wire.size}B) hex=${wire.toHex()}")
        ble.accessoryNotify(deviceId = deviceId, bytes = wire)
    }

    @SuppressLint("WrongConstant")
    private fun runControleeSession(shareableConfig: ByteArray) {
        val parsed = AppleProtocol.parseAppleUWBConfigData(shareableConfig)
        // Static-STS sessionKeyInfo for FiRa Unicast DS-TWR =
        // vendorId(2B) || stsIv(6B). Apple does not transmit the vendor
        // id; 0x0807 is the value the NXP UWBJetpackExample uses against
        // NXP/Qorvo silicon and what most open-source accessory firmwares
        // default to.
        val sessionKeyInfo = byteArrayOf(0x08, 0x07) + parsed.stsIv
        // Apple sends slot duration in RSTU (1200 RSTU/ms). Convert to
        // ms for setSlotDuration. The system service multiplies back by
        // 1200 in Utils.convertMsToRstu, so 3 ms in → 3600 RSTU on air.
        val slotDurationMs = parsed.slotDurationRstu / 1200
        val deviceAddr = localShortAddress
            ?: UwbAddress.createRandomShortAddress().also { localShortAddress = it }
        val peerAddr = UwbAddress.fromBytes(parsed.peerShortAddress)

        Log.i(
            tag,
            "DIAG session-start ts=${SystemClock.elapsedRealtimeNanos()} " +
                "sessionId=${parsed.sessionId} ch=${parsed.channel} " +
                "preamble=${parsed.preambleIndex} " +
                "peerShort=${parsed.peerShortAddress.toHex()} " +
                "stsIv=${parsed.stsIv.toHex()} " +
                "sessionKeyInfo(8B)=${sessionKeyInfo.toHex()} " +
                "slotDurationRstu=${parsed.slotDurationRstu} " +
                "slotDurationMs=$slotDurationMs " +
                "config=CONFIG_UNICAST_DS_TWR " +
                "updateRate=INFREQUENT " +
                "api=android.ranging",
        )

        val uwbParams = UwbRangingParams.Builder(
            parsed.sessionId,
            UwbRangingParams.CONFIG_UNICAST_DS_TWR,
            deviceAddr,
            peerAddr,
        )
            .setComplexChannel(
                UwbComplexChannel.Builder()
                    .setChannel(parsed.channel)
                    .setPreambleIndex(parsed.preambleIndex)
                    .build(),
            )
            .setSessionKeyInfo(sessionKeyInfo)
            // RangingUpdateRate maps to a fixed RANGING_DURATION_MS at
            // the system service layer (NORMAL=240 unicast, INFREQUENT=
            // 600, FREQUENT=120). With slot_duration=3 ms, NORMAL's
            // 240 ms isn't an integer multiple of the chip's computed
            // block duration → UCI_STATUS_RANGING_DURATION_NOT_SUPPORTED
            // (reasonCode 35) on Galaxy SR250. INFREQUENT (600 ms) has
            // many more divisors, so it's the safer pick when slot != 2.
            // Apple's NI sends ranging_duration=198 ms in
            // AppleUWBConfigData[17..18], but UwbRangingParams.Builder
            // doesn't expose that field — we pick the closest accepted
            // multiple via the update-rate enum.
            .setRangingUpdateRate(RawRangingDevice.UPDATE_RATE_INFREQUENT)
            // setSlotDuration takes ms. The IntDef is lint-only; the
            // arbitrary int passes through the entire stack to UCI tag
            // 0x08. Suppressed at the function level above.
            .setSlotDuration(slotDurationMs)
            .build()

        val rangingDevice = RangingDevice.Builder().build()

        val rawDevice = RawRangingDevice.Builder()
            .setRangingDevice(rangingDevice)
            .setUwbRangingParams(uwbParams)
            .build()

        val rawConfig = RawResponderRangingConfig.Builder()
            .setRawRangingDevice(rawDevice)
            .build()

        val sessionConfig = SessionConfig.Builder()
            .setAngleOfArrivalNeeded(true)
            .build()

        val preference = RangingPreference.Builder(
            RangingPreference.DEVICE_ROLE_RESPONDER,
            rawConfig,
        )
            .setSessionConfig(sessionConfig)
            .build()

        // Callback methods run on `sessionExecutor` (single-thread
        // executor we own). All Pigeon FlutterApi calls require @UiThread,
        // so each one is dispatched through `rangingScope.launch` (=
        // mainScope from UwbHostApiImpl).
        val callback = object : RangingSession.Callback {
            override fun onOpened() {
                val ts = SystemClock.elapsedRealtimeNanos()
                Log.i(tag, "DIAG ranging-onOpened ts=$ts")
            }

            override fun onOpenFailed(reason: Int) {
                Log.w(tag, "DIAG ranging-onOpenFailed reason=$reason")
                rangingScope.launch {
                    flutterApi.onRangingError(
                        deviceId,
                        RangingError(
                            code = UwbErrorCode.SESSIONINITFAILED,
                            message = "ranging session open failed (reason=$reason)",
                        ),
                    ) {}
                }
            }

            override fun onStarted(peer: RangingDevice, technology: Int) {
                Log.i(
                    tag,
                    "DIAG ranging-onStarted ts=${SystemClock.elapsedRealtimeNanos()} " +
                        "tech=$technology",
                )
            }

            override fun onResults(peer: RangingDevice, data: RangingData) {
                val nowNanos = SystemClock.elapsedRealtimeNanos()
                // distance is documented @NonNull in AOSP source but
                // arrives as a Kotlin platform type; treat defensively
                // (matches AndroidControleeStrategy.emitRangingResult
                // which drops null-distance positions).
                val dist = data.distance?.measurement
                val az = data.azimuth?.measurement
                val el = data.elevation?.measurement
                Log.i(
                    tag,
                    "DIAG cb-pos ts=$nowNanos " +
                        "dist=${dist ?: "null"} " +
                        "az=${az ?: "null"} el=${el ?: "null"}",
                )
                if (dist == null) return
                val sample = RangingSample(
                    deviceId = deviceId,
                    distanceMeters = dist,
                    azimuthDegrees = az,
                    elevationDegrees = el,
                    // RangingData.timestampMillis is in an unspecified
                    // clock domain in the public API. Stamp the sample
                    // with our own elapsed-realtime-nanos at delivery
                    // time — same domain the Jetpack-based strategy
                    // returns via pos.elapsedRealtimeNanos.
                    elapsedRealtimeNanos = nowNanos,
                )
                rangingScope.launch { flutterApi.onRangingSample(sample) {} }
            }

            override fun onStopped(peer: RangingDevice, technology: Int) {
                Log.i(
                    tag,
                    "DIAG ranging-onStopped ts=${SystemClock.elapsedRealtimeNanos()} " +
                        "tech=$technology",
                )
                rangingScope.launch { flutterApi.onPeerLost(deviceId) {} }
            }

            override fun onClosed(reason: Int) {
                Log.i(
                    tag,
                    "DIAG ranging-onClosed ts=${SystemClock.elapsedRealtimeNanos()} " +
                        "reason=$reason",
                )
            }
        }

        val newSession = rangingManager.createRangingSession(sessionExecutor, callback)
            ?: run {
                Log.w(tag, "createRangingSession returned null")
                // runControleeSession is invoked from
                // handleAccessoryRequest which runs in mainScope, so
                // direct Pigeon call is fine here.
                flutterApi.onRangingError(
                    deviceId,
                    RangingError(
                        code = UwbErrorCode.SESSIONINITFAILED,
                        message = "createRangingSession returned null",
                    ),
                ) {}
                return
            }
        session = newSession

        // start() is annotated @RequiresPermission(RANGING). If the user
        // denied the permission, this throws SecurityException
        // synchronously rather than via onOpenFailed.
        try {
            cancellationSignal = newSession.start(preference)
        } catch (t: SecurityException) {
            Log.w(tag, "RangingSession.start denied: ${t.message}")
            flutterApi.onRangingError(
                deviceId,
                RangingError(
                    code = UwbErrorCode.SESSIONINITFAILED,
                    message = "RANGING permission denied: ${t.message}",
                ),
            ) {}
            try { newSession.close() } catch (_: Throwable) {}
            session = null
        }
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02X".format(it) }
}
