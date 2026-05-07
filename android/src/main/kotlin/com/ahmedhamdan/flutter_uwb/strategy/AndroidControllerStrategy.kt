package com.ahmedhamdan.flutter_uwb.strategy

import android.os.SystemClock
import android.util.Log
import androidx.core.uwb.RangingParameters
import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbControllerSessionScope
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
 * Sub-interface for accessory-mode controller strategies — strategies
 * that drive an Apple-FiRa accessory (e.g. a Qorvo DWM3001CDK) from the
 * Android side as the BLE / UWB host. The dispatcher in
 * `UwbHostApiImpl.onAccessoryNotify` casts the active strategy to this
 * type so it can route inbound notify bytes from `BleOob.accessoryConnect`.
 */
interface AccessoryControllerStrategy : RangingStrategy {
    /** Handle an inbound Apple-protocol notify from the accessory. */
    suspend fun handleAccessoryNotify(bytes: ByteArray)
}

/**
 * Android-as-controller against an Apple-FiRa accessory speaking Apple's
 * NI Accessory Protocol over BLE. Mirror of `IosAccessoryStrategy.swift`.
 *
 * ## Pairing flow
 *
 * 1. [start] acquires a [UwbControllerSessionScope] and opens a long-
 *    lived BLE GATT client connection to the accessory via
 *    [BleOob.accessoryConnect]. On subscribe-confirmed it writes
 *    `Initialize` (0x0A) to the accessory's `rxUuid`.
 * 2. Accessory pushes `AccessoryConfigurationData` (0x01) on its
 *    `txUuid`. We extract the accessory's 2-byte short address from the
 *    inner UWBConfigData blob (offsets 17–18, LE).
 * 3. Build an `AppleUWBConfigData` with the controller's session id,
 *    channel, preamble, FiRa params, a fresh STS IV, and our own short
 *    address; write `ConfigureAndStart` (0x0B + AppleUWBConfigData).
 * 4. Accessory pushes `AccessoryUwbDidStart` (0x02). Start the UWB
 *    radio as controller; samples flow through [emitRangingResult].
 * 5. [stop] cancels the session, writes `Stop` (0x0C), and tears down
 *    the BLE link.
 *
 * Slot duration is 2 ms (2400 RSTU) and ranging interval is 240 ms — the
 * values Jetpack picks for `RANGING_UPDATE_RATE_AUTOMATIC` with
 * `CONFIG_UNICAST_DS_TWR` and the Galaxy chip accepts in observed
 * captures. The same numbers are echoed into the AppleUWBConfigData so
 * the accessory configures matching params.
 */
class AndroidControllerStrategy(
    initialDeviceId: String,
    private val ble: BleOob,
    private val uwbManager: UwbManager,
    private val flutterApi: UwbFlutterApi,
    private val rangingScope: CoroutineScope,
) : AccessoryControllerStrategy {

    override var deviceId: String = initialDeviceId
        private set

    private val tag = "flutter_uwb"

    private enum class State {
        Idle,
        AwaitingAccessoryConfig,
        AwaitingDidStart,
        Ranging,
        Stopping,
    }

    private var state: State = State.Idle
    private var controllerScope: UwbControllerSessionScope? = null
    private var rangingJob: Job? = null

    /** FiRa session id, randomly assigned per [start]. */
    private var sessionId: Int = 0
    /** Static-STS initialisation vector, randomly assigned per [start]. */
    private val stsIv = ByteArray(6)
    /** Accessory's short address (MSB-first) parsed from
     *  AccessoryConfigurationData; used as the FiRa peer when we open
     *  the UWB session. */
    private var peerShortAddressMsb: ByteArray? = null

    override suspend fun start() {
        controllerScope = uwbManager.controllerSessionScope()
        sessionId = SecureRandom().nextInt(Int.MAX_VALUE - 1) + 1
        SecureRandom().nextBytes(stsIv)
        state = State.AwaitingAccessoryConfig

        Log.i(
            tag,
            "controller.start id=$deviceId sessionId=$sessionId " +
                "ch=${controllerScope?.uwbComplexChannel?.channel} " +
                "pre=${controllerScope?.uwbComplexChannel?.preambleIndex} " +
                "myAddr=${controllerScope?.localAddress?.address?.toHex()}",
        )

        // BleOob delivers the onReady callback on the BLE binder thread.
        // Hop to rangingScope (main) before touching flutterApi or
        // mutating strategy state.
        ble.accessoryConnect(deviceId) { ready ->
            rangingScope.launch {
                if (!ready) {
                    fail("BLE not ready for $deviceId")
                    return@launch
                }
                try {
                    Log.i(
                        tag,
                        "DIAG ble-tx ts=${SystemClock.elapsedRealtimeNanos()} id=Initialize",
                    )
                    ble.accessoryWrite(
                        deviceId = deviceId,
                        bytes = AppleProtocol.encodeIdOnly(AppleProtocol.MessageId.Initialize),
                    )
                } catch (t: Throwable) {
                    fail("Initialize write failed: ${t.message}")
                }
            }
        }
    }

    override fun stop() {
        val wasActive = state != State.Idle && state != State.Stopping
        state = State.Stopping
        rangingJob?.cancel()
        rangingJob = null
        if (wasActive) {
            try {
                ble.accessoryWrite(
                    deviceId = deviceId,
                    bytes = AppleProtocol.encodeIdOnly(AppleProtocol.MessageId.Stop),
                )
            } catch (_: Throwable) {}
        }
        ble.accessoryDisconnect(deviceId)
        state = State.Idle
    }

    override suspend fun handleAccessoryNotify(bytes: ByteArray) {
        try {
            handleAccessoryNotifyInner(bytes)
        } catch (t: Throwable) {
            Log.e(tag, "handleAccessoryNotify threw, state=$state", t)
            fail("accessory dispatch failed: ${t.message}")
        }
    }

    private suspend fun handleAccessoryNotifyInner(bytes: ByteArray) {
        val id = AppleProtocol.decodeId(bytes)
        val payload = AppleProtocol.decodePayload(bytes)
        Log.i(
            tag,
            "DIAG accessory-rx ts=${SystemClock.elapsedRealtimeNanos()} " +
                "id=$id state=$state len=${payload.size}",
        )
        when (state to id) {
            State.AwaitingAccessoryConfig to AppleProtocol.MessageId.AccessoryConfigurationData -> {
                val peer = parseAccessoryShortAddress(payload) ?: run {
                    fail("AccessoryConfigurationData payload too short: ${payload.size}")
                    return
                }
                peerShortAddressMsb = peer
                writeConfigureAndStart(peer)
                state = State.AwaitingDidStart
            }
            State.AwaitingDidStart to AppleProtocol.MessageId.AccessoryUwbDidStart -> {
                runControllerSession()
                state = State.Ranging
            }
            State.Ranging to AppleProtocol.MessageId.AccessoryUwbDidStop -> {
                Log.i(tag, "accessory reported UwbDidStop for $deviceId")
                flutterApi.onPeerLost(deviceId) {}
            }
            else -> {
                Log.w(tag, "unexpected accessory message id=$id in state=$state")
            }
        }
    }

    /**
     * Pull the accessory's 2-byte short address out of the 37-byte
     * `AccessoryConfigurationData` payload (without the 0x01 message id).
     * Layout:
     * - bytes 0..15  — Apple wrapper (version, length)
     * - bytes 16..36 — inner 21-byte UWBConfigData
     *   - inner offsets 17..18 = short address (LE) =>
     *     payload offsets 33..34 in the stripped payload.
     * Returns the address MSB-first, ready for [UwbAddress].
     */
    private fun parseAccessoryShortAddress(payload: ByteArray): ByteArray? {
        if (payload.size < 35) return null
        return byteArrayOf(payload[34], payload[33])
    }

    private fun writeConfigureAndStart(accessoryShortAddrMsb: ByteArray) {
        val scope = controllerScope ?: run {
            fail("writeConfigureAndStart: no controller scope")
            return
        }
        val controllerAddr = scope.localAddress.address
        val configData = AppleProtocol.buildAppleUWBConfigData(
            sessionId = sessionId,
            channel = scope.uwbComplexChannel.channel,
            preambleIndex = scope.uwbComplexChannel.preambleIndex,
            // FiRa default for CONFIG_UNICAST_DS_TWR.
            slotsPerRound = 6,
            // Jetpack's `slotDurationMillis` IntDef restricts us to {1, 2}.
            // 2400 RSTU = 2 ms; pairs with rangingIntervalMs=240 to give
            // a 12-ms block × 20 rounds layout the Galaxy chip accepts in
            // Galaxy↔Galaxy captures.
            slotDurationRstu = 2400,
            rangingIntervalMs = 240,
            stsIv = stsIv,
            controllerShortAddress = controllerAddr,
        )
        Log.i(
            tag,
            "DIAG ble-tx ts=${SystemClock.elapsedRealtimeNanos()} " +
                "id=ConfigureAndStart configData=${configData.toHex()} " +
                "peerShort=${accessoryShortAddrMsb.toHex()}",
        )
        ble.accessoryWrite(
            deviceId = deviceId,
            bytes = AppleProtocol.encodeWithPayload(
                AppleProtocol.MessageId.ConfigureAndStart,
                configData,
            ),
        )
    }

    private fun runControllerSession() {
        val scope = controllerScope ?: run {
            fail("runControllerSession: no controller scope")
            return
        }
        val peer = peerShortAddressMsb ?: run {
            fail("runControllerSession: missing peer address")
            return
        }
        // Jetpack CONFIG_UNICAST_DS_TWR sessionKeyInfo layout =
        // vendorId(2B, LE) || stsIv(6B). Vendor 0x0807 matches NXP's
        // Qorvo example firmware and the controlee strategy's choice.
        val sessionKeyInfo = byteArrayOf(0x08, 0x07) + stsIv
        val params = RangingParameters(
            uwbConfigType = RangingParameters.CONFIG_UNICAST_DS_TWR,
            sessionId = sessionId,
            subSessionId = 0,
            sessionKeyInfo = sessionKeyInfo,
            subSessionKeyInfo = null,
            complexChannel = scope.uwbComplexChannel,
            peerDevices = listOf(JetpackUwbDevice(UwbAddress(peer))),
            updateRateType = RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
        )
        Log.i(
            tag,
            "DIAG session-start ts=${SystemClock.elapsedRealtimeNanos()} " +
                "sessionId=$sessionId ch=${scope.uwbComplexChannel.channel} " +
                "preamble=${scope.uwbComplexChannel.preambleIndex} " +
                "peerShort=${peer.toHex()} stsIv=${stsIv.toHex()} " +
                "config=CONFIG_UNICAST_DS_TWR updateRate=AUTOMATIC role=controller",
        )
        rangingJob?.cancel()
        rangingJob = rangingScope.launch {
            scope.prepareSession(params)
                .onEach { result -> emitRangingResult(result) }
                .catch { t ->
                    Log.e(tag, "controller ranging flow error", t)
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
        flutterApi.onRangingError(
            deviceId,
            RangingError(
                code = UwbErrorCode.SESSIONINITFAILED,
                message = message,
            ),
        ) {}
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02X".format(it) }
}
