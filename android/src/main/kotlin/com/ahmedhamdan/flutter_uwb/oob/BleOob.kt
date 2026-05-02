package com.ahmedhamdan.flutter_uwb.oob

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import java.util.UUID

class BleOob(private val ctx: Context) {

    /** A registered Apple-FiRa accessory profile. Mirror of the iOS struct. */
    data class AccessoryProfile(
        val serviceUuid: UUID,
        val rxUuid: UUID,
        val txUuid: UUID,
    )

    interface Callback {
        fun onDeviceFound(id: String, name: String)
        fun onIncomingRequest(id: String, name: String)
        fun onConnected(id: String, name: String)
        fun onDisconnected(id: String, name: String)
        fun onError(msg: String)
        /**
         * Apple-protocol bytes received on a registered accessory profile's
         * Rx characteristic. The host (UwbHostApiImpl) routes these to the
         * active [AndroidControleeStrategy].
         */
        fun onAccessoryRequest(
            id: String,
            name: String,
            serviceUuid: UUID,
            bytes: ByteArray,
        ) {}
    }
    private var cb: Callback? = null
    fun setCallback(c: Callback) { cb = c }

    private val SVC = UUID.fromString("4f1a9a1c-08d8-4b2e-bc6b-6b1d9f8d7b21")
    private val CHAR_WRITE = UUID.fromString("b2d2a7f9-8c2a-4d7e-a89d-1d3a4e5f6a70")
    private val CHAR_NOTIFY = UUID.fromString("c9a0a82b-0c5a-4b8e-9e2e-5dbe2d08f7c3")
    private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /** Registered accessory profiles; populated by [setAccessoryProfiles]. */
    private var accessoryProfiles: List<AccessoryProfile> = emptyList()
    /** Tx characteristic per profile, populated when the GATT server is up. */
    private val accessoryTxChars = HashMap<UUID, BluetoothGattCharacteristic>()

    private val btMgr by lazy { ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager }
    private val adapter: BluetoothAdapter? get() = btMgr.adapter

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var gattServer: BluetoothGattServer? = null
    private var clientGatt: BluetoothGatt? = null

    /** Centrals that have written to us, keyed by address. */
    private val pendingCentrals = HashMap<String, BluetoothDevice>()
    /** Already-reported scan addresses so we don't spam onDeviceFound. */
    private val seenAdvertisers = HashSet<String>()

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) { cb?.onError("BLE advertise failed: $errorCode") }
    }

    private fun permsOk(): Boolean {
        val needed: Array<String> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return needed.all {
            ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun start(localName: String) {
        val a = adapter
        if (a == null || !a.isEnabled) { cb?.onError("Bluetooth disabled or unavailable"); return }
        if (!permsOk()) { cb?.onError("Bluetooth permissions missing"); return }

        seenAdvertisers.clear()
        pendingCentrals.clear()

        val serverCb = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    cb?.onDisconnected(device.address, deviceNameSafe(device))
                    pendingCentrals.remove(device.address)
                }
            }

            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray,
            ) {
                if (characteristic.uuid == CHAR_WRITE) {
                    // Peer-mode token write.
                    TokenStore.putPeer(device.address, value)
                    pendingCentrals[device.address] = device
                    cb?.onIncomingRequest(device.address, deviceNameSafe(device))
                } else {
                    // Accessory-mode write — match the characteristic to a
                    // registered profile's Rx UUID.
                    val profile = accessoryProfiles.firstOrNull {
                        it.rxUuid == characteristic.uuid
                    }
                    if (profile != null) {
                        pendingCentrals[device.address] = device
                        cb?.onAccessoryRequest(
                            id = device.address,
                            name = deviceNameSafe(device),
                            serviceUuid = profile.serviceUuid,
                            bytes = value,
                        )
                    }
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
            }
        }
        gattServer = btMgr.openGattServer(ctx, serverCb)
        val service = BluetoothGattService(SVC, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply {
            addCharacteristic(BluetoothGattCharacteristic(
                CHAR_WRITE,
                BluetoothGattCharacteristic.PROPERTY_WRITE
                    or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            ))
            addCharacteristic(BluetoothGattCharacteristic(
                CHAR_NOTIFY,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ,
            ).apply {
                addDescriptor(BluetoothGattDescriptor(
                    CCCD,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
                ))
            })
        }
        gattServer?.addService(service)

        // Add accessory-mode services (one per registered profile) so an
        // iPhone-host or Apple-protocol accessory can connect to Android
        // and drive the multi-message exchange against the controlee
        // strategy.
        accessoryTxChars.clear()
        for (profile in accessoryProfiles) {
            val accessoryService = BluetoothGattService(
                profile.serviceUuid,
                BluetoothGattService.SERVICE_TYPE_PRIMARY,
            )
            accessoryService.addCharacteristic(
                BluetoothGattCharacteristic(
                    profile.rxUuid,
                    BluetoothGattCharacteristic.PROPERTY_WRITE
                        or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                    BluetoothGattCharacteristic.PERMISSION_WRITE,
                ),
            )
            val txChar = BluetoothGattCharacteristic(
                profile.txUuid,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ,
            ).apply {
                addDescriptor(
                    BluetoothGattDescriptor(
                        CCCD,
                        BluetoothGattDescriptor.PERMISSION_READ
                            or BluetoothGattDescriptor.PERMISSION_WRITE,
                    ),
                )
            }
            accessoryService.addCharacteristic(txChar)
            accessoryTxChars[profile.serviceUuid] = txChar
            gattServer?.addService(accessoryService)
        }

        advertiser = a.bluetoothLeAdvertiser
        val adData = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .addServiceUuid(ParcelUuid(SVC))
        // Include the first registered accessory profile's UUID in the
        // ad packet. Multi-profile advertising is constrained by the
        // 31-byte ad budget; for now a single profile is enough for the
        // v2 cross-platform path.
        accessoryProfiles.firstOrNull()?.let {
            adData.addServiceUuid(ParcelUuid(it.serviceUuid))
        }
        advertiser?.startAdvertising(
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build(),
            adData.build(),
            advertiseCallback,
        )

        scanner = a.bluetoothLeScanner
        scanner?.startScan(
            listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SVC)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),
            scanCb,
        )
    }

    fun stop() {
        scanner?.stopScan(scanCb)
        scanner = null
        advertiser?.stopAdvertising(advertiseCallback)
        advertiser = null
        clientGatt?.disconnect()
        clientGatt?.close()
        clientGatt = null
        gattServer?.close()
        gattServer = null
        pendingCentrals.clear()
        seenAdvertisers.clear()
        accessoryTxChars.clear()
        TokenStore.clear()
    }

    /**
     * Update the registered accessory profile list. If the GATT server
     * is currently up the change is picked up the next time [start] is
     * called; the host typically calls `stop()` then `start()` after a
     * register/unregister.
     */
    fun setAccessoryProfiles(profiles: List<AccessoryProfile>) {
        accessoryProfiles = profiles
    }

    /**
     * Push notify bytes via a registered accessory profile's Tx
     * characteristic to the central that initiated the exchange.
     *
     * `deviceId` is the BLE address of the central (matches the address
     * surfaced via [Callback.onAccessoryRequest]).
     */
    fun accessoryNotify(deviceId: String, bytes: ByteArray) {
        val device = pendingCentrals[deviceId] ?: return
        // The Tx char is the first registered accessory profile's tx char
        // — multi-profile fan-out lives in a follow-up.
        val tx = accessoryTxChars.values.firstOrNull() ?: return
        notify(device, tx, bytes)
    }

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, res: ScanResult) {
            val d = res.device ?: return
            val addr = d.address ?: return
            if (!seenAdvertisers.add(addr)) return
            cb?.onDeviceFound(addr, deviceNameSafe(d))
        }

        override fun onScanFailed(errorCode: Int) {
            cb?.onError("BLE scan failed: $errorCode")
        }
    }

    fun accept(deviceId: String, myToken: ByteArray) {
        val d = pendingCentrals[deviceId] ?: return
        val ch = gattServer?.getService(SVC)?.getCharacteristic(CHAR_NOTIFY) ?: return
        notify(d, ch, myToken)
        cb?.onConnected(d.address, deviceNameSafe(d))
    }

    fun decline(deviceId: String) {
        val d = pendingCentrals[deviceId] ?: return
        gattServer?.cancelConnection(d)
        pendingCentrals.remove(deviceId)
    }

    fun exchange(
        deviceId: String,
        myToken: ByteArray,
        onPeer: (ByteArray) -> Unit,
        onErr: (String) -> Unit,
    ) {
        val a = adapter
        if (a == null || !BluetoothAdapter.checkBluetoothAddress(deviceId)) {
            onErr("Invalid device id: $deviceId")
            return
        }
        val dev = a.getRemoteDevice(deviceId)
        clientGatt = dev.connectGatt(ctx, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    cb?.onDisconnected(dev.address, deviceNameSafe(dev))
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val svc = gatt.getService(SVC) ?: return onErr("Service not found")
                val notifyChar = svc.getCharacteristic(CHAR_NOTIFY)
                    ?: return onErr("Notify char not found")
                val writeChar = svc.getCharacteristic(CHAR_WRITE)
                    ?: return onErr("Write char not found")
                gatt.setCharacteristicNotification(notifyChar, true)
                val ccc = notifyChar.getDescriptor(CCCD)
                if (ccc != null) {
                    ccc.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    gatt.writeDescriptor(ccc)
                }
                writeChar.value = myToken
                gatt.writeCharacteristic(writeChar)
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (characteristic.uuid == CHAR_NOTIFY) {
                    onPeer(characteristic.value)
                    cb?.onConnected(dev.address, deviceNameSafe(dev))
                    gatt.disconnect()
                }
            }
        })
    }

    private fun notify(d: BluetoothDevice, ch: BluetoothGattCharacteristic, value: ByteArray) {
        val server = gattServer ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notifyApi33(server, d, ch, value)
        } else {
            @Suppress("DEPRECATION")
            ch.value = value
            @Suppress("DEPRECATION")
            server.notifyCharacteristicChanged(d, ch, false)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun notifyApi33(
        server: BluetoothGattServer,
        d: BluetoothDevice,
        ch: BluetoothGattCharacteristic,
        value: ByteArray,
    ) {
        val rc = server.notifyCharacteristicChanged(d, ch, false, value)
        if (rc != BluetoothStatusCodes.SUCCESS) {
            cb?.onError("notifyCharacteristicChanged failed: $rc")
        }
    }

    private fun deviceNameSafe(d: BluetoothDevice): String = try {
        d.name ?: "BLE Device"
    } catch (_: SecurityException) {
        "BLE Device"
    }
}
