import 'dart:async';
import 'dart:typed_data';

import 'src/pigeon/uwb.g.dart';

export 'src/pigeon/uwb.g.dart'
    show RangingSample, TokenPayload, UwbDevice, UwbRole, VoidResult;

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

  // -------- Discovery / OOB --------
  Future<VoidResult> startDiscovery(String localName) =>
      _api.startDiscovery(localName);

  Future<VoidResult> stopDiscovery() => _api.stopDiscovery();

  Future<List<UwbDevice>> getDiscovered() async {
    final list = await _api.getDiscovered();
    return list.whereType<UwbDevice>().toList();
  }

  Future<VoidResult> acceptRequest(String deviceId, Uint8List myToken) =>
      _api.acceptRequest(deviceId, TokenPayload(bytes: myToken));

  Future<VoidResult> declineRequest(String deviceId) =>
      _api.declineRequest(deviceId);

  Future<Uint8List> exchangeTokens(String deviceId, Uint8List myToken) async {
    final out = await _api.exchangeTokens(
      deviceId,
      TokenPayload(bytes: myToken),
    );
    return out.bytes ?? Uint8List(0);
  }

  // -------- UWB --------
  Future<bool> isUwbAvailable() => _api.isUwbAvailable();

  /// Returns the local platform-specific OOB token.
  ///
  /// On Android the bytes are the 9-byte little-endian blob described in
  /// `lib/src/pigeon/uwb_api.dart`. On iOS the bytes are an
  /// `NSKeyedArchiver`-encoded `NIDiscoveryToken`.
  Future<Uint8List> getLocalToken(UwbRole role) async {
    final t = await _api.getLocalToken(role);
    return t.bytes ?? Uint8List(0);
  }

  Future<VoidResult> startRanging(String deviceId) =>
      _api.startRanging(deviceId);

  Future<VoidResult> stopRanging() => _api.stopRanging();
}

class RangingErrorEvent {
  RangingErrorEvent(this.deviceId, this.message);
  final String deviceId;
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
// These delegate to FlutterUwb.instance for callers that prefer a flat API.
final FlutterUwb _instance = FlutterUwb.instance;

Future<VoidResult> startDiscovery(String localName) =>
    _instance.startDiscovery(localName);
Future<VoidResult> stopDiscovery() => _instance.stopDiscovery();
Future<List<UwbDevice>> getDiscovered() => _instance.getDiscovered();
Future<VoidResult> acceptRequest(String deviceId, Uint8List myToken) =>
    _instance.acceptRequest(deviceId, myToken);
Future<VoidResult> declineRequest(String deviceId) =>
    _instance.declineRequest(deviceId);
Future<Uint8List> exchangeTokens(String deviceId, Uint8List myToken) =>
    _instance.exchangeTokens(deviceId, myToken);
Future<bool> isUwbAvailable() => _instance.isUwbAvailable();
Future<Uint8List> getLocalToken(UwbRole role) =>
    _instance.getLocalToken(role);
Future<VoidResult> startRanging(String deviceId) =>
    _instance.startRanging(deviceId);
Future<VoidResult> stopRanging() => _instance.stopRanging();
