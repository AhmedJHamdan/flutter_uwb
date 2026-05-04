import Foundation
import NearbyInteraction

/// One per-peer UWB ranging strategy.
///
/// Each `RangingStrategy` owns its own `NISession`, drives the platform-side
/// configuration appropriate for the peer kind, and emits samples / errors
/// through the host's `UwbFlutterApi`. The host (`UwbHostApiImpl`) selects a
/// concrete strategy based on `UwbDevice.platform` and forwards lifecycle
/// events.
protocol RangingStrategy: AnyObject {
  /// The peer this strategy is talking to. Used by the host as a routing
  /// key when matching incoming events back to the right strategy.
  var deviceId: String { get }

  /// Begin ranging. The strategy is responsible for any platform-side
  /// handshake (peer mode: build `NINearbyPeerConfiguration` and run
  /// immediately; accessory mode: drive the Apple-spec multi-message BLE
  /// handshake before starting the session).
  func start() throws

  /// Tear down ranging. After `stop()` the strategy is dead — the host
  /// allocates a new instance for the next session.
  func stop()
}

/// Build a Pigeon `RangingSample` from an `NINearbyObject`.
///
/// Shared across strategies — the geometry derivation is identical regardless
/// of whether the peer is another iPhone or a FiRa accessory.
func makeSample(deviceId: String, object: NINearbyObject) -> RangingSample? {
  guard let distance = object.distance else { return nil }
  let azimuth: Double? = {
    guard let dir = object.direction else { return nil }
    // Direction is a unit vector in the device's reference frame.
    // azimuth ≈ atan2(x, -z); elevation ≈ asin(y)
    return Double(atan2(dir.x, -dir.z)) * 180.0 / .pi
  }()
  let elevation: Double? = {
    guard let dir = object.direction else { return nil }
    return Double(asin(dir.y)) * 180.0 / .pi
  }()
  return RangingSample(
    deviceId: deviceId,
    distanceMeters: Double(distance),
    azimuthDegrees: azimuth,
    elevationDegrees: elevation,
    elapsedRealtimeNanos: Int64(Date().timeIntervalSince1970 * 1e9)
  )
}
