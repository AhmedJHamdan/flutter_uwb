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
/// **Discovery / OOB transport** uses BLE GATT via `BleOob.swift` — the same
/// custom service + characteristic UUIDs as the Android `BleOob.kt`. Each
/// peer found by `CBCentralManager` becomes a `UwbDevice` keyed by the
/// peripheral's `identifier.uuidString`; peripheral-side requests are keyed
/// by the connected central's `identifier.uuidString`.
///
/// **UWB ranging** is dispatched by `UwbDevice.platform`:
/// - `"ios"` / `"android"` → `IosPeerStrategy` (NINearbyPeerConfiguration).
/// - `"accessory"`         → `IosAccessoryStrategy` (NINearbyAccessoryConfiguration
///   over Apple's FiRa accessory BLE protocol).
@available(iOS 14.0, *)
final class UwbHostApiImpl: NSObject, UwbHostApi {
  private let flutterApi: UwbFlutterApi

  private let ble = BleOob()

  /// Devices observed via BLE OOB, keyed by BLE id.
  private var discovered: [String: UwbDevice] = [:]

  private var peerTokens: [String: Data] = [:]
  private var pendingExchanges: [String: (Result<TokenPayload, Error>) -> Void] = [:]
  private var localTokenSession: NISession?
  private var activeStrategy: RangingStrategy?

  init(messenger: FlutterBinaryMessenger) {
    self.flutterApi = UwbFlutterApi(binaryMessenger: messenger)
    super.init()
    ble.callback = self
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
    ble.start(
      localName: localName,
      accessoryProfiles: bleAccessoryProfiles()
    )
    return VoidResult(ok: true)
  }

  func registerAccessoryProfile(profile: AccessoryProfile) throws -> VoidResult {
    guard let svc = profile.serviceUuid,
          let rx = profile.rxUuid,
          let tx = profile.txUuid else {
      return VoidResult(
        ok: false,
        error: "AccessoryProfile requires serviceUuid, rxUuid, and txUuid"
      )
    }
    let key = svc.uppercased()
    let bleProfile = BleOob.AccessoryProfile(
      serviceUuid: CBUUID(string: svc),
      rxUuid: CBUUID(string: rx),
      txUuid: CBUUID(string: tx)
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
    discovered.removeAll()
    peerTokens.removeAll()
    failPendingExchanges(with: PluginError.cancelled)
    return VoidResult(ok: true)
  }

  func getDiscovered() throws -> [UwbDevice] {
    return Array(discovered.values)
  }

  func acceptRequest(deviceId: String, myToken: TokenPayload) throws -> VoidResult {
    let token = myToken.bytes?.data ?? Data()
    ble.accept(deviceId: deviceId, myToken: token)
    return VoidResult(ok: true)
  }

  func declineRequest(deviceId: String) throws -> VoidResult {
    ble.decline(deviceId: deviceId)
    return VoidResult(ok: true)
  }

  func exchangeTokens(
    deviceId: String,
    myToken: TokenPayload,
    completion: @escaping (Result<TokenPayload, Error>) -> Void
  ) {
    let token = myToken.bytes?.data ?? Data()
    pendingExchanges[deviceId] = completion
    ble.exchange(
      deviceId: deviceId,
      myToken: token,
      onPeer: { [weak self] bytes in
        guard let self = self else { return }
        self.peerTokens[deviceId] = bytes
        if let pending = self.pendingExchanges.removeValue(forKey: deviceId) {
          pending(.success(TokenPayload(
            bytes: FlutterStandardTypedData(bytes: bytes)
          )))
        }
      },
      onErr: { [weak self] message in
        guard let self = self else { return }
        if let pending = self.pendingExchanges.removeValue(forKey: deviceId) {
          pending(.failure(PluginError.transport(message)))
        }
      }
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
    let supported: Bool
    if #available(iOS 16.0, *) {
      supported = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    } else {
      supported = NISession.isSupported
    }
    completion(.success(supported))
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

  func startRanging(deviceId: String, completion: @escaping (Result<VoidResult, Error>) -> Void) {
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
      let strategy = try makeStrategy(for: device)
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
    completion(.success(VoidResult(ok: true)))
  }

  // MARK: - Helpers

  private func makeStrategy(for device: UwbDevice) throws -> RangingStrategy {
    switch device.platform ?? "ios" {
    case "ios", "android":
      guard let bytes = peerTokens[device.id ?? ""] else {
        throw PluginError.transport(
          "No peer token for \(device.id ?? "?"). "
            + "Run exchangeTokens (or acceptRequest) first."
        )
      }
      return IosPeerStrategy(
        deviceId: device.id ?? "",
        peerTokenBytes: bytes,
        flutterApi: flutterApi
      )
    case "accessory":
      guard #available(iOS 15.0, *) else {
        throw PluginError.transport(
          "Accessory ranging requires iOS 15.0 or newer."
        )
      }
      return IosAccessoryStrategy(
        deviceId: device.id ?? "",
        flutterApi: flutterApi,
        ble: ble
      )
    default:
      throw PluginError.transport(
        "Unknown peer platform: \(device.platform ?? "<nil>")"
      )
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

// MARK: - BleOob.Callback

@available(iOS 14.0, *)
extension UwbHostApiImpl: BleOob.Callback {
  func onDeviceFound(id: String, name: String) {
    let device = UwbDevice(id: id, name: name, platform: "ios")
    let isNew = discovered[id] == nil
    discovered[id] = device
    if isNew {
      flutterApi.onDeviceFound(device: device) { _ in }
    }
  }

  func onIncomingRequest(id: String, name: String, peerToken: Data) {
    let device = UwbDevice(id: id, name: name, platform: "ios")
    let isNew = discovered[id] == nil
    discovered[id] = device
    peerTokens[id] = peerToken
    if isNew {
      flutterApi.onDeviceFound(device: device) { _ in }
    }
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
    flutterApi.onRangingError(deviceId: id, message: message) { _ in }
  }

  // Accessory mode -----------------------------------------------------

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

  func onAccessoryNotify(id: String, bytes: Data) {
    guard #available(iOS 15.0, *) else { return }
    guard let strategy = activeStrategy as? IosAccessoryStrategy,
          strategy.deviceId == id else {
      return
    }
    strategy.handleAccessoryNotify(bytes)
  }
}
