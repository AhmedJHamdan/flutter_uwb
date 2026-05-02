import CoreBluetooth
import Foundation

/// CoreBluetooth-based OOB transport.
///
/// Two roles in one class:
///
/// - **Peer mode** (the v1 baseline). Mirrors `BleOob.kt` on Android: the
///   custom flutter_uwb service UUID, advertise + scan simultaneously,
///   one-shot `exchange(...)` for token swap. Used for iOS↔iOS and iOS↔Android
///   *peer*-style ranging.
///
/// - **Accessory mode** (Phase C+). Scans for additional Apple-FiRa accessory
///   service UUIDs in parallel. When a peripheral matches an accessory
///   profile, `onAccessoryFound` fires instead of `onDeviceFound`. The host
///   then drives a long-lived connection via `accessoryConnect / accessoryWrite
///   / accessoryDisconnect`, with the accessory's notify characteristic
///   bytes streaming in through `onAccessoryNotify`. The host owns the
///   message protocol; this class only carries bytes.
///
/// Topology (peer mode)
/// - Each instance runs a `CBPeripheralManager` (advertises the service +
///   hosts a GATT server with a write + a notify characteristic) **and** a
///   `CBCentralManager` (scans for the same service + acts as a GATT client).
/// - Whichever side initiates `exchange()` becomes the GATT client; the
///   other side receives the write at its server, fires `onIncomingRequest`,
///   and replies via NOTIFY when the app calls `accept(deviceId:myToken:)`.
///
/// Device identifiers are platform-local UUIDs:
///   - On the central side, `deviceId` is `CBPeripheral.identifier.uuidString`.
///   - On the peripheral side, `deviceId` is `CBCentral.identifier.uuidString`.
///   Each side never compares its `deviceId` to the peer's view; Dart only
///   addresses peers using its own local id.
///
/// Foreground only. iOS BLE peripheral mode does not include the service UUID
/// in the main advertising packet while backgrounded; v2's contract is
/// foreground-only ranging.
@available(iOS 14.0, *)
final class BleOob: NSObject {
  // MARK: - Public surface

  /// Vendor-specific BLE profile for an Apple-FiRa accessory.
  ///
  /// The protocol's *byte format* is fixed (see `apple_protocol.dart`), but
  /// the BLE service / characteristic UUIDs are vendor-chosen — Apple's
  /// WWDC 2022 sample uses one set, real accessories ship others. The host
  /// passes the relevant tuple to `start(...)`; Phase E will surface this
  /// configuration to Dart via `registerAccessoryAdapter`.
  struct AccessoryProfile: Equatable {
    let serviceUuid: CBUUID
    /// Characteristic the iPhone writes to (accessory's "Rx").
    let rxUuid: CBUUID
    /// Characteristic the accessory pushes notifications on (its "Tx").
    let txUuid: CBUUID
  }

  protocol Callback: AnyObject {
    // Peer mode --------------------------------------------------------
    func onDeviceFound(id: String, name: String)
    func onIncomingRequest(id: String, name: String, peerToken: Data)
    func onConnected(id: String, name: String)
    func onDisconnected(id: String, name: String)
    func onError(_ message: String)

    // Accessory mode ---------------------------------------------------
    /// A peripheral advertising one of the registered accessory service
    /// UUIDs has been seen. `serviceUuid` is the matched profile's service
    /// UUID (uppercase, hyphenated) — used by the host to look up
    /// vendor-tag metadata.
    func onAccessoryFound(id: String, name: String, serviceUuid: String)
    /// Bytes pushed by the accessory via its Tx (notify) characteristic.
    /// `bytes` is a fully-reassembled message (BLE-level fragmentation is
    /// transparent to the caller).
    func onAccessoryNotify(id: String, bytes: Data)
  }

  weak var callback: Callback?

  // Peer-mode UUIDs — same as `android/.../oob/BleOob.kt`.
  static let serviceUuid =
    CBUUID(string: "4F1A9A1C-08D8-4B2E-BC6B-6B1D9F8D7B21")
  static let writeUuid =
    CBUUID(string: "B2D2A7F9-8C2A-4D7E-A89D-1D3A4E5F6A70")
  static let notifyUuid =
    CBUUID(string: "C9A0A82B-0C5A-4B8E-9E2E-5DBE2D08F7C3")

  // MARK: - Internal state

  private var central: CBCentralManager?
  private var peripheral: CBPeripheralManager?

  /// Read by the host so callers can re-issue `start(...)` while keeping
  /// the existing localName.
  private(set) var localName: String = "ios"
  /// Read by the host to know whether scanning/advertising is active.
  private(set) var started = false
  // Flags set by `start()` and consumed when each manager reaches
  // `.poweredOn`. The two managers come up asynchronously so we cannot
  // begin scanning/advertising synchronously from `start`.
  private var wantsScan = false
  private var wantsAdvertise = false

  /// Configured accessory profiles. The scan filter is the union of these
  /// service UUIDs and the peer-mode `serviceUuid`.
  private var accessoryProfiles: [AccessoryProfile] = []

  // Peripheral / GATT-server state ----------------------------------------

  private var notifyCharacteristic: CBMutableCharacteristic?
  private var writeCharacteristic: CBMutableCharacteristic?

  /// Centrals that have written to us, keyed by their identifier.
  private var pendingCentrals: [String: CBCentral] = [:]
  /// Bytes the central wrote, kept until `accept(deviceId:myToken:)` is
  /// called. Consumed once the reply is sent.
  private var pendingCentralBytes: [String: Data] = [:]
  /// Notify backlog, kept when `updateValue` returns false (queue is full).
  private var queuedNotifies: [(CBCentral, Data)] = []

  // Central / GATT-client state -------------------------------------------

  private var peripheralsByID: [String: CBPeripheral] = [:]
  private var seenAdvertisers: Set<String> = []
  /// Cached `name` for already-discovered peripherals so `onConnected` can
  /// echo it without consulting `CBPeripheral.name` (which is sometimes
  /// nil after subscribe).
  private var nameByID: [String: String] = [:]

  /// Mode of each discovered peripheral, decided at advertisement time.
  private enum PeerKind {
    case peer
    case accessory(AccessoryProfile)
  }
  private var kindByID: [String: PeerKind] = [:]

  /// Per-peer state for an in-flight `exchange(...)` request.
  private struct ExchangeState {
    let myToken: Data
    let onPeer: (Data) -> Void
    let onErr: (String) -> Void
    var settled = false
    var notifyChar: CBCharacteristic?
    var writeChar: CBCharacteristic?
  }

  private var exchanges: [String: ExchangeState] = [:]

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

  /// Start peer-mode (advertise + scan custom service) and optionally also
  /// scan for one or more accessory service UUIDs.
  ///
  /// Calling `start` twice without an intervening `stop` updates the
  /// accessory-profile list and (re)kicks off scanning if the radio is up.
  func start(
    localName: String,
    accessoryProfiles: [AccessoryProfile] = []
  ) {
    self.localName = localName
    self.accessoryProfiles = accessoryProfiles
    seenAdvertisers.removeAll()
    pendingCentrals.removeAll()
    pendingCentralBytes.removeAll()
    queuedNotifies.removeAll()
    kindByID.removeAll()
    started = true
    wantsScan = true
    wantsAdvertise = true

    // Bring up both managers. State callbacks below kick off scan/advertise
    // once the radio reaches `.poweredOn`. Reusing existing managers if any
    // is fine; CoreBluetooth keeps state across foreground transitions.
    if central == nil {
      central = CBCentralManager(delegate: self, queue: .main)
    } else {
      // If already on, restart scan to pick up the new UUID list.
      if let c = central, c.state == .poweredOn, c.isScanning {
        c.stopScan()
      }
      attemptScanIfReady()
    }
    if peripheral == nil {
      peripheral = CBPeripheralManager(delegate: self, queue: .main)
    } else {
      attemptAdvertiseIfReady()
    }
  }

  /// Update the configured accessory profile list. If a scan is currently
  /// active, restart it with the new UUID filter; otherwise the new list is
  /// picked up on the next `start(...)` call.
  func updateAccessoryProfiles(_ profiles: [AccessoryProfile]) {
    self.accessoryProfiles = profiles
    if let c = central, c.state == .poweredOn, c.isScanning {
      c.stopScan()
      attemptScanIfReady()
    }
  }

  func stop() {
    started = false
    wantsScan = false
    wantsAdvertise = false

    if let c = central {
      if c.isScanning { c.stopScan() }
      // Disconnect any peripherals we connected as a client.
      for p in peripheralsByID.values where p.state != .disconnected {
        c.cancelPeripheralConnection(p)
      }
    }
    if let p = peripheral {
      if p.isAdvertising { p.stopAdvertising() }
      p.removeAllServices()
    }

    notifyCharacteristic = nil
    writeCharacteristic = nil
    seenAdvertisers.removeAll()
    pendingCentrals.removeAll()
    pendingCentralBytes.removeAll()
    queuedNotifies.removeAll()
    peripheralsByID.removeAll()
    nameByID.removeAll()
    kindByID.removeAll()

    // Fail any in-flight exchanges.
    for var state in exchanges.values where !state.settled {
      state.settled = true
      state.onErr("BLE stopped")
    }
    exchanges.removeAll()

    // Fail any pending accessory ready-callbacks.
    for var conn in accessoryConnections.values {
      conn.onReady?(false)
      conn.onReady = nil
    }
    accessoryConnections.removeAll()
  }

  // MARK: - Pairing API (peripheral-side)

  /// Reply to a pending incoming-request with `myToken` over NOTIFY. Mirror
  /// of `BleOob.accept` on Android.
  func accept(deviceId: String, myToken: Data) {
    guard let c = pendingCentrals[deviceId] else {
      callback?.onError("accept: unknown deviceId \(deviceId)")
      return
    }
    sendNotify(to: c, value: myToken)
    callback?.onConnected(id: deviceId, name: c.identifier.uuidString)
  }

  /// Refuse a pending incoming-request. Mirror of `BleOob.decline`.
  ///
  /// CoreBluetooth has no first-class "kick this central" call; the closest
  /// analogue is letting the connection time out. We forget our pending
  /// state so subsequent writes are treated as fresh requests.
  func decline(deviceId: String) {
    pendingCentrals.removeValue(forKey: deviceId)
    pendingCentralBytes.removeValue(forKey: deviceId)
  }

  // MARK: - Pairing API (central-side, peer mode)

  /// Connect to a discovered peer-mode peripheral, write `myToken` to it,
  /// and wait for the peer's NOTIFY reply. Mirror of `BleOob.exchange`.
  ///
  /// Both completion blocks fire at most once. `onPeer` runs after the
  /// peer's NOTIFY arrives; `onErr` runs on any failure path.
  func exchange(
    deviceId: String,
    myToken: Data,
    onPeer: @escaping (Data) -> Void,
    onErr: @escaping (String) -> Void
  ) {
    guard let p = peripheralsByID[deviceId] else {
      onErr("exchange: unknown deviceId \(deviceId)")
      return
    }
    exchanges[deviceId] = ExchangeState(
      myToken: myToken,
      onPeer: onPeer,
      onErr: onErr,
      settled: false,
      notifyChar: nil,
      writeChar: nil
    )
    p.delegate = self
    if p.state == .connected {
      p.discoverServices([Self.serviceUuid])
    } else {
      central?.connect(p, options: nil)
    }
  }

  // MARK: - Accessory-mode API (central-side, persistent connection)

  /// Open a long-lived GATT connection to a discovered accessory and
  /// subscribe to its Tx (notify) characteristic. `onReady(true)` fires
  /// once subscription is confirmed; subsequent `onAccessoryNotify`
  /// callbacks deliver bytes pushed by the accessory.
  func accessoryConnect(
    deviceId: String,
    onReady: @escaping (Bool) -> Void
  ) {
    guard let p = peripheralsByID[deviceId] else {
      onReady(false)
      callback?.onError("accessoryConnect: unknown deviceId \(deviceId)")
      return
    }
    guard case .accessory(let profile) = kindByID[deviceId] else {
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
      callback?.onError("accessoryWrite: not ready for \(deviceId)")
      return
    }
    let kind: CBCharacteristicWriteType =
      rx.properties.contains(.write) ? .withResponse : .withoutResponse
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
    var uuids: [CBUUID] = [Self.serviceUuid]
    uuids.append(contentsOf: accessoryProfiles.map(\.serviceUuid))
    return uuids
  }

  private func accessoryProfile(matching uuids: [CBUUID]) -> AccessoryProfile? {
    for profile in accessoryProfiles where uuids.contains(profile.serviceUuid) {
      return profile
    }
    return nil
  }

  private func attemptScanIfReady() {
    guard let c = central, wantsScan, c.state == .poweredOn else { return }
    if !c.isScanning {
      c.scanForPeripherals(
        withServices: scanFilter(),
        options: [
          CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ]
      )
    }
  }

  private func attemptAdvertiseIfReady() {
    guard let p = peripheral, wantsAdvertise, p.state == .poweredOn else {
      return
    }
    publishServiceIfNeeded()
    if !p.isAdvertising {
      p.startAdvertising([
        CBAdvertisementDataServiceUUIDsKey: [Self.serviceUuid],
        CBAdvertisementDataLocalNameKey: localName,
      ])
    }
  }

  private func publishServiceIfNeeded() {
    guard let p = peripheral, notifyCharacteristic == nil else { return }
    let writeChar = CBMutableCharacteristic(
      type: Self.writeUuid,
      properties: [.write, .writeWithoutResponse],
      value: nil,
      permissions: [.writeable]
    )
    let notifyChar = CBMutableCharacteristic(
      type: Self.notifyUuid,
      properties: [.notify, .read],
      value: nil,
      permissions: [.readable]
    )
    let service = CBMutableService(type: Self.serviceUuid, primary: true)
    service.characteristics = [writeChar, notifyChar]
    self.writeCharacteristic = writeChar
    self.notifyCharacteristic = notifyChar
    p.add(service)
  }

  private func sendNotify(to central: CBCentral, value: Data) {
    guard let p = peripheral, let ch = notifyCharacteristic else { return }
    let ok = p.updateValue(value, for: ch, onSubscribedCentrals: [central])
    if !ok {
      // Queue is full; CoreBluetooth will call
      // `peripheralManagerIsReady(toUpdateSubscribers:)` when capacity frees.
      queuedNotifies.append((central, value))
    } else {
      pendingCentralBytes.removeValue(forKey: central.identifier.uuidString)
    }
  }

  fileprivate func flushQueuedNotifies() {
    guard let p = peripheral, let ch = notifyCharacteristic else { return }
    while let (c, v) = queuedNotifies.first {
      let ok = p.updateValue(v, for: ch, onSubscribedCentrals: [c])
      if !ok { return }
      queuedNotifies.removeFirst()
      pendingCentralBytes.removeValue(forKey: c.identifier.uuidString)
    }
  }

  fileprivate func settleExchange(
    _ deviceId: String,
    success: Data?,
    failure: String?
  ) {
    guard var state = exchanges[deviceId] else { return }
    if state.settled { return }
    state.settled = true
    exchanges[deviceId] = state
    if let bytes = success { state.onPeer(bytes) }
    if let msg = failure { state.onErr(msg) }
    exchanges.removeValue(forKey: deviceId)
    if let p = peripheralsByID[deviceId], p.state == .connected {
      central?.cancelPeripheralConnection(p)
    }
  }
}

// MARK: - CBCentralManagerDelegate

@available(iOS 14.0, *)
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
    // Skip our own advertisements (when the OS happens to surface them).
    if advertisedName == localName { return }
    let advertisedUuids =
      (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

    peripheralsByID[id] = peripheral
    nameByID[id] = name

    let kind: PeerKind
    if advertisedUuids.contains(Self.serviceUuid) {
      kind = .peer
    } else if let profile = accessoryProfile(matching: advertisedUuids) {
      kind = .accessory(profile)
    } else {
      // Unknown UUID set; skip.
      return
    }
    kindByID[id] = kind

    if seenAdvertisers.insert(id).inserted {
      switch kind {
      case .peer:
        callback?.onDeviceFound(id: id, name: name)
      case .accessory(let profile):
        callback?.onAccessoryFound(
          id: id,
          name: name,
          serviceUuid: profile.serviceUuid.uuidString.uppercased()
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
    if let conn = accessoryConnections[id] {
      peripheral.discoverServices([conn.profile.serviceUuid])
    } else {
      peripheral.discoverServices([Self.serviceUuid])
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    let msg = error?.localizedDescription ?? "Failed to connect"
    settleExchange(id, success: nil, failure: msg)
    if var conn = accessoryConnections[id] {
      conn.onReady?(false)
      conn.onReady = nil
      accessoryConnections.removeValue(forKey: id)
      callback?.onError(msg)
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    let name = nameByID[id] ?? "BLE Device"
    if exchanges[id] != nil {
      settleExchange(id, success: nil, failure: error?.localizedDescription
                     ?? "Disconnected before peer token arrived")
    }
    if var conn = accessoryConnections[id] {
      conn.onReady?(false)
      conn.onReady = nil
      accessoryConnections.removeValue(forKey: id)
    }
    callback?.onDisconnected(id: id, name: name)
  }
}

// MARK: - CBPeripheralDelegate (central-side)

@available(iOS 14.0, *)
extension BleOob: CBPeripheralDelegate {
  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverServices error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    if let err = error {
      settleExchange(id, success: nil, failure: err.localizedDescription)
      failAccessoryReady(id, message: err.localizedDescription)
      return
    }
    if let conn = accessoryConnections[id] {
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
      return
    }
    guard let svc = peripheral.services?.first(where: {
      $0.uuid == Self.serviceUuid
    }) else {
      settleExchange(id, success: nil, failure: "Service not found")
      return
    }
    peripheral.discoverCharacteristics(
      [Self.writeUuid, Self.notifyUuid],
      for: svc
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    if let err = error {
      settleExchange(id, success: nil, failure: err.localizedDescription)
      failAccessoryReady(id, message: err.localizedDescription)
      return
    }
    guard let chars = service.characteristics else {
      settleExchange(id, success: nil, failure: "No characteristics")
      failAccessoryReady(id, message: "No characteristics")
      return
    }

    if var conn = accessoryConnections[id] {
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
      return
    }

    let writeChar = chars.first { $0.uuid == Self.writeUuid }
    let notifyChar = chars.first { $0.uuid == Self.notifyUuid }
    guard let write = writeChar, let notify = notifyChar else {
      settleExchange(id, success: nil, failure: "Missing write or notify char")
      return
    }
    if var state = exchanges[id] {
      state.writeChar = write
      state.notifyChar = notify
      exchanges[id] = state
    }
    peripheral.setNotifyValue(true, for: notify)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    if let err = error {
      settleExchange(id, success: nil, failure: err.localizedDescription)
      failAccessoryReady(id, message: err.localizedDescription)
      return
    }
    if let conn = accessoryConnections[id],
       characteristic.uuid == conn.profile.txUuid {
      // Subscription confirmed — accessory connection is ready.
      var c = conn
      c.onReady?(true)
      c.onReady = nil
      accessoryConnections[id] = c
      return
    }
    guard characteristic.uuid == Self.notifyUuid,
          let state = exchanges[id],
          let writeChar = state.writeChar else { return }
    peripheral.writeValue(state.myToken, for: writeChar, type: .withResponse)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    if let err = error {
      settleExchange(id, success: nil, failure: err.localizedDescription)
      // Accessory writes don't carry a settle path; surface as a generic
      // error so the strategy can decide how to recover.
      if accessoryConnections[id] != nil {
        callback?.onError("Accessory write failed: \(err.localizedDescription)")
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    if let err = error {
      settleExchange(id, success: nil, failure: err.localizedDescription)
      return
    }
    if let conn = accessoryConnections[id],
       characteristic.uuid == conn.profile.txUuid,
       let value = characteristic.value {
      callback?.onAccessoryNotify(id: id, bytes: value)
      return
    }
    guard characteristic.uuid == Self.notifyUuid,
          let value = characteristic.value else { return }
    let name = nameByID[id] ?? peripheral.name ?? "BLE Device"
    settleExchange(id, success: value, failure: nil)
    callback?.onConnected(id: id, name: name)
  }

  fileprivate func failAccessoryReady(_ id: String, message: String) {
    guard var conn = accessoryConnections[id] else { return }
    conn.onReady?(false)
    conn.onReady = nil
    accessoryConnections.removeValue(forKey: id)
    callback?.onError(message)
  }
}

// MARK: - CBPeripheralManagerDelegate (peripheral-side)

@available(iOS 14.0, *)
extension BleOob: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
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
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for req in requests {
      if req.characteristic.uuid == Self.writeUuid {
        let id = req.central.identifier.uuidString
        pendingCentrals[id] = req.central
        let bytes = req.value ?? Data()
        pendingCentralBytes[id] = bytes
        callback?.onIncomingRequest(
          id: id,
          name: id,
          peerToken: bytes
        )
      }
      peripheral.respond(to: req, withResult: .success)
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    // No-op. We send via `updateValue(...onSubscribedCentrals:)` from
    // `accept(deviceId:myToken:)`.
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    let id = central.identifier.uuidString
    pendingCentrals.removeValue(forKey: id)
    pendingCentralBytes.removeValue(forKey: id)
  }

  func peripheralManagerIsReady(
    toUpdateSubscribers peripheral: CBPeripheralManager
  ) {
    flushQueuedNotifies()
  }
}
