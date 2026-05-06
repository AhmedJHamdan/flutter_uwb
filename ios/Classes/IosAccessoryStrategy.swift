import ARKit
import Flutter
import Foundation
import NearbyInteraction

/// iOS↔accessory ranging via Apple's FiRa accessory BLE protocol.
///
/// The protocol is documented in `lib/src/accessory/apple_protocol.dart` and
/// Apple's WWDC 2022 *"Implementing Spatial Interactions with Third-Party
/// Accessories Using the U1 Chip"*. This class drives the handshake on the
/// iPhone (controller) side.
///
/// ## Pairing flow
///
/// 1. `start()` → `BleOob.accessoryConnect(deviceId:onReady:)` opens a GATT
///    connection and subscribes to the accessory's Tx characteristic.
/// 2. On ready, write `Initialize` (0x0A) to the accessory's Rx.
/// 3. Accessory pushes `AccessoryConfigurationData` (0x01) via Tx.
///    `handleAccessoryNotify(_:)` parses the payload into
///    `NINearbyAccessoryConfiguration(data:)`.
/// 4. Run the `NISession`. NI calls
///    `session(_:didGenerateShareableConfigurationData:for:)` with bytes the
///    accessory needs to align its radio.
/// 5. Write `ConfigureAndStart` (0x0B + shareable bytes) to the accessory.
/// 6. Accessory pushes `AccessoryUwbDidStart` (0x02). The `NISession` is
///    already running; samples flow through `session(_:didUpdate:)`.
/// 7. `stop()` invalidates the session, writes `Stop` (0x0C), and disconnects.
///
/// Requires iOS 15+; older devices fall back to peer-mode only.
final class IosAccessoryStrategy: NSObject, RangingStrategy, NISessionDelegate,
  ARSessionDelegate
{
  let deviceId: String

  private let flutterApi: UwbFlutterApi
  private weak var ble: BleOob?
  private let cameraAssist: Bool

  private var session: NISession?
  private var arSession: ARSession?
  /// Held until the AR session delivers its first frame, then consumed by
  /// the AR delegate to start NI ranging. NI rejects camera-assist configs
  /// when the AR session has no frames yet (NIErrorCodeInvalidARConfiguration
  /// / `invalidARSessionDescription`).
  private var pendingNIConfig: NINearbyAccessoryConfiguration?
  /// State machine for the multi-message handshake.
  private enum State {
    case idle
    case awaitingAccessoryConfig
    case awaitingDidStart
    case ranging
    case stopping
  }
  private var state: State = .idle

  /// - Parameter ble: Held weakly because `BleOob` is owned by the host
  ///   plugin and outlives any single ranging session.
  init(
    deviceId: String,
    flutterApi: UwbFlutterApi,
    ble: BleOob,
    cameraAssist: Bool = false
  ) {
    self.deviceId = deviceId
    self.flutterApi = flutterApi
    self.ble = ble
    self.cameraAssist = cameraAssist
    super.init()
  }

  // MARK: - RangingStrategy

  func start() throws {
    state = .awaitingAccessoryConfig
    ble?.accessoryConnect(deviceId: deviceId) { [weak self] ready in
      guard let self = self else { return }
      if !ready {
        self.fail("BLE not ready for \(self.deviceId)")
        return
      }
      self.writeMessage(.initialize)
    }
  }

  func stop() {
    let wasActive = state != .idle && state != .stopping
    state = .stopping
    pendingNIConfig = nil
    session?.invalidate()
    session = nil
    if wasActive { writeMessage(.stop) }
    ble?.accessoryDisconnect(deviceId: deviceId)
    if let ar = arSession {
      // Drop the delegate before pausing so ARKit stops dispatching frames
      // to us. Otherwise the "delegate retaining N ARFrames" warning fires
      // and the camera eventually stalls.
      ar.delegate = nil
      ar.pause()
    }
    arSession = nil
    state = .idle
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard let pending = pendingNIConfig, let ni = self.session else { return }
    pendingNIConfig = nil
    ni.run(pending)
  }

  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
    // NI requires this to be false when sharing the AR session, otherwise
    // NIErrorCodeInvalidARConfiguration (-5883) fires on the NI side.
    return false
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    let nsError = error as NSError
    pendingNIConfig = nil
    fail(
      "ARSession failed: \(nsError.domain) code=\(nsError.code) "
        + "\(error.localizedDescription)"
    )
  }

  // MARK: - Inbound BLE notifications

  /// Called by the host when the BLE transport delivers bytes from the
  /// accessory's Tx characteristic.
  func handleAccessoryNotify(_ bytes: Data) {
    guard let id = bytes.first else { return }
    let payload = bytes.count > 1
      ? bytes.subdata(in: 1..<bytes.count)
      : Data()

    switch (state, AccessoryMessageId(rawValue: id)) {
    case (.awaitingAccessoryConfig, .accessoryConfigurationData):
      do {
        let config = try NINearbyAccessoryConfiguration(data: payload)
        let s = NISession()
        s.delegate = self
        self.session = s
        if cameraAssist {
          // Mirror IosPeerStrategy's AR-first / NI-deferred pattern, otherwise
          // NI invalidates the session with NIErrorCodeInvalidARConfiguration
          // (-5883 / 1100 invalidARSessionDescription).
          config.isCameraAssistanceEnabled = true
          let arConfig = ARWorldTrackingConfiguration()
          arConfig.worldAlignment = .gravity
          arConfig.isCollaborationEnabled = false
          arConfig.userFaceTrackingEnabled = false
          arConfig.initialWorldMap = nil
          let ar = ARSession()
          ar.delegate = self
          ar.run(arConfig)
          arSession = ar
          s.setARSession(ar)
          // Defer s.run(config) to ARSessionDelegate.session(_:didUpdate:).
          pendingNIConfig = config
        } else {
          s.run(config)
        }
      } catch {
        fail("NINearbyAccessoryConfiguration: \(error.localizedDescription)")
      }

    case (.awaitingDidStart, .accessoryUwbDidStart):
      state = .ranging

    case (.ranging, .accessoryUwbDidStop):
      // Accessory tore the radio down on its end. Treat as peer lost.
      flutterApi.onPeerLost(deviceId: deviceId) { _ in }

    default:
      // Out-of-order or unknown id; ignore. A spec-compliant accessory
      // shouldn't reach this branch under the v2 contract.
      break
    }
  }

  // MARK: - NISessionDelegate

  func session(
    _ session: NISession,
    didGenerateShareableConfigurationData shareableConfigurationData: Data,
    for object: NINearbyObject
  ) {
    state = .awaitingDidStart
    var msg = Data([AccessoryMessageId.configureAndStart.rawValue])
    msg.append(shareableConfigurationData)
    ble?.accessoryWrite(deviceId: deviceId, bytes: msg)
  }

  func session(
    _ session: NISession,
    didUpdate nearbyObjects: [NINearbyObject]
  ) {
    for object in nearbyObjects {
      guard let sample = makeSample(deviceId: deviceId, object: object) else {
        continue
      }
      flutterApi.onRangingSample(sample: sample) { _ in }
    }
  }

  func session(
    _ session: NISession,
    didRemove nearbyObjects: [NINearbyObject],
    reason: NINearbyObject.RemovalReason
  ) {
    flutterApi.onPeerLost(deviceId: deviceId) { _ in }
  }

  func sessionWasSuspended(_ session: NISession) {}
  func sessionSuspensionEnded(_ session: NISession) {
    // The accessory-side handshake must be redone after a suspension.
    do {
      try start()
    } catch {
      fail(error.localizedDescription)
    }
  }

  func session(_ session: NISession, didInvalidateWith error: Error) {
    fail(error.localizedDescription)
  }

  // MARK: - Helpers

  private func writeMessage(_ id: AccessoryMessageId, payload: Data = Data()) {
    var bytes = Data([id.rawValue])
    bytes.append(payload)
    ble?.accessoryWrite(deviceId: deviceId, bytes: bytes)
  }

  private func fail(_ message: String) {
    flutterApi.onRangingError(
      deviceId: deviceId,
      error: RangingError(code: .sessionInitFailed, message: message)
    ) { _ in }
  }
}

/// Mirror of `AppleAccessoryMessageId` in `apple_protocol.dart`.
enum AccessoryMessageId: UInt8 {
  case accessoryConfigurationData = 0x01
  case accessoryUwbDidStart = 0x02
  case accessoryUwbDidStop = 0x03
  case initialize = 0x0A
  case configureAndStart = 0x0B
  case stop = 0x0C
}
