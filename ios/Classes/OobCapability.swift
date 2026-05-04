import Foundation

/// 1-byte capability flag advertised in the out-of-band channel so the
/// local stack can route iOS↔Android pairs through accessory mode and
/// keep same-OS pairs on peer mode without guessing.
///
/// Mirrors `lib/src/oob_capability.dart` and `OobCapability.kt`.
/// Reserved values `0x03`–`0xFF` map to [unknownDefault] so 0.3.x
/// peers (which never advertised this flag) keep working.
enum OobCapability {
  static let iosPeer: UInt8 = 0x01
  static let androidPeer: UInt8 = 0x02
  static let accessoryHost: UInt8 = 0x03

  /// Applied when the remote omits the capability byte.
  static let unknownDefault: UInt8 = iosPeer

  /// Encoded form for `MCNearbyServiceAdvertiser.discoveryInfo`. MPC
  /// requires `[String: String]`, so we hex-encode the byte.
  static let discoveryInfoKey = "caps"

  static func discoveryInfo() -> [String: String] {
    return [discoveryInfoKey: hex(iosPeer)]
  }

  static func parseDiscoveryInfo(_ info: [String: String]?) -> UInt8 {
    guard let raw = info?[discoveryInfoKey] else { return unknownDefault }
    return parseHex(raw) ?? unknownDefault
  }

  /// Map a remote capability byte to the `UwbDevice.platform` string
  /// used by the strategy dispatcher when the local stack is iOS.
  ///
  /// - Remote Android peer → `accessory:android` so the existing
  ///   dispatcher sends it to `IosAccessoryStrategy`.
  /// - Anything else → `ios` (peer mode).
  static func toIosPlatform(_ capability: UInt8) -> String {
    switch capability {
    case androidPeer: return "accessory:android"
    default: return "ios"
    }
  }

  // MARK: - Hex helpers

  private static func hex(_ b: UInt8) -> String {
    return String(format: "0x%02X", b)
  }

  private static func parseHex(_ raw: String) -> UInt8? {
    var s = raw.lowercased()
    if s.hasPrefix("0x") { s.removeFirst(2) }
    return UInt8(s, radix: 16)
  }
}
