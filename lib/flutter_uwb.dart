import 'dart:async';
import 'dart:typed_data';

import 'src/pigeon/uwb.g.dart';

export 'src/pigeon/uwb.g.dart'
    show AccessoryProfile, RangingSample, TokenPayload, UwbDevice, UwbRole;

/// Thrown by [FlutterUwb] when a platform operation fails.
class UwbException implements Exception {
  const UwbException(this.message);

  final String message;

  @override
  String toString() => 'UwbException: $message';
}

/// Public Dart facade for the flutter_uwb plugin.
///
/// Use [FlutterUwb.instance] to access the singleton or construct your own
/// for testing with a custom Pigeon binary messenger.
class FlutterUwb {
  FlutterUwb._() {
    UwbFlutterApi.setup(_FlutterApiHandler(this));
  }

  /// Default singleton.
  static final FlutterUwb instance = FlutterUwb._();

  final UwbHostApi _api = UwbHostApi();

  final StreamController<UwbDevice> _deviceFound =
      StreamController<UwbDevice>.broadcast();
  final StreamController<String> _deviceLost =
      StreamController<String>.broadcast();
  final StreamController<RangingSample> _samples =
      StreamController<RangingSample>.broadcast();
  final StreamController<String> _peerLost =
      StreamController<String>.broadcast();
  final StreamController<RangingErrorEvent> _errors =
      StreamController<RangingErrorEvent>.broadcast();

  /// Devices observed via OOB discovery, fired once per peer the first time
  /// it is seen.
  Stream<UwbDevice> get deviceFound => _deviceFound.stream;

  /// Fired when the OOB transport reports a previously-discovered peer is
  /// no longer reachable.
  Stream<String> get deviceLost => _deviceLost.stream;

  /// Ranging samples streamed from the platform.
  Stream<RangingSample> get rangingSamples => _samples.stream;

  /// Fired when the platform reports a peer is no longer reachable mid-session.
  Stream<String> get peerLost => _peerLost.stream;

  /// Errors raised inside an active ranging session.
  Stream<RangingErrorEvent> get rangingErrors => _errors.stream;

  // -------- Helpers --------

  void _check(VoidResult r) {
    if (!(r.ok ?? false)) throw UwbException(r.error ?? 'unknown error');
  }

  // -------- Discovery / OOB --------

  /// Start BLE OOB discovery, advertising [localName] to nearby peers.
  ///
  /// Throws [UwbException] if BLE is unavailable or already discovering.
  Future<void> startDiscovery(String localName) async =>
      _check(await _api.startDiscovery(localName));

  /// Stop BLE OOB discovery.
  ///
  /// Throws [UwbException] on failure.
  Future<void> stopDiscovery() async => _check(await _api.stopDiscovery());

  /// Snapshot of all peers discovered since the last [startDiscovery] call.
  Future<List<UwbDevice>> getDiscovered() async {
    final list = await _api.getDiscovered();
    return list.whereType<UwbDevice>().toList();
  }

  /// Accept a ranging request from [deviceId], supplying the local UWB token
  /// [myToken] so the peer can start an NISession / Jetpack UWB session.
  ///
  /// Throws [UwbException] on failure.
  Future<void> acceptRequest(String deviceId, Uint8List myToken) async =>
      _check(await _api.acceptRequest(deviceId, TokenPayload(bytes: myToken)));

  /// Decline a ranging request from [deviceId].
  ///
  /// Throws [UwbException] on failure.
  Future<void> declineRequest(String deviceId) async =>
      _check(await _api.declineRequest(deviceId));

  /// Register an accessory profile so the plugin scans for its service UUID
  /// alongside the built-in flutter_uwb peer service.
  ///
  /// `vendorTag` (when non-null) flows through to
  /// `UwbDevice.platform = "accessory:<vendorTag>"`.
  ///
  /// Throws [UwbException] on failure.
  Future<void> registerAccessoryProfile({
    required String serviceUuid,
    required String rxUuid,
    required String txUuid,
    String? vendorTag,
  }) async =>
      _check(
        await _api.registerAccessoryProfile(
          AccessoryProfile(
            serviceUuid: serviceUuid,
            rxUuid: rxUuid,
            txUuid: txUuid,
            vendorTag: vendorTag,
          ),
        ),
      );

  /// Remove a previously-registered accessory profile.
  ///
  /// Throws [UwbException] on failure.
  Future<void> unregisterAccessoryProfile(String serviceUuid) async =>
      _check(await _api.unregisterAccessoryProfile(serviceUuid));

  /// Exchange OOB tokens with [deviceId] in a single BLE round-trip.
  ///
  /// Sends [myToken] to the peer and returns the peer's token. Both sides
  /// must call this before starting a UWB session. For the common case,
  /// prefer [pairWith] which combines this with [getLocalToken].
  ///
  /// Throws [UwbException] if the platform returns an empty token or if
  /// the exchange fails.
  Future<Uint8List> exchangeTokens(String deviceId, Uint8List myToken) async {
    final out = await _api.exchangeTokens(
      deviceId,
      TokenPayload(bytes: myToken),
    );
    final bytes = out.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw const UwbException('exchangeTokens: platform returned empty token');
    }
    return bytes;
  }

  // -------- UWB --------

  /// Returns `true` if the device has a UWB radio and the OS grants access.
  Future<bool> isUwbAvailable() => _api.isUwbAvailable();

  /// Returns the local platform-specific OOB token for [role].
  ///
  /// On Android the bytes are a 9-byte little-endian blob. On iOS they are
  /// an `NSKeyedArchiver`-encoded `NIDiscoveryToken`. For the common case,
  /// prefer [pairWith] which combines this with [exchangeTokens].
  ///
  /// Throws [UwbException] if the token is unavailable.
  Future<Uint8List> getLocalToken(UwbRole role) async {
    final t = await _api.getLocalToken(role);
    final bytes = t.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw const UwbException('getLocalToken: platform returned empty token');
    }
    return bytes;
  }

  /// Convenience method that combines [getLocalToken] and [exchangeTokens]
  /// in a single call.
  ///
  /// After this succeeds call [startRanging] to start the UWB session.
  ///
  /// Throws [UwbException] if token retrieval or exchange fails.
  Future<void> pairWith(
    String deviceId, {
    UwbRole role = UwbRole.controller,
  }) async {
    final myToken = await getLocalToken(role);
    await exchangeTokens(deviceId, myToken);
  }

  /// Begin a UWB ranging session with [deviceId].
  ///
  /// Both sides must have completed token exchange (via [pairWith] or
  /// [exchangeTokens]) first. Samples are emitted on [rangingSamples];
  /// errors on [rangingErrors].
  ///
  /// Throws [UwbException] on failure.
  Future<void> startRanging(String deviceId) async =>
      _check(await _api.startRanging(deviceId));

  /// Stop the active UWB ranging session and release platform resources.
  ///
  /// Throws [UwbException] on failure.
  Future<void> stopRanging() async => _check(await _api.stopRanging());
}

/// Carries a platform error raised inside an active ranging session.
class RangingErrorEvent {
  RangingErrorEvent(this.deviceId, this.message);

  /// The peer whose session produced the error.
  final String deviceId;

  /// Human-readable description of the error.
  final String message;
}

class _FlutterApiHandler extends UwbFlutterApi {
  _FlutterApiHandler(this.parent);
  final FlutterUwb parent;

  @override
  void onDeviceFound(UwbDevice device) {
    parent._deviceFound.add(device);
  }

  @override
  void onDeviceLost(String deviceId) {
    parent._deviceLost.add(deviceId);
  }

  @override
  void onRangingSample(RangingSample sample) {
    parent._samples.add(sample);
  }

  @override
  void onPeerLost(String deviceId) {
    parent._peerLost.add(deviceId);
  }

  @override
  void onRangingError(String deviceId, String message) {
    parent._errors.add(RangingErrorEvent(deviceId, message));
  }
}

// -------- Backwards-compatible top-level functions --------
final FlutterUwb _instance = FlutterUwb.instance;

Future<void> startDiscovery(String localName) =>
    _instance.startDiscovery(localName);
Future<void> stopDiscovery() => _instance.stopDiscovery();
Future<List<UwbDevice>> getDiscovered() => _instance.getDiscovered();
Future<void> acceptRequest(String deviceId, Uint8List myToken) =>
    _instance.acceptRequest(deviceId, myToken);
Future<void> declineRequest(String deviceId) =>
    _instance.declineRequest(deviceId);
Future<void> registerAccessoryProfile({
  required String serviceUuid,
  required String rxUuid,
  required String txUuid,
  String? vendorTag,
}) =>
    _instance.registerAccessoryProfile(
      serviceUuid: serviceUuid,
      rxUuid: rxUuid,
      txUuid: txUuid,
      vendorTag: vendorTag,
    );
Future<void> unregisterAccessoryProfile(String serviceUuid) =>
    _instance.unregisterAccessoryProfile(serviceUuid);
Future<Uint8List> exchangeTokens(String deviceId, Uint8List myToken) =>
    _instance.exchangeTokens(deviceId, myToken);
Future<bool> isUwbAvailable() => _instance.isUwbAvailable();
Future<Uint8List> getLocalToken(UwbRole role) => _instance.getLocalToken(role);
Future<void> pairWith(String deviceId, {UwbRole role = UwbRole.controller}) =>
    _instance.pairWith(deviceId, role: role);
Future<void> startRanging(String deviceId) => _instance.startRanging(deviceId);
Future<void> stopRanging() => _instance.stopRanging();
