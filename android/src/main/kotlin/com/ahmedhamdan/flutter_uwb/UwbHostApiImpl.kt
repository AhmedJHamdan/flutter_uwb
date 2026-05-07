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
import com.ahmedhamdan.flutter_uwb.strategy.AccessoryControleeStrategy
import com.ahmedhamdan.flutter_uwb.strategy.AndroidControleeStrategy
import com.ahmedhamdan.flutter_uwb.strategy.AndroidControleeStrategyRanging
import com.ahmedhamdan.flutter_uwb.strategy.AndroidPeerStrategy
import com.ahmedhamdan.flutter_uwb.strategy.DartDrivenAccessoryStrategy
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

    /**
     * Whether the Android 16+ `android.ranging.*` API is reachable.
     * True iff SDK ≥ 36 AND the runtime exposes a non-null
     * `RangingManager` system service (the underlying mainline module
     * may be absent on some pre-GA Android 16 builds even though the
     * SDK level matches).
     *
     * Cached at construction; the SDK level can't change at runtime
     * and re-querying the system service per call is wasteful.
     */
    private val rangingApiAvailable: Boolean by lazy {
        if (Build.VERSION.SDK_INT < 36) {
            false
        } else try {
            appContext.getSystemService(android.ranging.RangingManager::class.java) != null
        } catch (t: Throwable) {
            Log.w(tag, "RangingManager probe failed: ${t.message}")
            false
        }
    }

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
                val isNew = !discovered.containsKey(id)
                val platform = OobCapability.toAndroidPlatform(capability)
                val device = UwbDevice(id = id, name = name, platform = platform)
                discovered[id] = device
                // BleOob callbacks fire on the BLE scanner / GATT-server
                // executor (binder threads on Android). Pigeon FlutterApi
                // calls require @UiThread; route through mainScope.
                if (isNew) mainScope.launch { flutterApi.onDeviceFound(device) {} }
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
                    mainScope.launch { flutterApi.onDeviceLost(id) {} }
                }
                val s = activeStrategy
                if (s?.deviceId == id) {
                    if (s is DartDrivenAccessoryStrategy) {
                        // Route the drop through the strategy so it can
                        // emit DISCONNECTED to the Dart adapter before
                        // tearing down the FiRa session.
                        mainScope.launch { s.handleDisconnected() }
                    } else {
                        s.stop()
                    }
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
                // device so the app can call startRanging against it. The
                // symmetric SVC means a cross-OS iOS peer that scan
                // already labeled `accessory:ios`; don't downgrade it
                // here.
                val existing = discovered[id]
                val key = serviceUuid.toString().uppercase()
                val vendorTag = registeredProfiles[key]?.vendorTag
                val platform = when {
                    existing?.platform != null
                        && existing.platform!!.startsWith("accessory") ->
                        existing.platform
                    vendorTag != null -> "accessory:$vendorTag"
                    else -> "accessory"
                }
                val isNew = existing == null
                val device = UwbDevice(id = id, name = name, platform = platform)
                discovered[id] = device
                if (isNew) mainScope.launch { flutterApi.onDeviceFound(device) {} }

                // Route the bytes to the active controlee strategy.
                // iOS uses random resolvable private addresses that may
                // not match the MAC the user originally tapped, so we
                // re-target the strategy to whichever central is now
                // driving the Apple-FiRa exchange.
                //
                // The cast targets the AccessoryControleeStrategy
                // sub-interface so both implementations
                // (AndroidControleeStrategy / Jetpack and
                // AndroidControleeStrategyRanging / android.ranging)
                // are dispatched to here.
                val s = activeStrategy as? AccessoryControleeStrategy ?: run {
                    Log.w(this@UwbHostApiImpl.tag, "onAccessoryRequest: no active controlee strategy for $id")
                    return
                }
                Log.i(this@UwbHostApiImpl.tag, "onAccessoryRequest dispatch from=$id strategyId=${s.deviceId}")
                if (s.deviceId != id) {
                    s.retarget(id)
                }
                mainScope.launch { s.handleAccessoryRequest(bytes) }
            }
            override fun onAccessoryAdvertisement(
                id: String,
                name: String,
                serviceUuid: UUID,
            ) {
                val key = serviceUuid.toString().uppercase()
                val vendorTag = registeredProfiles[key]?.vendorTag
                val platform = if (vendorTag != null) {
                    "accessory:$vendorTag"
                } else {
                    "accessory"
                }
                val isNew = !discovered.containsKey(id)
                val device = UwbDevice(id = id, name = name, platform = platform)
                discovered[id] = device
                Log.i(
                    this@UwbHostApiImpl.tag,
                    "accessory advert id=$id svc=$serviceUuid platform=$platform",
                )
                if (isNew) mainScope.launch { flutterApi.onDeviceFound(device) {} }
            }
            override fun onAccessoryNotify(
                id: String,
                serviceUuid: UUID,
                bytes: ByteArray,
            ) {
                val s = activeStrategy as? DartDrivenAccessoryStrategy ?: run {
                    Log.w(
                        this@UwbHostApiImpl.tag,
                        "onAccessoryNotify: no active dart-driven strategy for $id",
                    )
                    return
                }
                if (s.deviceId != id) {
                    Log.w(
                        this@UwbHostApiImpl.tag,
                        "onAccessoryNotify: id=$id mismatch strategyId=${s.deviceId}",
                    )
                    return
                }
                mainScope.launch { s.handleNotify(bytes) }
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
                    sessionKeyInfo = TokenStore.getSessionKey(id),
                )
            }
            platform == "accessory" || platform.startsWith("accessory:") -> {
                // Three accessory paths share the `accessory:*` platform
                // string:
                // - `accessory:ios` / bare `accessory` — an iPhone host
                //   is driving us; we run as controlee, replying to its
                //   Initialize / ConfigureAndStart writes.
                // - `accessory:<vendorTag>` (any other tag) — a Dart
                //   adapter or a built-in fallback owns the BLE-OOB
                //   protocol; we route to [DartDrivenAccessoryStrategy]
                //   which relays bytes to/from Dart and opens the FiRa
                //   session with whatever params the adapter returns.
                val vendorTag = if (platform.startsWith("accessory:")) {
                    platform.removePrefix("accessory:")
                } else {
                    null
                }
                val isControleeMode = vendorTag == null || vendorTag == "ios"
                if (!isControleeMode) {
                    DartDrivenAccessoryStrategy(
                        initialDeviceId = id,
                        vendorTag = vendorTag!!,
                        ble = ble,
                        uwbManager = mgr,
                        flutterApi = flutterApi,
                        rangingScope = mainScope,
                    )
                } else if (rangingApiAvailable) {
                    // Android 16+ path: arbitrary slot duration via
                    // android.ranging.* (no Jetpack {1, 2}-ms gate).
                    // Required for iPhone interop; iPhone NI uses 3 ms.
                    AndroidControleeStrategyRanging(
                        initialDeviceId = id,
                        appContext = appContext,
                        ble = ble,
                        flutterApi = flutterApi,
                        rangingScope = mainScope,
                    )
                } else {
                    // Android 15 and earlier: Jetpack path. Cross-OS
                    // ranging reaches ACTIVE then drops at the iPhone's
                    // FW-generated timeout (slot-duration mismatch).
                    AndroidControleeStrategy(
                        initialDeviceId = id,
                        ble = ble,
                        uwbManager = mgr,
                        flutterApi = flutterApi,
                        rangingScope = mainScope,
                    )
                }
            }
            else -> null
        }
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
            mutableListOf(
                "android.permission.BLUETOOTH_SCAN",
                "android.permission.BLUETOOTH_CONNECT",
                "android.permission.BLUETOOTH_ADVERTISE",
                "android.permission.UWB_RANGING",
            ).apply {
                // Android 16 introduced android.ranging.* and a new unified
                // RANGING permission. Cross-OS controlee path uses it.
                if (Build.VERSION.SDK_INT >= 36) {
                    add("android.permission.RANGING")
                }
            }
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

    // ---------------- Accessory adapter framework ----------------
    //
    // Routes Dart-side `AccessoryAdapter` traffic to the active
    // `DartDrivenAccessoryStrategy`. The Dart side picks the adapter
    // by vendor tag; the native dispatcher just spins up the strategy
    // and relays bytes.

    /**
     * Vendor tags the Dart side has registered an adapter for. Updated
     * by [setRegisteredAdapterTags]. Currently informational only —
     * makeStrategy unconditionally routes `accessory:*` (non-ios) to
     * [DartDrivenAccessoryStrategy], and the Dart `_AdapterRunner`
     * reports a clear error if no adapter is registered for the tag.
     */
    private var dartAdapterVendorTags: Set<String> = emptySet()

    override fun setRegisteredAdapterTags(
        vendorTags: List<String>,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        dartAdapterVendorTags = vendorTags.toSet()
        callback(Result.success(VoidResult(ok = true)))
    }

    /** Returns the active [DartDrivenAccessoryStrategy] iff the
     *  passed [deviceId] matches; otherwise `null`. */
    private fun activeDartAccessory(deviceId: String): DartDrivenAccessoryStrategy? {
        val s = activeStrategy as? DartDrivenAccessoryStrategy ?: return null
        return if (s.deviceId == deviceId) s else null
    }

    override fun beginAccessoryHandshake(
        deviceId: String,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        // Today the strategy's `start()` opens BLE itself when
        // `startRanging` is called; this method is reserved for a
        // future "open the BLE link without a session" flow. Reply
        // ok=true so the Dart side treats the kick-off as a no-op.
        callback(Result.success(VoidResult(ok = true)))
    }

    override fun accessoryProtocolWrite(
        deviceId: String,
        bytes: ByteArray,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        val s = activeDartAccessory(deviceId) ?: run {
            callback(Result.success(VoidResult(
                ok = false,
                error = "accessoryProtocolWrite: no active dart-driven strategy for $deviceId",
            )))
            return
        }
        try {
            s.accessoryProtocolWrite(bytes)
            callback(Result.success(VoidResult(ok = true)))
        } catch (t: Throwable) {
            callback(Result.success(VoidResult(
                ok = false,
                error = t.message ?: "accessoryProtocolWrite failed",
            )))
        }
    }

    override fun completeAccessoryHandshake(
        deviceId: String,
        params: FiraSessionParams,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        val s = activeDartAccessory(deviceId) ?: run {
            callback(Result.success(VoidResult(
                ok = false,
                error = "completeAccessoryHandshake: no active dart-driven strategy for $deviceId",
            )))
            return
        }
        val err = s.completeAccessoryHandshake(params)
        callback(Result.success(
            if (err == null) VoidResult(ok = true)
            else VoidResult(ok = false, error = err),
        ))
    }

    override fun failAccessoryHandshake(
        deviceId: String,
        message: String,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        val s = activeDartAccessory(deviceId) ?: run {
            // No active strategy is fine — just acknowledge.
            callback(Result.success(VoidResult(ok = true)))
            return
        }
        s.failAccessoryHandshake(message)
        callback(Result.success(VoidResult(ok = true)))
    }

    override fun surfaceAccessoryDevice(
        device: UwbDevice,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        val id = device.id
        if (id == null || id.isEmpty()) {
            callback(Result.success(VoidResult(
                ok = false,
                error = "surfaceAccessoryDevice: empty device id",
            )))
            return
        }
        // Add to the dispatcher's discovered map so a subsequent
        // startRanging(deviceId) resolves to this device. The Dart-side
        // `_knownDevices` and `deviceFound` stream are populated
        // separately by the seeder / adapter that called this.
        discovered[id] = device
        callback(Result.success(VoidResult(ok = true)))
    }

    override fun unsurfaceAccessoryDevice(
        deviceId: String,
        callback: (Result<VoidResult>) -> Unit,
    ) {
        discovered.remove(deviceId)
        callback(Result.success(VoidResult(ok = true)))
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
