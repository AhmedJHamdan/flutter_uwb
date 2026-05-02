// ignore_for_file: depend_on_referenced_packages
// pigeon is a dev_dependency used only for code generation.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/uwb.g.dart',
    kotlinOut: 'android/src/main/kotlin/com/ahmedhamdan/flutter_uwb/UwbPigeon.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.ahmedhamdan.flutter_uwb'),
    swiftOut: 'ios/Classes/UwbPigeon.g.swift',
  ),
)

class UwbDevice {
  String? id;
  String? name;
  String? platform;
}

class TokenPayload {
  Uint8List? bytes;
}

class VoidResult {
  bool? ok;
  String? error;
}

/// Role for an OOB token. Encoded into byte 0 of the token blob.
enum UwbRole {
  controller,
  controlee,
}

class RangingSample {
  String? deviceId;
  double? distanceMeters;
  double? azimuthDegrees;
  double? elevationDegrees;
  int? elapsedRealtimeNanos;
}

@HostApi()
abstract class UwbHostApi {
  // BLE / OOB discovery
  VoidResult startDiscovery(String localName);
  VoidResult stopDiscovery();
  List<UwbDevice> getDiscovered();
  VoidResult acceptRequest(String deviceId, TokenPayload myToken);
  VoidResult declineRequest(String deviceId);

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
  VoidResult startRanging(String deviceId);

  @async
  VoidResult stopRanging();
}

/// Callbacks from the host platform up to Dart.
@FlutterApi()
abstract class UwbFlutterApi {
  void onDeviceFound(UwbDevice device);
  void onDeviceLost(String deviceId);
  void onRangingSample(RangingSample sample);
  void onPeerLost(String deviceId);
  void onRangingError(String deviceId, String message);
}
