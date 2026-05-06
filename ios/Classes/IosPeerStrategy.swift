import ARKit
import AVFoundation
import Flutter
import Foundation
import NearbyInteraction

/// iOS↔iOS ranging.
///
/// Uses `NINearbyPeerConfiguration(peerToken:)` with a peer-supplied
/// `NIDiscoveryToken` (delivered via the BLE OOB exchange and cached on the
/// host). This is the original v1 path, factored out of `UwbHostApiImpl` so
/// strategy selection at the host can stay flat.
final class IosPeerStrategy: NSObject, RangingStrategy, NISessionDelegate, ARSessionDelegate {
  let deviceId: String

  private let peerTokenBytes: Data
  private let flutterApi: UwbFlutterApi
  private let cameraAssist: Bool
  private let extendedDistance: Bool
  private var session: NISession?
  /// Held strongly so the AR session keeps publishing into the NI session
  /// for the lifetime of `start()`–`stop()`. Apple's
  /// `NISession.setARSession(_:)` does not retain its argument.
  private var arSession: ARSession?
  /// Held until the AR session delivers its first frame, then consumed by
  /// the AR delegate to start NI ranging. NI rejects camera-assist configs
  /// when the AR session has no frames yet (-5883 InvalidARConfiguration).
  private var pendingNIConfig: NINearbyPeerConfiguration?

  /// - Parameter peerTokenBytes: `NSKeyedArchiver`-encoded `NIDiscoveryToken`
  ///   from the peer, received over BLE during the OOB exchange.
  /// - Parameter cameraAssist: Run an `ARSession` alongside `NISession`
  ///   and set `isCameraAssistanceEnabled = true` on the configuration.
  ///   Required to get continuous direction on iOS 26 / U2 hardware,
  ///   where `NINearbyObject.direction` otherwise reports nil.
  init(
    deviceId: String,
    peerTokenBytes: Data,
    flutterApi: UwbFlutterApi,
    cameraAssist: Bool = false,
    extendedDistance: Bool = false,
    existingSession: NISession? = nil
  ) {
    self.deviceId = deviceId
    self.peerTokenBytes = peerTokenBytes
    self.flutterApi = flutterApi
    self.cameraAssist = cameraAssist
    self.extendedDistance = extendedDistance
    self.session = existingSession
    super.init()
  }

  func start() throws {
    let token = try NSKeyedUnarchiver.unarchivedObject(
      ofClass: NIDiscoveryToken.self,
      from: peerTokenBytes
    )
    guard let peerToken = token else {
      throw PluginError.tokenUnavailable
    }
    let s = session ?? NISession()
    s.delegate = self
    self.session = s

    if cameraAssist {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        break
      case .notDetermined:
        // Kick off the system prompt asynchronously and bail out so the
        // user can tap Allow before retrying. Without this, ARSession.run
        // is called before iOS has a chance to surface the prompt and the
        // NI session invalidates with -5887 (sessionFailed) before the
        // user ever sees the permission dialog.
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        throw PluginError.transport(
          "Camera permission required for Camera assist. Tap Allow when "
            + "prompted, then tap Pair & range again."
        )
      case .denied, .restricted:
        throw PluginError.transport(
          "Camera permission denied. Enable it in Settings → "
            + "flutter_uwb_example → Camera, or turn off Camera assist."
        )
      @unknown default:
        throw PluginError.transport(
          "Camera permission status unknown. Turn off Camera assist or "
            + "grant access in Settings."
        )
      }
    }
    if cameraAssist && extendedDistance {
      throw PluginError.transport(
        "RangingOptions.cameraAssist and .extendedDistance are mutually "
          + "exclusive on NINearbyPeerConfiguration: extended distance "
          + "trades direction (AoA) for range, while camera assist "
          + "provides direction. Pick one."
      )
    }
    let config = NINearbyPeerConfiguration(peerToken: peerToken)
    if extendedDistance {
      if #available(iOS 17.0, *) {
        config.isExtendedDistanceMeasurementEnabled = true
      } else {
        throw PluginError.transport(
          "RangingOptions.extendedDistance requires iOS 17.0 or newer."
        )
      }
    }
    if cameraAssist {
      // Tear down any AR session left over from a previous start() —
      // notably from sessionSuspensionEnded re-entering this path.
      // Without this, the old delegate keeps receiving frames and ARKit
      // accumulates them ("delegate retaining N ARFrames").
      if let old = arSession {
        old.delegate = nil
        old.pause()
        arSession = nil
      }
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
      config.isCameraAssistanceEnabled = true
      // Defer s.run(config) to ARSessionDelegate.session(_:didUpdate:)
      // — NI requires the AR session to be delivering frames first.
      pendingNIConfig = config
    } else {
      s.run(config)
    }
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard let pending = pendingNIConfig, let ni = self.session else { return }
    pendingNIConfig = nil
    ni.run(pending)
  }

  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
    // NI requires this to be false when sharing the AR session, otherwise
    // -5883 (NIErrorCodeInvalidARConfiguration) fires on the NI side.
    return false
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    let nsError = error as NSError
    pendingNIConfig = nil
    flutterApi.onRangingError(
      deviceId: deviceId,
      error: RangingError(
        code: .sessionInitFailed,
        message: "ARSession failed: \(nsError.domain) code=\(nsError.code) "
          + "\(error.localizedDescription)"
      )
    ) { _ in }
  }

  func stop() {
    pendingNIConfig = nil
    session?.invalidate()
    session = nil
    if let ar = arSession {
      // Clear the delegate first — otherwise ARKit can keep dispatching
      // frames after pause(), and ARC won't release them because we still
      // hold a reference here. That's the "delegate retaining N ARFrames"
      // warning, which eventually starves the camera and hangs the app.
      ar.delegate = nil
      ar.pause()
    }
    arSession = nil
  }

  // MARK: - NISessionDelegate

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
    // Re-run with the same token. NI loses session state across the
    // suspend/resume boundary, so a re-run is required to keep samples
    // flowing.
    do {
      try start()
    } catch {
      flutterApi.onRangingError(
        deviceId: deviceId,
        error: RangingError(code: .unknown, message: error.localizedDescription)
      ) { _ in }
    }
  }

  func session(_ session: NISession, didInvalidateWith error: Error) {
    let nsError = error as NSError
    let raw = error.localizedDescription
    // iOS 26 NearbyInteraction returns the raw localization key
    // ("NIERROR_..._DESCRIPTION") instead of a human string. When that
    // happens, surface the NSError code so the caller has something to
    // grep against.
    let message: String
    if raw.hasPrefix("NIERROR_") || raw.isEmpty {
      message = "\(nsError.domain) code=\(nsError.code)"
    } else {
      message = "\(raw) [\(nsError.domain) code=\(nsError.code)]"
    }
    flutterApi.onRangingError(
      deviceId: deviceId,
      error: RangingError(code: .sessionInitFailed, message: message)
    ) { _ in }
  }

}
