package com.ahmedhamdan.flutter_uwb

import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.uwb.UwbAvailabilityCallback
import androidx.core.uwb.UwbControleeSessionScope
import androidx.core.uwb.UwbControllerSessionScope
import androidx.core.uwb.UwbManager
import java.util.concurrent.Executors
import com.ahmedhamdan.flutter_uwb.oob.BleOob
import com.ahmedhamdan.flutter_uwb.oob.OobCapability
import com.ahmedhamdan.flutter_uwb.oob.TokenStore
import com.ahmedhamdan.flutter_uwb.strategy.AndroidPeerStrategy
import com.ahmedhamdan.flutter_uwb.strategy.RangingStrategy
import io.flutter.plugin.common.BinaryMessenger
import java.nio.ByteBuffer
import java.nio.ByteOrder
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
 * - "android"  -> [AndroidPeerStrategy] (peer mode against another
 *                 Android phone running flutter_uwb)
 *
 * Accessory mode (`registerAccessoryProfile`) is iOS-only — Android
 * returns an error if the host app calls it on this platform.
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

    private var activeStrategy: RangingStrategy? = null

    /**
     * Cached UWB availability, fed by [UwbAvailabilityCallback]. Surfaced
     * to Dart through the session-state stream.
     */
    @Volatile private var lastKnownUwbAvailable: Boolean? = null
    private val availabilityExecutor = Executors.newSingleThreadExecutor()
    private val availabilityCallback = object : UwbAvailabilityCallback {
        override fun onUwbStateChanged(isUwbAvailable: Boolean, reason: Int) {
            lastKnownUwbAvailable = isUwbAvailable
            Log.i(tag, "UWB availability=$isUwbAvailable reasonCode=$reason")
        }
    }
    private var availabilityCallbackInstalled = false

    init {
        ble.setCallback(object : BleOob.Callback {
            override fun onDeviceFound(id: String, name: String, capability: Byte) {
                // Only surface Android peers — flutter_uwb 1.0.0 does not
                // range cross-OS, so iOS peers spotted on the symmetric
                // service are dropped at the discovery layer rather than
                // shown as "discoverable" only to fail at startRanging.
                if (capability == OobCapability.IOS_PEER) return
                val isNew = !discovered.containsKey(id)
                val platform = OobCapability.toAndroidPlatform(capability)
                val device = UwbDevice(id = id, name = name, platform = platform)
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
    // Apple-FiRa accessory mode is an iOS-only feature in flutter_uwb
    // 1.0.0. Both register / unregister return a structured error here so
    // host apps can branch on `Platform.isIOS` cleanly.

    override fun registerAccessoryProfile(profile: AccessoryProfile): VoidResult =
        VoidResult(
            ok = false,
            error = "registerAccessoryProfile is iOS-only in flutter_uwb 1.0.0",
        )

    override fun unregisterAccessoryProfile(serviceUuid: String): VoidResult =
        VoidResult(
            ok = false,
            error = "unregisterAccessoryProfile is iOS-only in flutter_uwb 1.0.0",
        )

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
                installAvailabilityCallbackOnce(mgr)
                mgr.isAvailable()
            } catch (t: Throwable) {
                Log.w(tag, "UWB probe failed: ${t.message}")
                false
            }
            lastKnownUwbAvailable = ok
            callback(Result.success(ok))
        }
    }

    private fun installAvailabilityCallbackOnce(mgr: UwbManager) {
        if (availabilityCallbackInstalled) return
        try {
            mgr.setUwbAvailabilityCallback(availabilityExecutor, availabilityCallback)
            availabilityCallbackInstalled = true
        } catch (t: Throwable) {
            Log.w(tag, "setUwbAvailabilityCallback failed: ${t.message}")
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

    override fun startRanging(
        deviceId: String,
        options: RangingOptions,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        // `options` (cameraAssist / extendedDistance) is wired through on
        // iOS. Both flags are no-ops on Android.
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
        if (platform != "android") return null
        val token = TokenStore.getPeer(id)
        if (token == null || token.isEmpty()) {
            throw IllegalStateException(
                "No peer token for $id. Run exchangeTokens (or acceptRequest) first.",
            )
        }
        return AndroidPeerStrategy(
            deviceId = id,
            peerTokenBytes = token,
            uwbManager = mgr,
            flutterApi = flutterApi,
            rangingScope = mainScope,
            sessionKeyInfo = TokenStore.getSessionKey(id),
        )
    }

    override fun getDeviceCapabilities(
        callback: (Result<DeviceCapabilities>) -> Unit,
    ) {
        mainScope.launch {
            try {
                val mgr = uwbManager
                    ?: UwbManager.createInstance(appContext).also { uwbManager = it }
                val scope = controllerScope
                    ?: mgr.controllerSessionScope().also { controllerScope = it }
                val caps = scope.rangingCapabilities
                callback(
                    Result.success(
                        DeviceCapabilities(
                            supportsPreciseDistance = caps.isDistanceSupported,
                            supportsDirection =
                                caps.isAzimuthalAngleSupported || caps.isElevationAngleSupported,
                            // iOS-only flags stay false on Android.
                            supportsCameraAssist = false,
                            supportsExtendedDistance = false,
                            supportedChannels = caps.supportedChannels.map { it.toLong() },
                            supportedConfigIds = caps.supportedConfigIds.map { it.toLong() },
                            minRangingIntervalMs = caps.minRangingInterval.toLong(),
                            supportsAoa = caps.isAzimuthalAngleSupported,
                        ),
                    ),
                )
            } catch (t: Throwable) {
                Log.w(tag, "getDeviceCapabilities failed", t)
                // Conservative fallback when the radio isn't available
                // (emulator, no UWB feature, permission denied).
                callback(
                    Result.success(
                        DeviceCapabilities(
                            supportsPreciseDistance = false,
                            supportsDirection = false,
                            supportsCameraAssist = false,
                            supportsExtendedDistance = false,
                            supportedChannels = emptyList(),
                            supportedConfigIds = emptyList(),
                            minRangingIntervalMs = null,
                            supportsAoa = false,
                        ),
                    ),
                )
            }
        }
    }

    override fun checkReadiness(callback: (Result<UwbReadiness>) -> Unit) {
        mainScope.launch {
            val missing = collectMissingPermissions()
            val bt = isBluetoothEnabled()
            val uwb = probeUwbAvailable()
            callback(
                Result.success(
                    UwbReadiness(
                        uwbAvailable = uwb,
                        bluetoothEnabled = bt,
                        permissionsGranted = missing.isEmpty(),
                        missingPermissions = missing,
                    ),
                ),
            )
        }
    }

    /**
     * Permissions the plugin's BLE OOB transport and UWB ranging code
     * actually call into at runtime. Mirrors what the plugin's manifest
     * declares, scoped to the current API level.
     */
    private fun collectMissingPermissions(): List<String> {
        val needed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                "android.permission.BLUETOOTH_SCAN",
                "android.permission.BLUETOOTH_CONNECT",
                "android.permission.BLUETOOTH_ADVERTISE",
                "android.permission.UWB_RANGING",
            )
        } else {
            listOf(
                "android.permission.BLUETOOTH",
                "android.permission.BLUETOOTH_ADMIN",
                "android.permission.ACCESS_FINE_LOCATION",
            )
        }
        return needed.filter {
            ContextCompat.checkSelfPermission(appContext, it) !=
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun isBluetoothEnabled(): Boolean {
        val mgr = appContext.getSystemService(Context.BLUETOOTH_SERVICE)
            as? BluetoothManager ?: return false
        return try {
            mgr.adapter?.isEnabled == true
        } catch (_: SecurityException) {
            // Pre-API-31 reads need BLUETOOTH; post-31 needs BLUETOOTH_CONNECT.
            // If neither is granted, we report bluetooth as not enabled rather
            // than crashing — the missingPermissions list covers the real fix.
            false
        }
    }

    private suspend fun probeUwbAvailable(): Boolean {
        if (isEmulator()) return false
        if (!appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_UWB)) {
            return false
        }
        return try {
            val mgr = uwbManager
                ?: UwbManager.createInstance(appContext).also { uwbManager = it }
            installAvailabilityCallbackOnce(mgr)
            mgr.isAvailable().also { lastKnownUwbAvailable = it }
        } catch (t: Throwable) {
            Log.w(tag, "UWB probe failed: ${t.message}")
            false
        }
    }

    fun dispose() {
        try { activeStrategy?.stop() } catch (_: Throwable) {}
        activeStrategy = null
        try { mainScope.cancel() } catch (_: Throwable) {}
        try { ble.stop() } catch (_: Throwable) {}
        if (availabilityCallbackInstalled) {
            try { uwbManager?.clearUwbAvailabilityCallback() } catch (_: Throwable) {}
            availabilityCallbackInstalled = false
        }
        try { availabilityExecutor.shutdownNow() } catch (_: Throwable) {}
        discovered.clear()
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
