/// 1-byte capability flag advertised by every flutter_uwb peer in its
/// out-of-band channel (BLE service-data on Android,
/// `MCNearbyServiceAdvertiser.discoveryInfo` on iOS).
///
/// The flag tells the local stack what the remote peer can negotiate so
/// that cross-OS pairs auto-route to accessory mode and same-OS pairs
/// stay in peer mode without guessing.
///
/// Wire layout (Android BLE service-data, payload of the advertised
/// service UUID): a single byte `[caps]`.
///
/// Wire layout (iOS MPC `discoveryInfo`): `{"caps": "0x01"}` — string
/// to satisfy MPC's `[String: String]` constraint.
///
/// Reserved values `0x03`–`0xFF` are for future kinds; unknown values
/// MUST be treated as [androidPeer] for back-compat with 0.3.x peers
/// that did not advertise a capability byte at all.
class OobCapability {
  OobCapability._();

  /// iOS peer (NearbyInteraction over MultipeerConnectivity).
  static const int iosPeer = 0x01;

  /// Android peer (Jetpack UWB over BLE).
  static const int androidPeer = 0x02;

  /// Reserved for accessory hosts (e.g., a phone exposing the Apple
  /// FiRa accessory protocol to a third-party UWB tag).
  static const int accessoryHost = 0x03;

  /// Default applied to peers that do not advertise a capability byte.
  ///
  /// Pre-0.4.0 builds only ran on Android, so the safe assumption is
  /// [androidPeer].
  static const int unknownDefault = androidPeer;
}
