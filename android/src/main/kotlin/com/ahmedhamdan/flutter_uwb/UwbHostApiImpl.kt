package com.ahmedhamdan.flutter_uwb

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.uwb.UwbControleeSessionScope
import androidx.core.uwb.UwbControllerSessionScope
import androidx.core.uwb.UwbManager
import com.ahmedhamdan.flutter_uwb.oob.BleOob
import com.ahmedhamdan.flutter_uwb.oob.TokenStore
import com.ahmedhamdan.flutter_uwb.strategy.AndroidControleeStrategy
import com.ahmedhamdan.flutter_uwb.strategy.AndroidPeerStrategy
import com.ahmedhamdan.flutter_uwb.strategy.RangingStrategy
import io.flutter.plugin.common.BinaryMessenger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.security.SecureRandom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

/**
 * Android implementation of Pigeon's UwbHostApi.
 *
 * Token wire format (peer-mode, 9 bytes little-endian):
 *   [0]   role (0=controller, 1=controlee)
 *   [1..2] shortAddr (u16)
 *   [3]   channel (u8, controller only)
 *   [4]   preambleIndex (u8, controller only)
 *   [5..8] sessionId (u32, controller only)
 *
 * Ranging is dispatched by `UwbDevice.platform`:
 * - "android" / "ios"      -> [AndroidPeerStrategy] (peer mode)
 * - "accessory"            -> [AndroidControleeStrategy] (Apple-protocol
 *                            controlee role; Android-as-accessory)
 * - "accessory:<vendor>"   -> currently routes to AndroidControleeStrategy.
 *                            Custom vendor adapter pluging is a follow-up.
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
    // not used by strategies
    private var controllerScope: UwbControllerSessionScope? = null
    private var controleeScope: UwbControleeSessionScope? = null
    private var localSessionId: Int = 0

    private var activeStrategy: RangingStrategy? = null

    init {
        ble.setCallback(object : BleOob.Callback {
            override fun onDeviceFound(id: String, name: String) {
                val isNew = !discovered.containsKey(id)
                val device = UwbDevice(id = id, name = name, platform = "android")
                discovered[id] = device
                if (isNew) flutterApi.onDeviceFound(device) {}
            }
            override fun onIncomingRequest(id: String, name: String) {
                Log.d(tag, "Incoming BLE request from $name")
            }
            override fun onConnected(id: String, name: String) {
                Log.d(tag, "BLE tokens exchanged with $name")
            }
            override fun onDisconnected(id: String, name: String) {
                Log.d(tag, "BLE disconnected $name")
                if (discovered.remove(id) != null) {
                    flutterApi.onDeviceLost(id) {}
                }
                val s = activeStrategy
                if (s?.deviceId == id) {
                    s.stop()
                    activeStrategy = null
                }
            }
            override fun onError(msg: String) {
                Log.e(tag, "BLE error: $msg")
            }
            override fun onAccessoryRequest(
                id: String,
                name: String,
                serviceUuid: UUID,
                bytes: ByteArray,
            ) {
                // Surface the iPhone-host as a discovered "accessory:<tag>"
                // device so the app can call startRanging against it.
                val key = serviceUuid.toString().uppercase()
                val tag = registeredProfiles[key]?.vendorTag
                val platform = if (tag != null) "accessory:$tag" else "accessory"
                val isNew = !discovered.containsKey(id)
                val device = UwbDevice(id = id, name = name, platform = platform)
                discovered[id] = device
                if (isNew) flutterApi.onDeviceFound(device) {}

                // Route the bytes to the active controlee strategy if it
                // matches this peer.
                val s = activeStrategy as? AndroidControleeStrategy ?: return
                if (s.deviceId == id) {
                    mainScope.launch { s.handleAccessoryRequest(bytes) }
                }
            }
        })
    }

    // ---------------- BLE OOB ----------------
    override fun startDiscovery(localName: String): VoidResult = try {
        ble.setAccessoryProfiles(bleAccessoryProfiles())
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
    private data class RegisteredProfile(
        val bleProfile: BleOob.AccessoryProfile,
        val vendorTag: String?,
    )
    private val registeredProfiles = LinkedHashMap<String, RegisteredProfile>()

    private fun bleAccessoryProfiles(): List<BleOob.AccessoryProfile> =
        registeredProfiles.values.map { it.bleProfile }

    override fun registerAccessoryProfile(profile: AccessoryProfile): VoidResult {
        val svc = profile.serviceUuid
            ?: return VoidResult(ok = false, error = "serviceUuid required")
        val rx = profile.rxUuid
            ?: return VoidResult(ok = false, error = "rxUuid required")
        val tx = profile.txUuid
            ?: return VoidResult(ok = false, error = "txUuid required")
        val key = svc.uppercase()
        val bleProfile = BleOob.AccessoryProfile(
            serviceUuid = UUID.fromString(svc),
            rxUuid = UUID.fromString(rx),
            txUuid = UUID.fromString(tx),
        )
        registeredProfiles[key] = RegisteredProfile(bleProfile, profile.vendorTag)
        ble.setAccessoryProfiles(bleAccessoryProfiles())
        return VoidResult(ok = true)
    }

    override fun unregisterAccessoryProfile(serviceUuid: String): VoidResult {
        registeredProfiles.remove(serviceUuid.uppercase())
        ble.setAccessoryProfiles(bleAccessoryProfiles())
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
                        localSessionId = SecureRandom().nextInt(Int.MAX_VALUE - 1) + 1
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
        activeStrategy?.stop()
        activeStrategy = null

        val device = discovered[deviceId]
        if (device == null) {
            callback(Result.success(VoidResult(
                ok = false,
                error = "Unknown deviceId $deviceId. Run startDiscovery first.",
            )))
            return
        }

        mainScope.launch {
            try {
                val mgr = uwbManager
                    ?: UwbManager.createInstance(appContext).also { uwbManager = it }
                val strategy = makeStrategy(device, mgr)
                if (strategy == null) {
                    callback(Result.success(VoidResult(
                        ok = false,
                        error = "Cannot range against platform '${device.platform}'",
                    )))
                    return@launch
                }
                activeStrategy = strategy
                strategy.start()
                callback(Result.success(VoidResult(ok = true)))
            } catch (t: Throwable) {
                Log.e(tag, "startRanging failed", t)
                activeStrategy = null
                callback(Result.success(VoidResult(
                    ok = false,
                    error = "startRanging failed",
                )))
            }
        }
    }

    override fun stopRanging(callback: (Result<VoidResult>) -> Unit) {
        try {
            activeStrategy?.stop()
            activeStrategy = null
            callback(Result.success(VoidResult(ok = true)))
        } catch (t: Throwable) {
            callback(Result.success(VoidResult(
                ok = false,
                error = t.message ?: "stopRanging error",
            )))
        }
    }

    private fun makeStrategy(
        device: UwbDevice,
        mgr: UwbManager,
    ): RangingStrategy? {
        val id = device.id ?: return null
        val platform = device.platform ?: "android"
        return when {
            platform == "android" || platform == "ios" -> {
                val token = TokenStore.getPeer(id)
                if (token == null || token.isEmpty()) {
                    throw IllegalStateException(
                        "No peer token for $id. Run exchangeTokens (or acceptRequest) first.",
                    )
                }
                AndroidPeerStrategy(
                    deviceId = id,
                    peerTokenBytes = token,
                    uwbManager = mgr,
                    flutterApi = flutterApi,
                    rangingScope = mainScope,
                )
            }
            platform == "accessory" || platform.startsWith("accessory:") -> {
                AndroidControleeStrategy(
                    deviceId = id,
                    ble = ble,
                    uwbManager = mgr,
                    flutterApi = flutterApi,
                    rangingScope = mainScope,
                )
            }
            else -> null
        }
    }

    fun dispose() {
        try { activeStrategy?.stop() } catch (_: Throwable) {}
        activeStrategy = null
        try { mainScope.cancel() } catch (_: Throwable) {}
        try { ble.stop() } catch (_: Throwable) {}
        discovered.clear()
        registeredProfiles.clear()
        TokenStore.clear()
    }

    // ---------------- Token codec (peer mode, getLocalToken) ----------------
    private object Token {
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
    }
}
