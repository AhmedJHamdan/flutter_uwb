package com.ahmedhamdan.flutter_uwb.strategy

import android.util.Log
import androidx.core.uwb.RangingParameters
import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbClientSessionScope
import androidx.core.uwb.UwbComplexChannel
import androidx.core.uwb.UwbControleeSessionScope
import androidx.core.uwb.UwbControllerSessionScope
import androidx.core.uwb.UwbManager
import androidx.core.uwb.UwbDevice as JetpackUwbDevice
import com.ahmedhamdan.flutter_uwb.RangingSample
import com.ahmedhamdan.flutter_uwb.UwbFlutterApi
import com.ahmedhamdan.flutter_uwb.UwbRole
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/**
 * Android↔Android (and Android↔iOS where iOS speaks the v1 9-byte token)
 * ranging.
 *
 * Token wire format (9 bytes, little-endian, mirror of the v1 contract):
 *   [0]    role (0 = controller, 1 = controlee)
 *   [1..2] shortAddr (u16)
 *   [3]    channel (u8, controller only)
 *   [4]    preambleIndex (u8, controller only)
 *   [5..8] sessionId (u32, controller only)
 *
 * The strategy owns whichever of [controllerScope]/[controleeScope]
 * applies based on the peer's role byte; [stop] cancels the ranging
 * coroutine but leaves the scope cached so subsequent runs against the
 * same UWB stack don't re-acquire.
 */
class AndroidPeerStrategy(
    override val deviceId: String,
    private val peerTokenBytes: ByteArray,
    private val uwbManager: UwbManager,
    private val flutterApi: UwbFlutterApi,
    private val rangingScope: CoroutineScope,
) : RangingStrategy {

    private val tag = "flutter_uwb"

    private var controllerScope: UwbControllerSessionScope? = null
    private var controleeScope: UwbControleeSessionScope? = null
    private var rangingJob: Job? = null
    private var localSessionId: Int = 0

    override suspend fun start() {
        val peer = Token.parse(peerTokenBytes)
        val (scope, params) = buildSessionFor(peer)

        rangingJob?.cancel()
        rangingJob = rangingScope.launch {
            scope.prepareSession(params)
                .onEach { result -> emitRangingResult(result) }
                .catch { t ->
                    Log.e(tag, "ranging flow error", t)
                    flutterApi.onRangingError(
                        deviceId,
                        t.message ?: "ranging error",
                    ) {}
                }
                .collect { /* drained by onEach */ }
        }
    }

    override fun stop() {
        rangingJob?.cancel()
        rangingJob = null
    }

    private suspend fun buildSessionFor(
        peer: Token.Fields,
    ): Pair<UwbClientSessionScope, RangingParameters> = when (peer.role) {
        UwbRole.CONTROLLER -> {
            val scope = controleeScope
                ?: uwbManager.controleeSessionScope().also { controleeScope = it }
            val params = RangingParameters(
                /* uwbConfigType  */ RangingParameters.CONFIG_UNICAST_DS_TWR,
                /* sessionId      */ peer.sessionId,
                /* subSessionId   */ 0,
                /* sessionKeyInfo */ null,
                /* subSessionKey  */ null,
                /* complexChannel */ UwbComplexChannel(
                    peer.channel.toInt(),
                    peer.preambleIndex.toInt(),
                ),
                /* peerDevices    */ listOf(
                    JetpackUwbDevice(UwbAddress(peer.shortAddressBytes())),
                ),
                /* updateRateType */ RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
            )
            scope to params
        }
        UwbRole.CONTROLEE -> {
            val scope = controllerScope
                ?: uwbManager.controllerSessionScope().also { controllerScope = it }
            val params = RangingParameters(
                RangingParameters.CONFIG_UNICAST_DS_TWR,
                if (localSessionId != 0) localSessionId
                else (SecureRandom().nextInt(Int.MAX_VALUE - 1) + 1).also { localSessionId = it },
                0,
                null,
                null,
                scope.uwbComplexChannel,
                listOf(JetpackUwbDevice(UwbAddress(peer.shortAddressBytes()))),
                RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
            )
            scope to params
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

    private object Token {
        data class Fields(
            val role: UwbRole,
            val shortAddr: Short,
            val channel: Byte,
            val preambleIndex: Byte,
            val sessionId: Int,
        ) {
            fun shortAddressBytes(): ByteArray = byteArrayOf(
                (shortAddr.toInt() and 0xFF).toByte(),
                ((shortAddr.toInt() ushr 8) and 0xFF).toByte(),
            )
        }

        fun parse(bytes: ByteArray): Fields {
            require(bytes.size >= 9) { "Token must be ≥9 bytes, got ${bytes.size}" }
            val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val roleRaw = bb.get().toInt() and 0xFF
            val role = UwbRole.ofRaw(roleRaw)
                ?: throw IllegalArgumentException("Unknown role byte: $roleRaw")
            val shortAddr = bb.short
            val channel = bb.get()
            val preambleIndex = bb.get()
            val sessionId = bb.int
            return Fields(role, shortAddr, channel, preambleIndex, sessionId)
        }
    }
}
