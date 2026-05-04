import CoreBluetooth
import Flutter
import Foundation
import NearbyInteraction

// Pigeon 14.0.1's Swift FlutterApi codegen uses `Result<Void, FlutterError>`.
// `FlutterError` from the Flutter framework is an NSObject and is not
// automatically bridged to Swift's `Error` protocol — make it conform here
// so the generated code compiles.
extension FlutterError: Error {}

/// Implements `UwbHostApi` on iOS.
///
/// **Discovery / out-of-band transport** is split by peer kind:
/// - `PeerOob` (MultipeerConnectivity) handles iOS↔iOS peer
///   discovery and `NIDiscoveryToken` exchange. iOS 17+ requires an
///   active AWDL/Bonjour sidechannel for `NINearbyPeerConfiguration`
///   to actually produce samples; the `MCSession` provides it.
/// - `BleOob` (CoreBluetooth) handles FiRa accessory discovery and
///   the long-lived GATT connection used by `IosAccessoryStrategy`
///   to drive the Apple-protocol handshake.
///
/// **UWB ranging** is dispatched by `UwbDevice.platform`:
/// - `"ios"` / `"android"` → `IosPeerStrategy` (`NINearbyPeerConfiguration`).
/// - `"accessory"`         → `IosAccessoryStrategy`
///   (`NINearbyAccessoryConfiguration` over Apple's FiRa accessory
///   BLE protocol).
final class UwbHostApiImpl: NSObject, UwbHostApi {
  private let flutterApi: UwbFlutterApi

  private let ble = BleOob()
  private let peer = PeerOob()

  /// All currently-discovered peers (iOS via `PeerOob`, accessories
  /// via `BleOob`), keyed by the OOB transport's device id.
  private var discovered: [String: UwbDevice] = [:]

  private var peerTokens: [String: Data] = [:]
  private var pendingExchanges: [String: (Result<TokenPayload, Error>) -> Void] = [:]
  private var localTokenSession: NISession?
  private var activeStrategy: RangingStrategy?

  init(messenger: FlutterBinaryMessenger) {
    self.flutterApi = UwbFlutterApi(binaryMessenger: messenger)
    super.init()
    ble.callback = self
    peer.callback = self
  }

  // MARK: - Accessory profiles

  private struct RegisteredProfile {
    let bleProfile: BleOob.AccessoryProfile
    let vendorTag: String?
  }
  private var registeredProfiles: [String: RegisteredProfile] = [:]

  private func bleAccessoryProfiles() -> [BleOob.AccessoryProfile] {
    return registeredProfiles.values.map(\.bleProfile)
  }

  // MARK: - Discovery / OOB

  func startDiscovery(localName: String) throws -> VoidResult {
    discovered.removeAll()
    peerTokens.removeAll()
    failPendingExchanges(with: PluginError.cancelled)
    ble.start(localName: localName, accessoryProfiles: bleAccessoryProfiles())
    peer.start(localName: localName)
    return VoidResult(ok: true)
  }

  func registerAccessoryProfile(profile: AccessoryProfile) throws -> VoidResult {
    let key = profile.serviceUuid.uppercased()
    let bleProfile = BleOob.AccessoryProfile(
      serviceUuid: CBUUID(string: profile.serviceUuid),
      rxUuid: CBUUID(string: profile.rxUuid),
      txUuid: CBUUID(string: profile.txUuid)
    )
    registeredProfiles[key] = RegisteredProfile(
      bleProfile: bleProfile,
      vendorTag: profile.vendorTag
    )
    ble.updateAccessoryProfiles(bleAccessoryProfiles())
    return VoidResult(ok: true)
  }

  func unregisterAccessoryProfile(serviceUuid: String) throws -> VoidResult {
    registeredProfiles.removeValue(forKey: serviceUuid.uppercased())
    ble.updateAccessoryProfiles(bleAccessoryProfiles())
    return VoidResult(ok: true)
  }

  func stopDiscovery() throws -> VoidResult {
    ble.stop()
    peer.stop()
    discovered.removeAll()
    peerTokens.removeAll()
    failPendingExchanges(with: PluginError.cancelled)
    return VoidResult(ok: true)
  }

  func getDiscovered() throws -> [UwbDevice] {
    return Array(discovered.values)
  }

  func acceptRequest(deviceId: String, myToken: TokenPayload) throws -> VoidResult {
    // Incoming requests on iOS only originate from `PeerOob`. The
    // accessory path has no symmetric "incoming request" concept —
    // accessories are discovered and connected to, not the reverse.
    let token = myToken.bytes.data
    peer.accept(deviceId: deviceId, myToken: token)
    return VoidResult(ok: true)
  }

  func declineRequest(deviceId: String) throws -> VoidResult {
    peer.decline(deviceId: deviceId)
    return VoidResult(ok: true)
  }

  func exchangeTokens(
    deviceId: String,
    myToken: TokenPayload,
    completion: @escaping (Result<TokenPayload, Error>) -> Void
  ) {
    let token = myToken.bytes.data
    pendingExchanges[deviceId] = completion
    let onPeer: (Data) -> Void = { [weak self] bytes in
      guard let self = self else { return }
      self.peerTokens[deviceId] = bytes
      if let pending = self.pendingExchanges.removeValue(forKey: deviceId) {
        pending(.success(TokenPayload(
          bytes: FlutterStandardTypedData(bytes: bytes)
        )))
      }
    }
    let onErr: (String) -> Void = { [weak self] message in
      guard let self = self else { return }
      if let pending = self.pendingExchanges.removeValue(forKey: deviceId) {
        pending(.failure(PluginError.transport(message)))
      }
    }
    // Token exchange on iOS only happens with iOS peers via `PeerOob`.
    // Accessory ranging uses the Apple FiRa handshake driven by
    // `IosAccessoryStrategy`, not a token exchange.
    peer.exchange(
      deviceId: deviceId,
      myToken: token,
      onPeer: onPeer,
      onErr: onErr
    )
  }

  // MARK: - UWB

  func isUwbAvailable(completion: @escaping (Result<Bool, Error>) -> Void) {
    #if targetEnvironment(simulator)
    // The iOS simulator stubs `NISession.isSupported` as `true` but cannot
    // actually run UWB ranging. Be honest with callers.
    completion(.success(false))
    return
    #else
    completion(.success(
      NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    ))
    #endif
  }

  func getLocalToken(role: UwbRole, completion: @escaping (Result<TokenPayload, Error>) -> Void) {
    // On iOS the role does not affect the token: NIDiscoveryToken is opaque
    // and NI sessions are symmetric.
    let session = localTokenSession ?? NISession()
    localTokenSession = session
    guard let token = session.discoveryToken else {
      completion(.failure(PluginError.tokenUnavailable))
      return
    }
    do {
      let bytes = try NSKeyedArchiver.archivedData(
        withRootObject: token,
        requiringSecureCoding: true
      )
      completion(.success(TokenPayload(bytes: FlutterStandardTypedData(bytes: bytes))))
    } catch {
      completion(.failure(error))
    }
  }

  func startRanging(
    deviceId: String,
    options: RangingOptions,
    completion: @escaping (Result<VoidResult, Error>) -> Void
  ) {
    // `options` (cameraAssist / extendedDistance) is wired into the
    // NI configurations downstream.
    activeStrategy?.stop()
    activeStrategy = nil

    guard let device = discovered[deviceId] else {
      completion(.success(VoidResult(
        ok: false,
        error: "Unknown deviceId \(deviceId). Run startDiscovery first."
      )))
      return
    }

    do {
      let strategy = try makeStrategy(for: device, options: options)
      activeStrategy = strategy
      try strategy.start()
      completion(.success(VoidResult(ok: true)))
    } catch let pluginError as PluginError {
      activeStrategy = nil
      completion(.success(VoidResult(
        ok: false,
        error: pluginError.errorDescription ?? "startRanging failed"
      )))
    } catch {
      activeStrategy = nil
      completion(.failure(error))
    }
  }

  func stopRanging(completion: @escaping (Result<VoidResult, Error>) -> Void) {
    activeStrategy?.stop()
    activeStrategy = nil
    // The strategy invalidated the underlying NISession (it shared the
    // same instance as `localTokenSession`). NI sessions cannot be reused
    // after `invalidate()`, so drop the cached reference — the next
    // `getLocalToken` call must create a fresh one. Required for
    // camera-assisted ranging: NI rejects -5883 InvalidARConfiguration if
    // the session has already had `run()` called on it.
    localTokenSession = nil
    completion(.success(VoidResult(ok: true)))
  }

  func getDeviceCapabilities(
    completion: @escaping (Result<DeviceCapabilities, Error>) -> Void
  ) {
    let dc = NISession.deviceCapabilities
    // `supportsExtendedDistanceMeasurement` only exists on iOS 17.4+.
    let extendedDistance: Bool = {
      if #available(iOS 17.0, *) {
        return dc.supportsExtendedDistanceMeasurement
      }
      return false
    }()
    let caps = DeviceCapabilities(
      supportsPreciseDistance: dc.supportsPreciseDistanceMeasurement,
      supportsDirection: dc.supportsDirectionMeasurement,
      supportsCameraAssist: dc.supportsCameraAssistance,
      supportsExtendedDistance: extendedDistance,
      // Channel/config-id introspection is Android-only; NI hides those.
      supportedChannels: [],
      supportedConfigIds: [],
      minRangingIntervalMs: nil,
      // Apple-side AoA is implicit when `supportsDirectionMeasurement`
      // is true; we mirror it here for callers that key off `supportsAoa`.
      supportsAoa: dc.supportsDirectionMeasurement
    )
    completion(.success(caps))
  }

  // MARK: - Helpers

  private func makeStrategy(
    for device: UwbDevice,
    options: RangingOptions
  ) throws -> RangingStrategy {
    let platform = device.platform
    switch platform {
    case "ios", "android":
      guard let bytes = peerTokens[device.id] else {
        throw PluginError.transport(
          "No peer token for \(device.id). "
            + "Run exchangeTokens (or acceptRequest) first."
        )
      }
      return IosPeerStrategy(
        deviceId: device.id,
        peerTokenBytes: bytes,
        flutterApi: flutterApi,
        cameraAssist: options.cameraAssist,
        extendedDistance: options.extendedDistance,
        existingSession: localTokenSession
      )
    case let p where p == "accessory" || p.hasPrefix("accessory:"):
      return IosAccessoryStrategy(
        deviceId: device.id,
        flutterApi: flutterApi,
        ble: ble,
        cameraAssist: options.cameraAssist
      )
    default:
      throw PluginError.transport("Unknown peer platform: \(platform)")
    }
  }

  private func failPendingExchanges(with error: Error) {
    for completion in pendingExchanges.values { completion(.failure(error)) }
    pendingExchanges.removeAll()
  }
}

// MARK: - PluginError

enum PluginError: LocalizedError {
  case cancelled
  case notDiscovering
  case tokenUnavailable
  case transport(String)

  var errorDescription: String? {
    switch self {
    case .cancelled:        return "Operation cancelled"
    case .notDiscovering:   return "Discovery is not active"
    case .tokenUnavailable: return "Local NIDiscoveryToken not available"
    case .transport(let m): return m
    }
  }
}

// MARK: - BleOob.Callback / PeerOob.Callback

extension UwbHostApiImpl: BleOob.Callback, PeerOob.Callback {
  // MARK: PeerOob — iOS↔iOS peer discovery + token exchange

  func onPeerDeviceFound(id: String, name: String, capability: UInt8) {
    let platform = OobCapability.toIosPlatform(capability)
    let device = UwbDevice(id: id, name: name, platform: platform)
    let isNew = discovered[id] == nil
    discovered[id] = device
    if isNew {
      flutterApi.onDeviceFound(device: device) { _ in }
    }
  }

  func onPeerDeviceLost(id: String) {
    if discovered.removeValue(forKey: id) != nil {
      flutterApi.onDeviceLost(deviceId: id) { _ in }
    }
    peerTokens.removeValue(forKey: id)
    if let pending = pendingExchanges.removeValue(forKey: id) {
      pending(.failure(PluginError.cancelled))
    }
  }

  func onIncomingRequest(id: String, name: String, peerToken: Data) {
    // Incoming MPC requests only originate from same-OS iOS peers.
    let device = UwbDevice(id: id, name: name, platform: "ios")
    let isNew = discovered[id] == nil
    discovered[id] = device
    peerTokens[id] = peerToken
    if isNew {
      flutterApi.onDeviceFound(device: device) { _ in }
    }
    flutterApi.onIncomingRequest(
      device: device,
      peerToken: TokenPayload(bytes: FlutterStandardTypedData(bytes: peerToken))
    ) { _ in }
  }

  func onConnected(id: String, name: String) {
    // no-op
  }

  func onDisconnected(id: String, name: String) {
    if discovered.removeValue(forKey: id) != nil {
      flutterApi.onDeviceLost(deviceId: id) { _ in }
    }
    peerTokens.removeValue(forKey: id)
    if let pending = pendingExchanges.removeValue(forKey: id) {
      pending(.failure(PluginError.cancelled))
    }
    if activeStrategy?.deviceId == id {
      activeStrategy?.stop()
      activeStrategy = nil
    }
  }

  func onError(_ message: String) {
    let id = activeStrategy?.deviceId ?? "ble"
    flutterApi.onRangingError(
      deviceId: id,
      error: RangingError(code: .transportError, message: message)
    ) { _ in }
  }

  // MARK: BleOob — FiRa accessory discovery + GATT notifications

  func onAccessoryFound(id: String, name: String, serviceUuid: String) {
    let vendorTag = registeredProfiles[serviceUuid.uppercased()]?.vendorTag
    let platform = vendorTag.map { "accessory:\($0)" } ?? "accessory"
    let device = UwbDevice(id: id, name: name, platform: platform)
    let isNew = discovered[id] == nil
    discovered[id] = device
    if isNew {
      flutterApi.onDeviceFound(device: device) { _ in }
    }
  }

  func onSymmetricPeerFound(id: String, name: String, capability: UInt8) {
    let platform = OobCapability.toIosPlatform(capability)
    let device = UwbDevice(id: id, name: name, platform: platform)
    let isNew = discovered[id] == nil
    discovered[id] = device
    if isNew {
      flutterApi.onDeviceFound(device: device) { _ in }
    }
  }

  func onAccessoryNotify(id: String, bytes: Data) {
    guard let strategy = activeStrategy as? IosAccessoryStrategy,
          strategy.deviceId == id else {
      return
    }
    strategy.handleAccessoryNotify(bytes)
  }
}
