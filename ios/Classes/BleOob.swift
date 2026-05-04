import CoreBluetooth
import Foundation
import os.log

private let bleLog = OSLog(subsystem: "flutter_uwb", category: "BleOob")
private func dlog(_ msg: String) {
  os_log("%{public}@", log: bleLog, type: .info, msg)
}

/// CoreBluetooth-based out-of-band transport.
///
/// Two roles are driven from the same instance:
///
/// 1. **Symmetric peer mode (cross-OS)** — iOS publishes a GATT server
///    on the symmetric service UUID that mirrors `BleOob.kt` on Android,
///    and scans for the same UUID. Android advertises capability
///    `[0x02]` as service-data so iOS can surface it as
///    `accessory:android` without any vendor profile registration.
///    Conversely, iOS BLE advertisements cannot carry service-data
///    (Apple strips that field), so iOS conveys its capability byte
///    `0x01` after connect via `MSG_CAPS = 0x03` on the NOTIFY
///    characteristic.
///
/// 2. **FiRa accessory mode** — central-only; scans for any registered
///    accessory profile's vendor service UUID, drives a long-lived GATT
///    connection (`accessoryConnect` / `accessoryWrite` /
///    `accessoryDisconnect`), and forwards bytes to
///    `IosAccessoryStrategy` via `onAccessoryNotify`.
///
/// iOS↔iOS peer-mode discovery and `NIDiscoveryToken` exchange is
/// handled by `PeerOob` (MultipeerConnectivity) and is intentionally
/// not part of this class. Foreground only.
final class BleOob: NSObject {
  // MARK: - Symmetric service UUIDs (mirror of Android's BleOob.kt)

  static let symmetricServiceUuid =
    CBUUID(string: "4F1A9A1C-08D8-4B2E-BC6B-6B1D9F8D7B21")
  static let symmetricWriteUuid =
    CBUUID(string: "B2D2A7F9-8C2A-4D7E-A89D-1D3A4E5F6A70")
  static let symmetricNotifyUuid =
    CBUUID(string: "C9A0A82B-0C5A-4B8E-9E2E-5DBE2D08F7C3")

  /// Capability conveyance message type. Body is a single byte
  /// matching `OobCapability.iosPeer` / `androidPeer`.
  static let msgCapability: UInt8 = 0x03

  /// Synthetic accessory profile for cross-OS peers connecting on the
  /// symmetric service. Stored in `profileByID` for any peer matched
  /// via service-data so `accessoryConnect` works without a registered
  /// vendor profile. The Apple-FiRa protocol over this profile is
  /// driven by `IosAccessoryStrategy` exactly as for vendor
  /// accessories.
  private static let symmetricAccessoryProfile = AccessoryProfile(
    serviceUuid: symmetricServiceUuid,
    rxUuid: symmetricWriteUuid,
    txUuid: symmetricNotifyUuid
  )

  // MARK: - Public surface

  /// Vendor-specific BLE profile for an Apple-FiRa accessory.
  ///
  /// The protocol's byte format is fixed (see `apple_protocol.dart`),
  /// but the BLE service and characteristic UUIDs are vendor-chosen.
  /// Pass them in via `registerAccessoryProfile` from Dart.
  struct AccessoryProfile: Equatable {
    let serviceUuid: CBUUID
    /// Characteristic the iPhone writes to (the accessory's "Rx").
    let rxUuid: CBUUID
    /// Characteristic the accessory pushes notifications on (its "Tx").
    let txUuid: CBUUID
  }

  protocol Callback: AnyObject {
    /// A peripheral advertising one of the registered accessory
    /// service UUIDs has been seen. `serviceUuid` is the matched
    /// profile's service UUID (uppercase, hyphenated) — used by the
    /// host to look up vendor-tag metadata.
    func onAccessoryFound(id: String, name: String, serviceUuid: String)

    /// Bytes pushed by the accessory via its Tx (notify)
    /// characteristic. `bytes` is a fully-reassembled message
    /// (BLE-level fragmentation is transparent to the caller).
    func onAccessoryNotify(id: String, bytes: Data)

    /// A symmetric BLE peer (Android phone, future cross-OS host)
    /// matching the shared service UUID has been seen. `capability`
    /// is the parsed `OobCapability` byte from the advertisement
    /// service-data (Android), defaulting to `androidPeer` when
    /// missing.
    func onSymmetricPeerFound(id: String, name: String, capability: UInt8)

    /// A previously-connected accessory or symmetric peer
    /// disconnected (peer-initiated, link loss, or our own
    /// `accessoryDisconnect` call).
    func onDisconnected(id: String, name: String)

    /// Any non-recoverable BLE error. Surfaced as a transport error to
    /// the active ranging session if one is running.
    func onError(_ message: String)
  }

  weak var callback: Callback?

  // MARK: - Internal state

  private var central: CBCentralManager?
  private var peripheral: CBPeripheralManager?

  /// The mutable service we publish for symmetric peer mode. Re-added
  /// on every peripheral state transition to `.poweredOn`.
  private var symmetricService: CBMutableService?
  private var symmetricWriteChar: CBMutableCharacteristic?
  private var symmetricNotifyChar: CBMutableCharacteristic?
  private var symmetricServiceAdded = false

  /// Local advertising name passed via `start(localName:...)`. Used as
  /// `CBAdvertisementDataLocalNameKey`.
  private var localName: String = ""

  private(set) var started = false
  private var wantsScan = false

  /// Configured accessory profiles. Forms the scan filter (in addition
  /// to the symmetric service UUID, which is always scanned for).
  private var accessoryProfiles: [AccessoryProfile] = []

  private var peripheralsByID: [String: CBPeripheral] = [:]
  private var seenAdvertisers: Set<String> = []
  /// Cached `name` for already-discovered peripherals so disconnect
  /// callbacks can echo it without consulting `CBPeripheral.name`
  /// (which is sometimes nil after subscribe).
  private var nameByID: [String: String] = [:]
  /// The accessory profile each discovered peripheral matched. Absent
  /// for symmetric-peer discoveries.
  private var profileByID: [String: AccessoryProfile] = [:]

  /// Per-accessory connection state.
  private struct AccessoryConnection {
    let profile: AccessoryProfile
    /// Fires when subscription to the Tx characteristic is confirmed.
    var onReady: ((Bool) -> Void)?
    var rxChar: CBCharacteristic?
    var txChar: CBCharacteristic?
  }

  private var accessoryConnections: [String: AccessoryConnection] = [:]

  // MARK: - Lifecycle

  override init() {
    super.init()
  }

  /// Start scanning for accessories and symmetric peers, and start
  /// publishing the symmetric GATT service so other phones can find
  /// us. Calling `start` twice without an intervening `stop` updates
  /// the accessory-profile list and (re)kicks off scanning if the
  /// radio is up.
  func start(localName: String, accessoryProfiles: [AccessoryProfile]) {
    dlog("BleOob.start name=\(localName) profiles=\(accessoryProfiles.count)")
    self.localName = localName
    self.accessoryProfiles = accessoryProfiles
    seenAdvertisers.removeAll()
    profileByID.removeAll()
    started = true
    // Symmetric service UUID is always scanned for, so scanning is
    // always wanted while started.
    wantsScan = true

    if central == nil {
      central = CBCentralManager(delegate: self, queue: .main)
    } else if let c = central, c.state == .poweredOn, c.isScanning {
      // Restart scan to pick up the new UUID list.
      c.stopScan()
      attemptScanIfReady()
    } else {
      attemptScanIfReady()
    }

    if peripheral == nil {
      peripheral = CBPeripheralManager(delegate: self, queue: .main)
    } else {
      attemptAdvertiseIfReady()
    }
  }

  /// Update the configured accessory profile list. Symmetric scanning
  /// continues regardless. If a scan is currently active, restart it
  /// with the new UUID filter.
  func updateAccessoryProfiles(_ profiles: [AccessoryProfile]) {
    self.accessoryProfiles = profiles
    guard let c = central else { return }
    if c.state == .poweredOn, c.isScanning {
      c.stopScan()
    }
    attemptScanIfReady()
  }

  func stop() {
    started = false
    wantsScan = false

    if let c = central {
      if c.isScanning { c.stopScan() }
      // Disconnect any peripherals we connected as a client.
      for p in peripheralsByID.values where p.state != .disconnected {
        c.cancelPeripheralConnection(p)
      }
    }

    if let pm = peripheral {
      if pm.isAdvertising { pm.stopAdvertising() }
      if symmetricServiceAdded, let svc = symmetricService {
        pm.remove(svc)
      }
    }
    symmetricServiceAdded = false

    seenAdvertisers.removeAll()
    peripheralsByID.removeAll()
    nameByID.removeAll()
    profileByID.removeAll()

    // Fail any pending accessory ready-callbacks.
    for var conn in accessoryConnections.values {
      conn.onReady?(false)
      conn.onReady = nil
    }
    accessoryConnections.removeAll()
  }

  // MARK: - Accessory-mode API (central-side, persistent connection)

  /// Open a long-lived GATT connection to a discovered accessory and
  /// subscribe to its Tx (notify) characteristic. `onReady(true)`
  /// fires once subscription is confirmed; subsequent
  /// `onAccessoryNotify` callbacks deliver bytes pushed by the
  /// accessory.
  func accessoryConnect(
    deviceId: String,
    onReady: @escaping (Bool) -> Void
  ) {
    dlog("accessoryConnect id=\(deviceId) periph=\(peripheralsByID[deviceId] != nil) profile=\(profileByID[deviceId] != nil)")
    guard let p = peripheralsByID[deviceId] else {
      onReady(false)
      callback?.onError("accessoryConnect: unknown deviceId \(deviceId)")
      return
    }
    guard let profile = profileByID[deviceId] else {
      onReady(false)
      callback?.onError("accessoryConnect: \(deviceId) is not an accessory")
      return
    }
    accessoryConnections[deviceId] = AccessoryConnection(
      profile: profile,
      onReady: onReady,
      rxChar: nil,
      txChar: nil
    )
    p.delegate = self
    if p.state == .connected {
      p.discoverServices([profile.serviceUuid])
    } else {
      central?.connect(p, options: nil)
    }
  }

  /// Write bytes to the accessory's Rx characteristic.
  func accessoryWrite(deviceId: String, bytes: Data) {
    guard let p = peripheralsByID[deviceId],
          let conn = accessoryConnections[deviceId],
          let rx = conn.rxChar else {
      dlog("accessoryWrite: not ready id=\(deviceId)")
      callback?.onError("accessoryWrite: not ready for \(deviceId)")
      return
    }
    let kind: CBCharacteristicWriteType =
      rx.properties.contains(.write) ? .withResponse : .withoutResponse
    dlog("accessoryWrite id=\(deviceId) bytes=\(bytes.map { String(format: "%02X", $0) }.joined()) kind=\(kind == .withResponse ? "resp" : "noresp")")
    p.writeValue(bytes, for: rx, type: kind)
  }

  /// Tear down an accessory connection.
  func accessoryDisconnect(deviceId: String) {
    if let p = peripheralsByID[deviceId], p.state != .disconnected {
      central?.cancelPeripheralConnection(p)
    }
    accessoryConnections.removeValue(forKey: deviceId)
  }

  // MARK: - Helpers

  private func scanFilter() -> [CBUUID] {
    var ids: [CBUUID] = [BleOob.symmetricServiceUuid]
    ids.append(contentsOf: accessoryProfiles.map(\.serviceUuid))
    return ids
  }

  private func accessoryProfile(matching uuids: [CBUUID]) -> AccessoryProfile? {
    for profile in accessoryProfiles where uuids.contains(profile.serviceUuid) {
      return profile
    }
    return nil
  }

  private func attemptScanIfReady() {
    guard let c = central else { return }
    guard wantsScan else { return }
    guard c.state == .poweredOn else {
      dlog("scan: central not poweredOn state=\(c.state.rawValue)")
      return
    }
    if !c.isScanning {
      let f = scanFilter()
      dlog("scan: starting filter=\(f.count) uuids")
      c.scanForPeripherals(
        withServices: f,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
      )
    }
  }

  private func attemptAdvertiseIfReady() {
    guard started else { return }
    guard let pm = peripheral else { return }
    guard pm.state == .poweredOn else { return }
    if symmetricService == nil {
      let writeChar = CBMutableCharacteristic(
        type: BleOob.symmetricWriteUuid,
        properties: [.write, .writeWithoutResponse],
        value: nil,
        permissions: [.writeable]
      )
      let notifyChar = CBMutableCharacteristic(
        type: BleOob.symmetricNotifyUuid,
        properties: [.notify, .read],
        value: nil,
        permissions: [.readable]
      )
      let svc = CBMutableService(
        type: BleOob.symmetricServiceUuid,
        primary: true
      )
      svc.characteristics = [writeChar, notifyChar]
      symmetricWriteChar = writeChar
      symmetricNotifyChar = notifyChar
      symmetricService = svc
    }
    if !symmetricServiceAdded, let svc = symmetricService {
      pm.add(svc)
      symmetricServiceAdded = true
    }
    if !pm.isAdvertising {
      var data: [String: Any] = [
        CBAdvertisementDataServiceUUIDsKey: [BleOob.symmetricServiceUuid],
      ]
      if !localName.isEmpty {
        data[CBAdvertisementDataLocalNameKey] = localName
      }
      dlog("peripheral: startAdvertising name=\(localName)")
      pm.startAdvertising(data)
    }
  }

  fileprivate func failAccessoryReady(_ id: String, message: String) {
    dlog("failAccessoryReady id=\(id) msg=\(message)")
    guard var conn = accessoryConnections[id] else { return }
    conn.onReady?(false)
    conn.onReady = nil
    accessoryConnections.removeValue(forKey: id)
    callback?.onError(message)
  }
}

// MARK: - CBCentralManagerDelegate

extension BleOob: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      attemptScanIfReady()
    case .poweredOff, .unauthorized, .unsupported:
      callback?.onError("Bluetooth central not available: \(central.state.rawValue)")
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let id = peripheral.identifier.uuidString
    let advertisedName =
      advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let name = advertisedName ?? peripheral.name ?? "BLE Device"
    let advertisedUuids =
      (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

    if let profile = accessoryProfile(matching: advertisedUuids) {
      peripheralsByID[id] = peripheral
      nameByID[id] = name
      profileByID[id] = profile

      if seenAdvertisers.insert(id).inserted {
        callback?.onAccessoryFound(
          id: id,
          name: name,
          serviceUuid: profile.serviceUuid.uuidString.uppercased()
        )
      }
      return
    }

    if advertisedUuids.contains(BleOob.symmetricServiceUuid) {
      let serviceData =
        (advertisementData[CBAdvertisementDataServiceDataKey]
          as? [CBUUID: Data]) ?? [:]
      let payload = serviceData[BleOob.symmetricServiceUuid]
      dlog("scan: symmetric peer id=\(id) name=\(name) cap=\(payload?.map { String(format: "%02X", $0) }.joined() ?? "nil")")
      let capability: UInt8
      if let first = payload?.first {
        capability = first
      } else {
        // No service-data — by convention this means the peer is
        // another iOS device, since iOS BLE advertisements cannot
        // carry service-data. Same-OS pairs go via MPC, so skip.
        return
      }
      peripheralsByID[id] = peripheral
      nameByID[id] = name
      profileByID[id] = BleOob.symmetricAccessoryProfile
      if seenAdvertisers.insert(id).inserted {
        callback?.onSymmetricPeerFound(
          id: id, name: name, capability: capability
        )
      }
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didConnect peripheral: CBPeripheral
  ) {
    peripheral.delegate = self
    let id = peripheral.identifier.uuidString
    dlog("didConnect id=\(id)")
    if let conn = accessoryConnections[id] {
      peripheral.discoverServices([conn.profile.serviceUuid])
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    let msg = error?.localizedDescription ?? "Failed to connect"
    dlog("didFailToConnect id=\(id) err=\(msg)")
    if accessoryConnections[id] != nil {
      failAccessoryReady(id, message: msg)
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    let name = nameByID[id] ?? "BLE Device"
    dlog("didDisconnect id=\(id) err=\(error?.localizedDescription ?? "nil")")
    if var conn = accessoryConnections[id] {
      conn.onReady?(false)
      conn.onReady = nil
      accessoryConnections.removeValue(forKey: id)
    }
    callback?.onDisconnected(id: id, name: name)
  }
}

// MARK: - CBPeripheralDelegate (central-side)

extension BleOob: CBPeripheralDelegate {
  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverServices error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    dlog("didDiscoverServices id=\(id) services=\(peripheral.services?.count ?? -1) err=\(error?.localizedDescription ?? "nil")")
    if let err = error {
      failAccessoryReady(id, message: err.localizedDescription)
      return
    }
    guard let conn = accessoryConnections[id] else { return }
    guard let svc = peripheral.services?.first(where: {
      $0.uuid == conn.profile.serviceUuid
    }) else {
      failAccessoryReady(id, message: "Accessory service not found")
      return
    }
    peripheral.discoverCharacteristics(
      [conn.profile.rxUuid, conn.profile.txUuid],
      for: svc
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    dlog("didDiscoverChars id=\(id) chars=\(service.characteristics?.count ?? -1) err=\(error?.localizedDescription ?? "nil")")
    if let err = error {
      failAccessoryReady(id, message: err.localizedDescription)
      return
    }
    guard var conn = accessoryConnections[id] else { return }
    guard let chars = service.characteristics else {
      failAccessoryReady(id, message: "No characteristics")
      return
    }
    let rx = chars.first { $0.uuid == conn.profile.rxUuid }
    let tx = chars.first { $0.uuid == conn.profile.txUuid }
    guard let rxChar = rx, let txChar = tx else {
      failAccessoryReady(id, message: "Missing accessory rx/tx char")
      return
    }
    conn.rxChar = rxChar
    conn.txChar = txChar
    accessoryConnections[id] = conn
    peripheral.setNotifyValue(true, for: txChar)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    dlog("didUpdateNotify id=\(id) char=\(characteristic.uuid.uuidString) isNotifying=\(characteristic.isNotifying) err=\(error?.localizedDescription ?? "nil")")
    if let err = error {
      failAccessoryReady(id, message: err.localizedDescription)
      return
    }
    guard let conn = accessoryConnections[id],
          characteristic.uuid == conn.profile.txUuid else {
      return
    }
    // Subscription confirmed — accessory connection is ready.
    var c = conn
    c.onReady?(true)
    c.onReady = nil
    accessoryConnections[id] = c
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    dlog("didWriteValue id=\(id) err=\(error?.localizedDescription ?? "nil")")
    if let err = error, accessoryConnections[id] != nil {
      callback?.onError("Accessory write failed: \(err.localizedDescription)")
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    guard error == nil,
          let conn = accessoryConnections[id],
          characteristic.uuid == conn.profile.txUuid,
          let value = characteristic.value else {
      return
    }
    callback?.onAccessoryNotify(id: id, bytes: value)
  }
}

// MARK: - CBPeripheralManagerDelegate (symmetric peer mode)

extension BleOob: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    dlog("peripheralManagerDidUpdateState state=\(peripheral.state.rawValue)")
    switch peripheral.state {
    case .poweredOn:
      attemptAdvertiseIfReady()
    case .poweredOff, .unauthorized, .unsupported:
      callback?.onError(
        "Bluetooth peripheral not available: \(peripheral.state.rawValue)"
      )
    default:
      break
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didAdd service: CBService,
    error: Error?
  ) {
    dlog("peripheralManager didAdd err=\(error?.localizedDescription ?? "nil")")
    if let err = error {
      callback?.onError("Failed to publish symmetric service: \(err.localizedDescription)")
    }
  }

  func peripheralManagerDidStartAdvertising(
    _ peripheral: CBPeripheralManager,
    error: Error?
  ) {
    dlog("peripheralManagerDidStartAdvertising err=\(error?.localizedDescription ?? "nil")")
    if let err = error {
      callback?.onError("Symmetric advertising failed: \(err.localizedDescription)")
    }
  }

  /// Central subscribed to our NOTIFY characteristic. Apple's FiRa
  /// accessory protocol uses `0x03` for `accessoryUwbDidStop`, so we
  /// must not pre-emit any frame here — the central side already
  /// learned our capability from the missing service-data on the
  /// scan advertisement (iOS BLE strips service-data; Android centrals
  /// treat that absence as the iOS-peer signal). The first NOTIFY
  /// frame the central sees on this channel is therefore the
  /// accessory's own `0x01 AccessoryConfigurationData` reply driven by
  /// `IosAccessoryStrategy` once a host writes `Initialize` (0x0A).
  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    // intentionally empty
  }
}
