import Flutter
import Foundation
import NearbyInteraction

/// iOS↔iOS ranging.
///
/// Uses `NINearbyPeerConfiguration(peerToken:)` with a peer-supplied
/// `NIDiscoveryToken` (delivered via the BLE OOB exchange and cached on the
/// host). This is the original v1 path, factored out of `UwbHostApiImpl` so
/// strategy selection at the host can stay flat.
@available(iOS 14.0, *)
final class IosPeerStrategy: NSObject, RangingStrategy, NISessionDelegate {
  let deviceId: String

  private let peerTokenBytes: Data
  private let flutterApi: UwbFlutterApi
  private var session: NISession?

  /// - Parameters:
  ///   - deviceId: Stable peer id used for sample routing on the Dart side.
  ///   - peerTokenBytes: NSKeyedArchiver-encoded `NIDiscoveryToken` from the
  ///     peer (received over BLE during the OOB exchange).
  ///   - flutterApi: Pigeon API used to push samples / errors / peer-lost
  ///     events into Dart.
  init(
    deviceId: String,
    peerTokenBytes: Data,
    flutterApi: UwbFlutterApi
  ) {
    self.deviceId = deviceId
    self.peerTokenBytes = peerTokenBytes
    self.flutterApi = flutterApi
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
    let s = NISession()
    s.delegate = self
    self.session = s
    s.run(NINearbyPeerConfiguration(peerToken: peerToken))
  }

  func stop() {
    session?.invalidate()
    session = nil
  }

  // MARK: - NISessionDelegate

  func session(
    _ session: NISession,
    didUpdate nearbyObjects: [NINearbyObject]
  ) {
    for object in nearbyObjects {
      flutterApi.onRangingSample(
        sample: makeSample(deviceId: deviceId, object: object)
      ) { _ in }
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
        message: error.localizedDescription
      ) { _ in }
    }
  }

  func session(_ session: NISession, didInvalidateWith error: Error) {
    flutterApi.onRangingError(
      deviceId: deviceId,
      message: error.localizedDescription
    ) { _ in }
  }
}
