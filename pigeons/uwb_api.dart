// ignore_for_file: depend_on_referenced_packages
// pigeon is a dev_dependency used only for code generation.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/uwb.g.dart',
    kotlinOut:
        'android/src/main/kotlin/com/ahmedhamdan/flutter_uwb/UwbPigeon.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.ahmedhamdan.flutter_uwb'),
    swiftOut: 'ios/Classes/UwbPigeon.g.swift',
  ),
)
class UwbDevice {
  UwbDevice({
    required this.id,
    required this.name,
    required this.platform,
  });

  String id;
  String name;
  String platform;
}

/// BLE service + characteristic triplet describing an accessory.
///
/// `serviceUuid` is the GATT service the iPhone/Android scans for and
/// connects to. `rxUuid` is the characteristic the host writes to (the
/// accessory's "Rx"); `txUuid` is the one the accessory pushes via
/// notifications (its "Tx").
///
/// `vendorTag` is appended to `UwbDevice.platform` as `accessory:<tag>` so
/// the Dart side can filter; pass `null` for the built-in Apple-FiRa
/// handling (`UwbDevice.platform == "accessory"`).
class AccessoryProfile {
  AccessoryProfile({
    required this.serviceUuid,
    required this.rxUuid,
    required this.txUuid,
    this.vendorTag,
  });

  String serviceUuid;
  String rxUuid;
  String txUuid;
  String? vendorTag;
}

class TokenPayload {
  TokenPayload({required this.bytes});
  Uint8List bytes;
}

class VoidResult {
  VoidResult({required this.ok, this.error});
  bool ok;
  String? error;
}

/// Role for an OOB token. Encoded into byte 0 of the token blob.
enum UwbRole {
  controller,
  controlee,
}

/// Stable error code surface for the [RangingError] raised from a UWB
/// session. The native sides map their respective platform errors
/// (`RangingResultFailure.reasonCode` / `STATE_CHANGE_REASON_*` on
/// Android; `NIError.Code` / `CBError.Code` on iOS) onto these values.
enum UwbErrorCode {
  /// The OS denied a permission the plugin needs (Bluetooth scan/connect/
  /// advertise, fine location on Android < 12, Nearby Interaction or camera
  /// usage on iOS). Recover by requesting the missing permission and
  /// retrying — the rest of the plugin state is unchanged.
  permissionDenied,

  /// The UWB radio is present but disabled or unavailable (airplane mode,
  /// hardware fault, OS-level toggle). Surface a "turn UWB on" prompt to
  /// the user; nothing the plugin can do programmatically.
  uwbDisabled,

  /// The peer dropped during ranging (out of range, BLE link lost, app on
  /// the other side closed). The session is torn down before this fires;
  /// the only recovery is rediscovery and re-pair.
  peerLost,

  /// UWB use is restricted in the device's current region (Russia,
  /// Indonesia, and a small number of other jurisdictions disable the
  /// radio entirely). Not user-recoverable; surface a region-restriction
  /// notice.
  regionalRestriction,

  /// The platform refused to start the UWB session (invalid token,
  /// channel/preamble mismatch, unsupported config). Usually indicates the
  /// peers disagreed on session parameters; re-pair before retrying.
  sessionInitFailed,

  /// The OOB transport (BLE GATT) failed during a critical exchange —
  /// connection drop mid-handshake, characteristic write failure, GATT
  /// timeout. Retry the operation; if it persists, BLE on one side is in
  /// a bad state.
  transportError,

  /// Catch-all for platform errors the plugin couldn't classify. The
  /// `message` field on [RangingError] / [UwbException] carries the
  /// underlying platform string for debugging.
  unknown,
}

/// Error raised from a UWB session.
class RangingError {
  RangingError({required this.code, required this.message});
  UwbErrorCode code;
  String message;
}

/// Options modulating a ranging session. iOS-only flags are no-ops on
/// Android.
class RangingOptions {
  RangingOptions({this.cameraAssist = false, this.extendedDistance = false});

  /// iOS only. Enables `NINearbyPeerConfiguration.isCameraAssistanceEnabled`.
  /// Requires `NSCameraUsageDescription` in the host app's Info.plist.
  bool cameraAssist;

  /// iOS 17.4+ accessory only. Enables
  /// `NINearbyAccessoryConfiguration.isExtendedDistanceMeasurementEnabled`.
  bool extendedDistance;
}

/// What the local UWB radio supports. Some fields are platform-specific:
/// the iOS-only flags are always `false` on Android, and the Android-only
/// ranging-stack details (channels, config IDs, AoA, min interval) are
/// always empty / zero on iOS.
class DeviceCapabilities {
  DeviceCapabilities({
    required this.supportsPreciseDistance,
    required this.supportsDirection,
    required this.supportsCameraAssist,
    required this.supportsExtendedDistance,
    required this.supportedChannels,
    required this.supportedConfigIds,
    this.minRangingIntervalMs,
    required this.supportsAoa,
  });

  bool supportsPreciseDistance;
  bool supportsDirection;
  bool supportsCameraAssist;
  bool supportsExtendedDistance;
  List<int?> supportedChannels;
  List<int?> supportedConfigIds;
  int? minRangingIntervalMs;
  bool supportsAoa;
}

class RangingSample {
  RangingSample({
    required this.deviceId,
    required this.distanceMeters,
    this.azimuthDegrees,
    this.elevationDegrees,
    required this.elapsedRealtimeNanos,
  });

  String deviceId;
  double distanceMeters;
  double? azimuthDegrees;
  double? elevationDegrees;
  int elapsedRealtimeNanos;
}

@HostApi()
abstract class UwbHostApi {
  // BLE / OOB discovery
  VoidResult startDiscovery(String localName);
  VoidResult stopDiscovery();
  List<UwbDevice> getDiscovered();
  VoidResult acceptRequest(String deviceId, TokenPayload myToken);
  VoidResult declineRequest(String deviceId);

  // Accessory profile registration. The host scans for every registered
  // service UUID in addition to the built-in flutter_uwb peer service.
  // Profiles are kept across stop/start cycles; call
  // `unregisterAccessoryProfile` to remove one.
  VoidResult registerAccessoryProfile(AccessoryProfile profile);
  VoidResult unregisterAccessoryProfile(String serviceUuid);

  // Token exchange does BLE I/O and must be async.
  @async
  TokenPayload exchangeTokens(String deviceId, TokenPayload myToken);

  // UWB ranging
  @async
  bool isUwbAvailable();

  /// Returns the platform-native OOB token to share with the peer.
  /// On Android the format is the 9-byte little-endian blob:
  ///   [0]   role (0=controller, 1=controlee)
  ///   [1..2] shortAddr (u16)
  ///   [3]   channel (u8, controller only)
  ///   [4]   preambleIndex (u8, controller only)
  ///   [5..8] sessionId (u32, controller only)
  /// On iOS the bytes are an `NSKeyedArchiver`-encoded `NIDiscoveryToken`.
  @async
  TokenPayload getLocalToken(UwbRole role);

  @async
  VoidResult startRanging(String deviceId, RangingOptions options);

  @async
  VoidResult stopRanging();

  /// Snapshot of the local UWB radio's capabilities. Returns the
  /// platform-specific profile (iOS-only fields are false on Android,
  /// Android-only fields are empty on iOS).
  @async
  DeviceCapabilities getDeviceCapabilities();
}

/// Callbacks from the host platform up to Dart.
@FlutterApi()
abstract class UwbFlutterApi {
  void onDeviceFound(UwbDevice device);
  void onDeviceLost(String deviceId);
  void onRangingSample(RangingSample sample);
  void onPeerLost(String deviceId);
  void onRangingError(String deviceId, RangingError error);
  void onIncomingRequest(UwbDevice device, TokenPayload peerToken);
}
