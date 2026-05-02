package com.ahmedhamdan.flutter_uwb

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
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
import com.ahmedhamdan.flutter_uwb.oob.BleOob
import com.ahmedhamdan.flutter_uwb.oob.TokenStore
import io.flutter.plugin.common.BinaryMessenger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

/**
 * Android implementation of Pigeon's UwbHostApi.
 *
 * Token wire format (9 bytes, little-endian):
 *   [0]   role (0=controller, 1=controlee)
 *   [1..2] shortAddr (u16)
 *   [3]   channel (u8, controller only)
 *   [4]   preambleIndex (u8, controller only)
 *   [5..8] sessionId (u32, controller only)
 */
class UwbHostApiImpl(
    private val appContext: Context,
    messenger: BinaryMessenger,
) : UwbHostApi {

    private val tag = "flutter_uwb"
    private val flutterApi = UwbFlutterApi(messenger)
    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val ble = BleOob(appContext)
    private val discovered = LinkedHashMap<String, UwbDevice>()

    private var uwbManager: UwbManager? = null
    private var controllerScope: UwbControllerSessionScope? = null
    private var controleeScope: UwbControleeSessionScope? = null
    private var localSessionId: Int = 0
    private var rangingJob: Job? = null

    init {
        ble.setCallback(object : BleOob.Callback {
            override fun onDeviceFound(id: String, name: String) {
                val isNew = !discovered.containsKey(id)
                val device = UwbDevice(id = id, name = name, platform = "android")
                discovered[id] = device
                if (isNew) flutterApi.onDeviceFound(device) {}
            }
            override fun onIncomingRequest(id: String, name: String) {
                Log.d(tag, "Incoming BLE request from $name ($id)")
            }
            override fun onConnected(id: String, name: String) {
                Log.d(tag, "BLE tokens exchanged with $name ($id)")
            }
            override fun onDisconnected(id: String, name: String) {
                Log.d(tag, "BLE disconnected $name ($id)")
                if (discovered.remove(id) != null) {
                    flutterApi.onDeviceLost(id) {}
                }
            }
            override fun onError(msg: String) {
                Log.e(tag, "BLE error: $msg")
            }
        })
    }

    // ---------------- BLE OOB ----------------
    override fun startDiscovery(localName: String): VoidResult = try {
        ble.start(localName)
        VoidResult(ok = true)
    } catch (t: Throwable) {
        Log.e(tag, "startDiscovery", t)
        VoidResult(ok = false, error = t.message ?: "startDiscovery error")
    }

    override fun stopDiscovery(): VoidResult = try {
        ble.stop()
        discovered.clear()
        TokenStore.clear()
        VoidResult(ok = true)
    } catch (t: Throwable) {
        Log.e(tag, "stopDiscovery", t)
        VoidResult(ok = false, error = t.message ?: "stopDiscovery error")
    }

    override fun getDiscovered(): List<UwbDevice> = discovered.values.toList()

    override fun acceptRequest(deviceId: String, myToken: TokenPayload): VoidResult = try {
        ble.accept(deviceId, myToken.bytes ?: ByteArray(0))
        VoidResult(ok = true)
    } catch (t: Throwable) {
        Log.e(tag, "acceptRequest", t)
        VoidResult(ok = false, error = t.message ?: "acceptRequest error")
    }

    override fun declineRequest(deviceId: String): VoidResult = try {
        ble.decline(deviceId)
        VoidResult(ok = true)
    } catch (t: Throwable) {
        Log.e(tag, "declineRequest", t)
        VoidResult(ok = false, error = t.message ?: "declineRequest error")
    }

    // ---------------- Accessory profile registration ----------------
    // Stash registrations so the Phase D Android-side controlee strategy
    // can consume them. The Android BLE-OOB plumbing for accessory mode
    // is hardware-gated; for now this is store-only.
    private val registeredProfiles = LinkedHashMap<String, AccessoryProfile>()

    override fun registerAccessoryProfile(profile: AccessoryProfile): VoidResult {
        val svc = profile.serviceUuid
            ?: return VoidResult(ok = false, error = "serviceUuid required")
        if (profile.rxUuid == null || profile.txUuid == null) {
            return VoidResult(ok = false, error = "rxUuid and txUuid required")
        }
        registeredProfiles[svc.uppercase()] = profile
        return VoidResult(ok = true)
    }

    override fun unregisterAccessoryProfile(serviceUuid: String): VoidResult {
        registeredProfiles.remove(serviceUuid.uppercase())
        return VoidResult(ok = true)
    }

    override fun exchangeTokens(
        deviceId: String,
        myToken: TokenPayload,
        callback: (Result<TokenPayload>) -> Unit,
    ) {
        val my = myToken.bytes ?: ByteArray(0)
        var settled = false
        try {
            ble.exchange(
                deviceId,
                myToken = my,
                onPeer = { bytes ->
                    if (settled) return@exchange
                    settled = true
                    TokenStore.putPeer(deviceId, bytes)
                    callback(Result.success(TokenPayload(bytes = bytes)))
                },
                onErr = { msg ->
                    if (settled) return@exchange
                    settled = true
                    callback(Result.failure(RuntimeException(msg)))
                },
            )
        } catch (t: Throwable) {
            if (!settled) {
                settled = true
                callback(Result.failure(t))
            }
        }
    }

    // ---------------- UWB ----------------
    override fun isUwbAvailable(callback: (Result<Boolean>) -> Unit) {
        // Emulators advertise FEATURE_UWB and even let `controleeSessionScope`
        // succeed, but actual ranging fails. Reject up-front so callers can
        // hide UWB UI on simulators, parallel to iOS `targetEnvironment(simulator)`.
        if (isEmulator()) {
            callback(Result.success(false))
            return
        }
        val pm = appContext.packageManager
        if (!pm.hasSystemFeature(PackageManager.FEATURE_UWB)) {
            callback(Result.success(false))
            return
        }
        mainScope.launch {
            val ok = try {
                val mgr = uwbManager ?: UwbManager.createInstance(appContext).also { uwbManager = it }
                // controleeSessionScope is the lighter-weight probe.
                mgr.controleeSessionScope()
                true
            } catch (t: Throwable) {
                Log.w(tag, "UWB probe failed: ${t.message}")
                false
            }
            callback(Result.success(ok))
        }
    }

    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.startsWith("unknown") ||
            Build.MODEL.contains("google_sdk") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for") ||
            Build.MANUFACTURER.contains("Genymotion") ||
            (Build.BRAND.startsWith("generic") && Build.DEVICE.startsWith("generic")) ||
            Build.PRODUCT == "google_sdk" ||
            Build.PRODUCT.startsWith("sdk_gphone") ||
            Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish"

    override fun getLocalToken(role: UwbRole, callback: (Result<TokenPayload>) -> Unit) {
        mainScope.launch {
            try {
                val mgr = uwbManager ?: UwbManager.createInstance(appContext).also { uwbManager = it }
                val bytes = when (role) {
                    UwbRole.CONTROLLER -> {
                        val scope = mgr.controllerSessionScope()
                        controllerScope = scope
                        localSessionId = Random.nextInt(1, Int.MAX_VALUE)
                        Token.build(
                            role = UwbRole.CONTROLLER,
                            addr = scope.localAddress.address,
                            channel = scope.uwbComplexChannel.channel.toByte(),
                            preambleIndex = scope.uwbComplexChannel.preambleIndex.toByte(),
                            sessionId = localSessionId,
                        )
                    }
                    UwbRole.CONTROLEE -> {
                        val scope = mgr.controleeSessionScope()
                        controleeScope = scope
                        Token.build(
                            role = UwbRole.CONTROLEE,
                            addr = scope.localAddress.address,
                            channel = 0,
                            preambleIndex = 0,
                            sessionId = 0,
                        )
                    }
                }
                callback(Result.success(TokenPayload(bytes = bytes)))
            } catch (t: Throwable) {
                Log.e(tag, "getLocalToken failed", t)
                callback(Result.failure(t))
            }
        }
    }

    override fun startRanging(deviceId: String, callback: (Result<VoidResult>) -> Unit) {
        val peerToken = TokenStore.getPeer(deviceId)
        if (peerToken == null || peerToken.isEmpty()) {
            callback(Result.success(VoidResult(
                ok = false,
                error = "No peer token for $deviceId. Run exchangeTokens first.",
            )))
            return
        }
        val peer = try {
            Token.parse(peerToken)
        } catch (t: Throwable) {
            callback(Result.success(VoidResult(ok = false, error = "Invalid peer token: ${t.message}")))
            return
        }

        mainScope.launch {
            try {
                val mgr = uwbManager ?: UwbManager.createInstance(appContext).also { uwbManager = it }
                val (scope, params) = buildSessionFor(peer, mgr)

                rangingJob?.cancel()
                rangingJob = mainScope.launch {
                    scope.prepareSession(params)
                        .onEach { result -> emitRangingResult(deviceId, result) }
                        .catch { t ->
                            Log.e(tag, "ranging flow error", t)
                            flutterApi.onRangingError(deviceId, t.message ?: "ranging error") {}
                        }
                        .collect { /* drained by onEach */ }
                }
                callback(Result.success(VoidResult(ok = true)))
            } catch (t: Throwable) {
                Log.e(tag, "startRanging failed", t)
                callback(Result.success(VoidResult(ok = false, error = t.message ?: "startRanging error")))
            }
        }
    }

    override fun stopRanging(callback: (Result<VoidResult>) -> Unit) {
        try {
            rangingJob?.cancel()
            rangingJob = null
            callback(Result.success(VoidResult(ok = true)))
        } catch (t: Throwable) {
            callback(Result.success(VoidResult(ok = false, error = t.message ?: "stopRanging error")))
        }
    }

    private suspend fun buildSessionFor(
        peer: Token.Fields,
        mgr: UwbManager,
    ): Pair<UwbClientSessionScope, RangingParameters> = when (peer.role) {
        UwbRole.CONTROLLER -> {
            // Peer is controller → I am controlee. Use peer's channel/sessionId.
            val scope = controleeScope ?: mgr.controleeSessionScope().also { controleeScope = it }
            val params = RangingParameters(
                /* uwbConfigType  */ RangingParameters.CONFIG_UNICAST_DS_TWR,
                /* sessionId      */ peer.sessionId,
                /* subSessionId   */ 0,
                /* sessionKeyInfo */ null,
                /* subSessionKey  */ null,
                /* complexChannel */ UwbComplexChannel(peer.channel.toInt(), peer.preambleIndex.toInt()),
                /* peerDevices    */ listOf(JetpackUwbDevice(UwbAddress(peer.shortAddressBytes()))),
                /* updateRateType */ RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
            )
            scope to params
        }
        UwbRole.CONTROLEE -> {
            // Peer is controlee → I am controller. Use my channel/sessionId.
            val scope = controllerScope ?: mgr.controllerSessionScope().also { controllerScope = it }
            val params = RangingParameters(
                RangingParameters.CONFIG_UNICAST_DS_TWR,
                if (localSessionId != 0) localSessionId else Random.nextInt(1, Int.MAX_VALUE).also { localSessionId = it },
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

    private fun emitRangingResult(deviceId: String, result: RangingResult) {
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

    fun dispose() {
        try { rangingJob?.cancel() } catch (_: Throwable) {}
        try { mainScope.cancel() } catch (_: Throwable) {}
        try { ble.stop() } catch (_: Throwable) {}
        discovered.clear()
        TokenStore.clear()
    }

    // ---------------- Token codec ----------------
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

        fun build(
            role: UwbRole,
            addr: ByteArray,
            channel: Byte,
            preambleIndex: Byte,
            sessionId: Int,
        ): ByteArray {
            require(addr.size >= 2) { "UWB address must be ≥2 bytes, got ${addr.size}" }
            val bb = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
            bb.put(role.raw.toByte())
            // shortAddr is little-endian: byte[0]=lsb, byte[1]=msb
            bb.put(addr[0])
            bb.put(addr[1])
            bb.put(channel)
            bb.put(preambleIndex)
            bb.putInt(sessionId)
            return bb.array()
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
