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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/**
 * Android-as-controller against a *pre-configured* FiRa responder
 * (e.g. a Qorvo DWM3001CDK running CLI firmware that was set up via
 * `RESPF` on its USB CLI).
 *
 * No BLE handshake: both sides agree on session params out-of-band by
 * convention. The Qorvo's short address is hard-pinned, the
 * sessionKeyInfo is hard-pinned (so the operator can paste the
 * matching `-VUPPER=` value into the Qorvo CLI), and the channel +
 * preamble + the local short address are picked by Jetpack — they're
 * logged to the DIAG line so the operator can copy them into the
 * matching `RESPF -CHAN= -PCODE= -PADDR=` invocation.
 *
 * Used to validate that Android↔Qorvo FiRa interop works at the radio
 * level once the OOB protocol mismatch (Apple-private STS in QANI
 * firmware) is removed by reflashing Qorvo with the open CLI image.
 */
class AndroidStaticPairStrategy(
    override val deviceId: String,
    private val uwbManager: UwbManager,
    private val flutterApi: UwbFlutterApi,
    private val rangingScope: CoroutineScope,
) : RangingStrategy {

    private val tag = "flutter_uwb"

    private var controllerScope: UwbControllerSessionScope? = null
    private var rangingJob: Job? = null

    override suspend fun start() {
        val scope = uwbManager.controllerSessionScope()
        controllerScope = scope

        val myAddr = scope.localAddress.address
        val ch = scope.uwbComplexChannel.channel
        val pre = scope.uwbComplexChannel.preambleIndex
        Log.i(
            tag,
            "DIAG static-pair-info ts=${SystemClock.elapsedRealtimeNanos()} " +
                "myAddr=${myAddr.toHex()} ch=$ch pre=$pre " +
                "expected_qorvo_cmd=\"RESPF -CHAN=$ch -PCODE=$pre -ID=$SESSION_ID " +
                "-SLOT=2400 -BLOCK=240 -ROUND=6 -RRU=DSTWR -ADDR=$PEER_SHORT_ADDR_DEC " +
                "-PADDR=0x${myAddr.toHex()} -VUPPER=$VUPPER_HEX_COLON\"",
        )

        val params = RangingParameters(
            uwbConfigType = RangingParameters.CONFIG_UNICAST_DS_TWR,
            sessionId = SESSION_ID,
            subSessionId = 0,
            sessionKeyInfo = SESSION_KEY_INFO,
            subSessionKeyInfo = null,
            complexChannel = scope.uwbComplexChannel,
            peerDevices = listOf(
                JetpackUwbDevice(
                    UwbAddress(byteArrayOf(0x00, PEER_SHORT_ADDR_DEC.toByte())),
                ),
            ),
            updateRateType = RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
        )
        Log.i(
            tag,
            "DIAG session-start ts=${SystemClock.elapsedRealtimeNanos()} " +
                "sessionId=$SESSION_ID ch=$ch pre=$pre " +
                "peerShort=00${"%02X".format(PEER_SHORT_ADDR_DEC)} " +
                "config=CONFIG_UNICAST_DS_TWR updateRate=AUTOMATIC role=controller mode=static-pair",
        )
        rangingJob?.cancel()
        rangingJob = rangingScope.launch {
            scope.prepareSession(params)
                .onEach { result -> emitRangingResult(result) }
                .catch { t ->
                    Log.e(tag, "static-pair ranging flow error", t)
                    fail(t.message ?: "ranging error")
                }
                .collect { /* drained by onEach */ }
        }
    }

    override fun stop() {
        rangingJob?.cancel()
        rangingJob = null
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
                    "DIAG cb-pos ts=$nowTs dist=${dist ?: "null"} az=${az ?: "null"} " +
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
            is RangingResult.RangingResultPeerDisconnected ->
                flutterApi.onPeerLost(deviceId) {}
            is RangingResult.RangingResultInitialized ->
                Log.i(tag, "DIAG cb-init ts=$nowTs for $deviceId")
            is RangingResult.RangingResultFailure -> {
                Log.w(tag, "DIAG cb-failure ts=$nowTs reason=${result.reason} for $deviceId")
                fail("ranging failure (reason=${result.reason})")
            }
        }
    }

    private fun fail(message: String) {
        flutterApi.onRangingError(
            deviceId,
            RangingError(code = UwbErrorCode.SESSIONINITFAILED, message = message),
        ) {}
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02X".format(it) }

    companion object {
        /** FiRa session id; matches Qorvo CLI default `-ID=42`. */
        const val SESSION_ID: Int = 42

        /**
         * Qorvo's hard-pinned short address. Matches `-ADDR=1` on the
         * Qorvo CLI; UwbAddress takes bytes MSB-first so the wire is
         * `0x00 0x01`.
         */
        const val PEER_SHORT_ADDR_DEC: Int = 0x01

        /**
         * 8-byte FiRa Static-STS sessionKeyInfo. Layout =
         * `vendorId(2B) || stsIv(6B)`. Mirrors the Qorvo CLI's
         * `-VUPPER=08:07:00:11:22:33:44:55` so the STS scrambling
         * derivation matches on both ends.
         */
        val SESSION_KEY_INFO: ByteArray = byteArrayOf(
            0x08, 0x07, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        )

        const val VUPPER_HEX_COLON: String = "08:07:00:11:22:33:44:55"

        /** Synthetic deviceId used by the dispatcher; mirrored in Dart. */
        const val DEVICE_ID: String = "qorvo-static-001"
        const val DEVICE_NAME: String = "Qorvo (static demo)"
        const val DEVICE_PLATFORM: String = "static-pair:qorvo"
    }
}
