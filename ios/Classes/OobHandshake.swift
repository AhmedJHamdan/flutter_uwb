import CryptoKit
import Foundation

/// X25519 ECDH + HKDF-SHA256, mirror of `OobHandshake.kt`.
///
/// Reserved for future iOS↔Android peer pairing over a shared BLE
/// transport. The current 0.4.0 release routes cross-OS pairs through
/// the Apple FiRa accessory protocol (which has its own STS material
/// supplied by `NISession`), so this struct is not on any active code
/// path yet — it is published so both sides agree on the wire format
/// the moment a shared BLE peer-mode transport lands.
///
/// Wire format (matches Kotlin):
/// - 32-byte X25519 raw public key (RFC 7748 little-endian).
/// - HKDF-SHA256 with `salt = "flutter_uwb v1 hkdf salt"` and
///   info strings `"flutter_uwb v1 session key"` /
///   `"flutter_uwb v1 mac key"` derives a 16-byte UWB session key
///   plus a 16-byte HMAC-SHA256 key.
/// - Token wrap: `[16-byte truncated HMAC-SHA256 tag || token bytes]`.
@available(iOS 16.0, *)
enum OobHandshake {
  static let publicKeyLength = 32
  static let macTagLength = 16
  static let sessionKeyLength = 16
  static let macKeyLength = 16

  private static let hkdfSalt = "flutter_uwb v1 hkdf salt".data(using: .utf8)!
  private static let hkdfSession = "flutter_uwb v1 session key".data(using: .utf8)!
  private static let hkdfMac = "flutter_uwb v1 mac key".data(using: .utf8)!

  struct SessionKeys {
    let sessionKey: Data
    let macKey: Data
  }

  struct LocalKeyPair {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Data
  }

  static func generateKeyPair() -> LocalKeyPair {
    let priv = Curve25519.KeyAgreement.PrivateKey()
    return LocalKeyPair(
      privateKey: priv,
      publicKey: priv.publicKey.rawRepresentation
    )
  }

  static func derive(
    localPrivate: Curve25519.KeyAgreement.PrivateKey,
    peerPublicBytes: Data
  ) throws -> SessionKeys {
    let peerPub = try Curve25519.KeyAgreement.PublicKey(
      rawRepresentation: peerPublicBytes
    )
    let shared = try localPrivate.sharedSecretFromKeyAgreement(with: peerPub)
    let sessionKey = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: hkdfSalt,
      sharedInfo: hkdfSession,
      outputByteCount: sessionKeyLength
    ).withUnsafeBytes { Data($0) }
    let macKey = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: hkdfSalt,
      sharedInfo: hkdfMac,
      outputByteCount: macKeyLength
    ).withUnsafeBytes { Data($0) }
    return SessionKeys(sessionKey: sessionKey, macKey: macKey)
  }

  static func wrapToken(macKey: Data, token: Data) -> Data {
    let key = SymmetricKey(data: macKey)
    let mac = HMAC<SHA256>.authenticationCode(for: token, using: key)
    let tag = Data(mac).prefix(macTagLength)
    return tag + token
  }

  static func unwrapToken(macKey: Data, payload: Data) -> Data? {
    guard payload.count > macTagLength else { return nil }
    let tag = payload.prefix(macTagLength)
    let token = payload.suffix(from: macTagLength)
    let key = SymmetricKey(data: macKey)
    let expected = Data(HMAC<SHA256>.authenticationCode(
      for: token,
      using: key
    )).prefix(macTagLength)
    guard constantTimeEquals(tag, expected) else { return nil }
    return Data(token)
  }

  private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
    return diff == 0
  }
}
