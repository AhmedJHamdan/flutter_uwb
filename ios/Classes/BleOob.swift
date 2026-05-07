import CoreBluetooth
import Foundation
import os.log

private let bleLog = OSLog(subsystem: "flutter_uwb", category: "BleOob")
private func dlog(_ msg: String) {
  os_log("%{public}@", log: bleLog, type: .info, msg)
}

/// CoreBluetooth-based out-of-band transport for **iOS-as-host**
/// driving an Apple-FiRa UWB accessory (Qorvo, NXP, custom MFi tag).
///
/// Central-only: scans for any registered accessory profile's vendor
/// service UUID, drives a long-lived GATT connection
/// (`accessoryConnect` / `accessoryWrite` / `accessoryDisconnect`),
/// and forwards bytes to `IosAccessoryStrategy` via
/// `onAccessoryNotify`.
///
/// iOS↔iOS peer-mode discovery and `NIDiscoveryToken` exchange is
/// handled by `PeerOob` (MultipeerConnectivity). Foreground only.
final class BleOob: NSObject {
  // MARK: - Public surface

  /// Vendor-specific BLE profile for an Apple-FiRa accessory.
  ///
  /// The protocol's byte format is fixed by Apple's NI Accessory
  /// Protocol, but the BLE service and characteristic UUIDs are
  /// vendor-chosen. Pass them in via `registerAccessoryProfile` from
  /// Dart.
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
    /// characteristic.
    func onAccessoryNotify(id: String, bytes: Data)

    /// A previously-connected accessory disconnected (peer-initiated,
    /// link loss, or our own `accessoryDisconnect` call).
    func onDisconnected(id: String, name: String)

    /// Any non-recoverable BLE error.
    func onError(_ message: String)
  }

  weak var callback: Callback?

  // MARK: - Internal state

  private var central: CBCentralManager?

  private(set) var started = false
  private var wantsScan = false

  /// `true` when the system Bluetooth radio is currently `.poweredOn`.
  /// Read by `UwbHostApiImpl.checkReadiness` to surface a "turn on
  /// Bluetooth" hint to the host app.
  ///
  /// Returns `false` when the central manager has not been instantiated
  /// yet — instantiating it here would trigger the OS Bluetooth-usage
  /// prompt, which we don't want to do on a passive readiness check.
  var isPoweredOn: Bool {
    return central?.state == .poweredOn
  }

  /// Configured accessory profiles. Forms the scan filter.
  private var accessoryProfiles: [AccessoryProfile] = []

  private var peripheralsByID: [String: CBPeripheral] = [:]
  private var seenAdvertisers: Set<String> = []
  /// Cached `name` for already-discovered peripherals so disconnect
  /// callbacks can echo it without consulting `CBPeripheral.name`
  /// (which is sometimes nil after subscribe).
  private var nameByID: [String: String] = [:]
  /// The accessory profile each discovered peripheral matched.
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

  /// Start scanning for registered accessory profiles. Calling `start`
  /// twice without an intervening `stop` updates the accessory-profile
  /// list and (re)kicks off scanning if the radio is up.
  func start(accessoryProfiles: [AccessoryProfile]) {
    dlog("BleOob.start profiles=\(accessoryProfiles.count)")
    self.accessoryProfiles = accessoryProfiles
    seenAdvertisers.removeAll()
    profileByID.removeAll()
    started = true
    wantsScan = !accessoryProfiles.isEmpty

    if central == nil {
      central = CBCentralManager(delegate: self, queue: .main)
    } else if let c = central, c.state == .poweredOn, c.isScanning {
      // Restart scan to pick up the new UUID list.
      c.stopScan()
      attemptScanIfReady()
    } else {
      attemptScanIfReady()
    }
  }

  /// Update the configured accessory profile list. If a scan is
  /// currently active, restart it with the new UUID filter.
  func updateAccessoryProfiles(_ profiles: [AccessoryProfile]) {
    self.accessoryProfiles = profiles
    wantsScan = !profiles.isEmpty
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
    return accessoryProfiles.map(\.serviceUuid)
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
      guard !f.isEmpty else { return }
      dlog("scan: starting filter=\(f.count) uuids")
      c.scanForPeripherals(
        withServices: f,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
      )
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

    guard let profile = accessoryProfile(matching: advertisedUuids) else {
      return
    }
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
