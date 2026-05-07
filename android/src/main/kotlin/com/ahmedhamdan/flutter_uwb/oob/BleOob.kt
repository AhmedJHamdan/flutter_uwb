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
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import java.util.UUID

/**
 * CoreBluetooth-based out-of-band transport for Android↔Android peer
 * mode.
 *
 * The local device both advertises and scans the symmetric service
 * UUID below. Peers exchange UWB tokens via an ECDH-keyed handshake on
 * the GATT server's `CHAR_WRITE` / `CHAR_NOTIFY` pair. Apple-FiRa
 * accessory mode is iOS-only in flutter_uwb 1.0.0; this class no
 * longer participates in cross-OS or vendor-accessory flows.
 */
class BleOob(private val ctx: Context) {

    interface Callback {
        /**
         * @param capability remote peer's [OobCapability] byte. Defaults
         * to [OobCapability.UNKNOWN_DEFAULT] when the advertisement omits
         * service-data (pre-0.4.0 peers).
         */
        fun onDeviceFound(id: String, name: String, capability: Byte)
        fun onIncomingRequest(id: String, name: String)
        fun onConnected(id: String, name: String)
        fun onDisconnected(id: String, name: String)
        fun onError(msg: String)
    }
    private var cb: Callback? = null
    fun setCallback(c: Callback) { cb = c }

    private val SVC = UUID.fromString("4f1a9a1c-08d8-4b2e-bc6b-6b1d9f8d7b21")
    private val CHAR_WRITE = UUID.fromString("b2d2a7f9-8c2a-4d7e-a89d-1d3a4e5f6a70")
    private val CHAR_NOTIFY = UUID.fromString("c9a0a82b-0c5a-4b8e-9e2e-5dbe2d08f7c3")
    private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /** Type byte prefix on the inner (post-reassembly) wire. */
    private companion object {
        const val MSG_HANDSHAKE: Byte = 0x01
        const val MSG_TOKEN: Byte = 0x02
        const val PREFERRED_MTU: Int = 247
        const val DEFAULT_MTU: Int = 23
    }

    private val btMgr by lazy { ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager }
    private val adapter: BluetoothAdapter? get() = btMgr.adapter

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var gattServer: BluetoothGattServer? = null
    private var clientGatt: BluetoothGatt? = null

    private val pendingCentrals = HashMap<String, BluetoothDevice>()
    private val seenAdvertisers = HashSet<String>()

    /** Per-central server-side handshake/key state, keyed by BLE address. */
    private val serverHandshakes = HashMap<String, OobHandshake.LocalKeyPair>()
    private val serverKeys = HashMap<String, OobHandshake.SessionKeys>()
    private val serverReassemblers = HashMap<String, BleFramer.Reassembler>()
    private val serverMtus = HashMap<String, Int>()

    /** Single active client connection state — only one outbound exchange at a time. */
    private var clientLocalPair: OobHandshake.LocalKeyPair? = null
    private var clientKeys: OobHandshake.SessionKeys? = null
    private val clientReassembler = BleFramer.Reassembler()
    private var clientMtu: Int = DEFAULT_MTU
    private var clientDeviceId: String? = null
    private var clientMyToken: ByteArray? = null
    private var clientOnPeer: ((ByteArray) -> Unit)? = null
    private var clientOnErr: ((String) -> Unit)? = null

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            Log.e("flutter_uwb", "BLE advertise failed: $errorCode")
            cb?.onError("BLE advertise failed: $errorCode")
        }
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i("flutter_uwb", "BLE advertise success: $settingsInEffect")
        }
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
        Log.i("flutter_uwb", "BleOob.start name=$localName")
        val a = adapter
        if (a == null || !a.isEnabled) { cb?.onError("Bluetooth disabled or unavailable"); return }
        if (!permsOk()) { cb?.onError("Bluetooth permissions missing"); return }

        seenAdvertisers.clear()
        pendingCentrals.clear()
        serverHandshakes.clear()
        serverKeys.clear()
        serverReassemblers.clear()
        serverMtus.clear()

        val serverCb = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    cb?.onDisconnected(device.address, deviceNameSafe(device))
                    pendingCentrals.remove(device.address)
                    serverHandshakes.remove(device.address)
                    serverKeys.remove(device.address)
                    serverReassemblers.remove(device.address)
                    serverMtus.remove(device.address)
                }
            }

            override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                serverMtus[device.address] = mtu
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
                    Log.i(
                        "flutter_uwb",
                        "onCharWrite from=${device.address} bytes=${
                            value.joinToString("") { "%02X".format(it) }
                        }",
                    )
                    handleServerInbound(device, value)
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
            }

            override fun onDescriptorReadRequest(
                device: BluetoothDevice,
                requestId: Int,
                offset: Int,
                descriptor: BluetoothGattDescriptor,
            ) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                    BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE,
                )
            }

            override fun onDescriptorWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                descriptor: BluetoothGattDescriptor,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray,
            ) {
                // Standard CCCD subscribe — Jetpack-UWB centrals write
                // [0x01, 0x00] to enable notifications. Without an
                // explicit ack the central times out waiting for the
                // response (~30 s) and disconnects.
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null,
                    )
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

        advertiser = a.bluetoothLeAdvertiser
        // Legacy BLE advert is capped at 31 bytes — a 128-bit service
        // UUID alone is 18 B, leaving no room for service-data in the
        // primary packet. Put the capability byte in the scan response
        // so an active scanner gets both packets merged into a single
        // discovery callback.
        val adData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SVC))
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceData(ParcelUuid(SVC), OobCapability.localServiceData())
            .build()
        advertiser?.startAdvertising(
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build(),
            adData,
            scanResponse,
            advertiseCallback,
        )

        scanner = a.bluetoothLeScanner
        Log.i("flutter_uwb", "starting scan for SVC=$SVC")
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
        serverHandshakes.clear()
        serverKeys.clear()
        serverReassemblers.clear()
        serverMtus.clear()
        resetClientState()
        TokenStore.clear()
    }

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, res: ScanResult) {
            val d = res.device ?: return
            val addr = d.address ?: return
            if (!seenAdvertisers.add(addr)) return
            val record = res.scanRecord
            val data = record?.serviceData?.get(ParcelUuid(SVC))
            Log.i("flutter_uwb",
                "scan hit addr=$addr name=${deviceNameSafe(d)} svcData=${
                    data?.joinToString("") { "%02X".format(it) } ?: "nil"
                }")
            // iOS BLE advertisements cannot carry service-data, so an
            // ad on the symmetric service UUID with no service-data is
            // by convention not an Android peer. Surface the byte to
            // the host; the host filters non-Android peers because
            // flutter_uwb 1.0.0 only ranges Android↔Android.
            val capability: Byte = if (data == null || data.isEmpty()) {
                OobCapability.IOS_PEER
            } else {
                data[0]
            }
            cb?.onDeviceFound(addr, deviceNameSafe(d), capability)
        }

        override fun onScanFailed(errorCode: Int) {
            cb?.onError("BLE scan failed: $errorCode")
        }
    }

    /**
     * Server-side acceptor: send our token back over the established
     * handshake channel as an HMAC-wrapped envelope.
     */
    fun accept(deviceId: String, myToken: ByteArray) {
        val d = pendingCentrals[deviceId] ?: return
        val keys = serverKeys[deviceId]
        val ch = gattServer?.getService(SVC)?.getCharacteristic(CHAR_NOTIFY) ?: return
        if (keys == null) {
            cb?.onError("accept: no handshake keys for $deviceId")
            return
        }
        val wrapped = OobHandshake.wrapToken(keys.macKey, myToken)
        notifyTyped(d, ch, MSG_TOKEN, wrapped, mtu = serverMtus[deviceId] ?: DEFAULT_MTU)
        cb?.onConnected(d.address, deviceNameSafe(d))
    }

    fun decline(deviceId: String) {
        val d = pendingCentrals[deviceId] ?: return
        gattServer?.cancelConnection(d)
        pendingCentrals.remove(deviceId)
        serverHandshakes.remove(deviceId)
        serverKeys.remove(deviceId)
        serverReassemblers.remove(deviceId)
        serverMtus.remove(deviceId)
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
        resetClientState()
        clientDeviceId = deviceId
        clientMyToken = myToken
        clientOnPeer = onPeer
        clientOnErr = onErr
        clientLocalPair = OobHandshake.generateKeyPair()

        val dev = a.getRemoteDevice(deviceId)
        clientGatt = dev.connectGatt(ctx, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        // Try to bump the MTU before discovering services so the
                        // 32-byte handshake frame fits in a single ATT write.
                        if (!gatt.requestMtu(PREFERRED_MTU)) {
                            gatt.discoverServices()
                        }
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        cb?.onDisconnected(dev.address, deviceNameSafe(dev))
                        finishClientWithError("BLE disconnected")
                    }
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                clientMtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else DEFAULT_MTU
                gatt.discoverServices()
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val svc = gatt.getService(SVC)
                    ?: return finishClientWithError("Service not found")
                val notifyChar = svc.getCharacteristic(CHAR_NOTIFY)
                    ?: return finishClientWithError("Notify char not found")
                val writeChar = svc.getCharacteristic(CHAR_WRITE)
                    ?: return finishClientWithError("Write char not found")
                gatt.setCharacteristicNotification(notifyChar, true)
                val ccc = notifyChar.getDescriptor(CCCD)
                if (ccc != null) {
                    @Suppress("DEPRECATION")
                    ccc.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(ccc)
                }
                // Send our handshake init frame: [MSG_HANDSHAKE | pubkey].
                val pair = clientLocalPair
                    ?: return finishClientWithError("No local handshake key")
                writeTyped(gatt, writeChar, MSG_HANDSHAKE, pair.publicKey, mtu = clientMtu)
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (characteristic.uuid != CHAR_NOTIFY) return
                @Suppress("DEPRECATION")
                val frame = characteristic.value ?: return
                val assembled = clientReassembler.feed(frame) ?: return
                handleClientAssembled(gatt, assembled)
            }
        })
    }

    // ---------------- Handshake helpers ----------------

    /**
     * Process a fully reassembled inbound message on the GATT-server side.
     */
    private fun handleServerInbound(device: BluetoothDevice, fragment: ByteArray) {
        val r = serverReassemblers.getOrPut(device.address) { BleFramer.Reassembler() }
        val message = r.feed(fragment) ?: return
        if (message.isEmpty()) return
        val type = message[0]
        val body = message.copyOfRange(1, message.size)
        when (type) {
            MSG_HANDSHAKE -> {
                if (body.size != OobHandshake.PUBLIC_KEY_LENGTH) {
                    cb?.onError("handshake: bad pubkey length ${body.size}")
                    return
                }
                val local = OobHandshake.generateKeyPair()
                serverHandshakes[device.address] = local
                val keys = try {
                    OobHandshake.derive(local.privateKey, body)
                } catch (t: Throwable) {
                    cb?.onError("handshake: derive failed ${t.message}")
                    return
                }
                serverKeys[device.address] = keys
                pendingCentrals[device.address] = device
                val ch = gattServer?.getService(SVC)?.getCharacteristic(CHAR_NOTIFY) ?: return
                notifyTyped(
                    device,
                    ch,
                    MSG_HANDSHAKE,
                    local.publicKey,
                    mtu = serverMtus[device.address] ?: DEFAULT_MTU,
                )
            }
            MSG_TOKEN -> {
                val keys = serverKeys[device.address] ?: run {
                    cb?.onError("token before handshake from ${device.address}")
                    return
                }
                val token = OobHandshake.unwrapToken(keys.macKey, body) ?: run {
                    cb?.onError("token MAC verification failed from ${device.address}")
                    return
                }
                TokenStore.putPeer(device.address, token, keys.sessionKey)
                pendingCentrals[device.address] = device
                cb?.onIncomingRequest(device.address, deviceNameSafe(device))
            }
            else -> cb?.onError("unknown handshake message type 0x${type.toInt() and 0xFF}")
        }
    }

    /**
     * Process a fully reassembled inbound message on the GATT-client side.
     */
    private fun handleClientAssembled(gatt: BluetoothGatt, message: ByteArray) {
        if (message.isEmpty()) return
        val type = message[0]
        val body = message.copyOfRange(1, message.size)
        when (type) {
            MSG_HANDSHAKE -> {
                if (body.size != OobHandshake.PUBLIC_KEY_LENGTH) {
                    finishClientWithError("handshake: bad pubkey length ${body.size}")
                    return
                }
                val pair = clientLocalPair
                    ?: return finishClientWithError("No local handshake key")
                val keys = try {
                    OobHandshake.derive(pair.privateKey, body)
                } catch (t: Throwable) {
                    finishClientWithError("handshake derive: ${t.message}")
                    return
                }
                clientKeys = keys
                val token = clientMyToken
                    ?: return finishClientWithError("No queued token")
                val writeChar = gatt.getService(SVC)?.getCharacteristic(CHAR_WRITE)
                    ?: return finishClientWithError("Write char gone")
                val wrapped = OobHandshake.wrapToken(keys.macKey, token)
                writeTyped(gatt, writeChar, MSG_TOKEN, wrapped, mtu = clientMtu)
            }
            MSG_TOKEN -> {
                val keys = clientKeys
                    ?: return finishClientWithError("Token before handshake")
                val token = OobHandshake.unwrapToken(keys.macKey, body)
                    ?: return finishClientWithError("Token MAC verification failed")
                val deviceId = clientDeviceId
                if (deviceId != null) {
                    TokenStore.putPeer(deviceId, token, keys.sessionKey)
                }
                val onPeer = clientOnPeer
                clientOnPeer = null
                clientOnErr = null
                onPeer?.invoke(token)
                cb?.onConnected(gatt.device.address, deviceNameSafe(gatt.device))
                gatt.disconnect()
            }
            else -> finishClientWithError("Unknown message type")
        }
    }

    private fun finishClientWithError(msg: String) {
        val onErr = clientOnErr
        clientOnPeer = null
        clientOnErr = null
        onErr?.invoke(msg)
    }

    private fun resetClientState() {
        clientLocalPair = null
        clientKeys = null
        clientReassembler.reset()
        clientMtu = DEFAULT_MTU
        clientDeviceId = null
        clientMyToken = null
        clientOnPeer = null
        clientOnErr = null
    }

    // ---------------- Wire helpers ----------------

    private fun writeTyped(
        gatt: BluetoothGatt,
        ch: BluetoothGattCharacteristic,
        type: Byte,
        body: ByteArray,
        mtu: Int,
    ) {
        val full = ByteArray(1 + body.size)
        full[0] = type
        System.arraycopy(body, 0, full, 1, body.size)
        for (frame in BleFramer.fragments(full, mtu)) {
            @Suppress("DEPRECATION")
            ch.value = frame
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(ch)
        }
    }

    private fun notifyTyped(
        d: BluetoothDevice,
        ch: BluetoothGattCharacteristic,
        type: Byte,
        body: ByteArray,
        mtu: Int,
    ) {
        val full = ByteArray(1 + body.size)
        full[0] = type
        System.arraycopy(body, 0, full, 1, body.size)
        for (frame in BleFramer.fragments(full, mtu)) {
            notify(d, ch, frame)
        }
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
