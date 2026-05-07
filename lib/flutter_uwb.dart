import 'dart:async';
import 'dart:typed_data';

import 'src/accessory/_adapter_registry.dart';
import 'src/accessory/_adapter_runner.dart';
import 'src/accessory/accessory_adapter.dart';
// `accessory_adapter.dart` re-exports `AccessoryHandshakeEvent`,
// `AccessoryHandshakeEventKind`, and `FiraSessionParams` as typedefs over
// the Pigeon-generated types. Hide them here to keep a single canonical
// name in scope for this library's references.
import 'src/pigeon/uwb.g.dart'
    hide AccessoryHandshakeEvent, AccessoryHandshakeEventKind, FiraSessionParams;

export 'src/accessory/accessory_adapter.dart'
    show
        AccessoryAdapter,
        AccessoryConnection,
        AccessoryHandshakeEvent,
        AccessoryHandshakeEventKind,
        FiraSessionParams;

export 'src/log.dart' show UwbLog, UwbLogLevel;

export 'src/pigeon/uwb.g.dart'
    show
        AccessoryProfile,
        DeviceCapabilities,
        RangingError,
        RangingOptions,
        RangingSample,
        TokenPayload,
        UwbDevice,
        UwbErrorCode,
        UwbReadiness,
        UwbRole;

/// Thrown by [FlutterUwb] when a platform operation fails.
///
/// [code] carries a stable error category callers can branch on:
///
/// ```dart
/// try {
///   await uwb.startRanging(deviceId);
/// } on UwbException catch (e) {
///   if (e.code == UwbErrorCode.permissionDenied) { ... }
/// }
/// ```
///
/// `null` means the error came from a path that does not yet carry a
/// typed code on the wire; inspect [message] in that case.
class UwbException implements Exception {
  const UwbException(this.message, {this.code});

  /// Stable error category, or `null` when the underlying call did not
  /// classify the failure.
  final UwbErrorCode? code;

  /// Human-readable description from the platform.
  final String message;

  @override
  String toString() => code == null
      ? 'UwbException: $message'
      : 'UwbException(${code!.name}): $message';
}

/// Public Dart facade for the flutter_uwb plugin.
///
/// Use [FlutterUwb.instance] to access the singleton or construct your own
/// for testing with a custom Pigeon binary messenger.
class FlutterUwb {
  FlutterUwb._() {
    _adapterRegistry = AdapterRegistry(api: _api);
    _adapterRunner = AdapterRunner(
      registry: _adapterRegistry,
      api: _api,
      vendorTagFor: _vendorTagForDevice,
    );
    UwbFlutterApi.setup(_FlutterApiHandler(this));
  }

  static FlutterUwb? _instance;

  /// Default singleton. Re-created lazily after [dispose].
  static FlutterUwb get instance => _instance ??= FlutterUwb._();

  final UwbHostApi _api = UwbHostApi();
  late final AdapterRegistry _adapterRegistry;
  late final AdapterRunner _adapterRunner;
  final Map<String, UwbDevice> _knownDevices = {};

  /// Resolves the vendor tag for a discovered accessory device. Used by
  /// [AdapterRunner] to look up the right adapter when the native side
  /// fires `connected`.
  String _vendorTagForDevice(String deviceId) {
    final platform = _knownDevices[deviceId]?.platform ?? '';
    if (platform.startsWith('accessory:')) {
      return platform.substring('accessory:'.length);
    }
    return '';
  }

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
  final StreamController<IncomingRequest> _incomingRequests =
      StreamController<IncomingRequest>.broadcast();

  bool _disposed = false;

  /// `true` once [dispose] has been called on this instance.
  bool get isDisposed => _disposed;

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

  /// Pair requests received from a peer over the OOB transport.
  ///
  /// Fires when a remote peer initiates pairing by sending us their
  /// UWB token. Reply with [acceptRequest] (and then [startRanging])
  /// or [declineRequest].
  Stream<IncomingRequest> get incomingRequests => _incomingRequests.stream;

  // -------- Helpers --------

  void _check(VoidResult r) {
    if (!r.ok) throw UwbException(r.error ?? 'unknown error');
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
    if (out.bytes.isEmpty) {
      throw const UwbException(
        'exchangeTokens: platform returned empty token',
        code: UwbErrorCode.transportError,
      );
    }
    return out.bytes;
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
    if (t.bytes.isEmpty) {
      throw const UwbException(
        'getLocalToken: platform returned empty token',
        code: UwbErrorCode.sessionInitFailed,
      );
    }
    return t.bytes;
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
  Future<void> startRanging(
    String deviceId, {
    RangingOptions? options,
  }) async =>
      _check(await _api.startRanging(
        deviceId,
        options ?? RangingOptions(),
      ));

  /// Snapshot of the local UWB radio's capabilities. iOS-only fields are
  /// `false` on Android; Android-only fields are empty/zero on iOS.
  Future<DeviceCapabilities> getDeviceCapabilities() =>
      _api.getDeviceCapabilities();

  /// One-shot check of UWB hardware, Bluetooth state, and runtime
  /// permissions. Use this before [startDiscovery] / [startRanging] to
  /// drive an onboarding flow:
  ///
  /// ```dart
  /// final r = await uwb.checkReadiness();
  /// if (!r.bluetoothEnabled) showEnableBluetoothPrompt();
  /// else if (!r.permissionsGranted) requestPermissions(r.missingPermissions);
  /// else if (!r.uwbAvailable) showUnsupportedScreen();
  /// else readyToRange();
  /// ```
  ///
  /// Does not request permissions — the host app keeps that responsibility
  /// (typically via `permission_handler`). On iOS, [UwbReadiness.permissionsGranted]
  /// is always `true` and [UwbReadiness.missingPermissions] is empty;
  /// iOS prompts on first use rather than exposing a query API.
  Future<UwbReadiness> checkReadiness() => _api.checkReadiness();

  /// Stop the active UWB ranging session and release platform resources.
  ///
  /// Throws [UwbException] on failure.
  Future<void> stopRanging() async => _check(await _api.stopRanging());

  // -------- Accessory adapter framework (Android-only in v1) --------

  /// Register a custom [AccessoryAdapter]. The plugin invokes the
  /// adapter on every `startRanging` against an
  /// `accessory:<adapter.vendorTag>` device.
  ///
  /// Adapter authors typically also call [registerAccessoryProfile]
  /// with the same vendor tag so the BLE scanner picks up the
  /// accessory and surfaces it in [deviceFound].
  ///
  /// Re-registering with the same vendor tag replaces the previous
  /// adapter (custom adapters shadow built-ins).
  ///
  /// iOS: the adapter is recorded but the native dispatcher continues
  /// to use the hard-coded `IosAccessoryStrategy`. The framework is
  /// Android-only in v1.
  Future<void> registerAccessoryAdapter(AccessoryAdapter adapter) async {
    _adapterRegistry.register(adapter);
  }

  /// Remove the adapter previously registered for [vendorTag].
  /// No-op if no adapter is registered.
  Future<void> unregisterAccessoryAdapter(String vendorTag) async {
    _adapterRegistry.unregister(vendorTag);
  }

  /// Tear down the plugin's Dart-side resources: closes all broadcast
  /// streams and detaches the Pigeon flutter-api handler.
  ///
  /// Call this when the host app is shutting down or on hot reload to
  /// avoid leaking stream controllers across reload cycles. After
  /// [dispose] returns, the static [instance] getter will mint a fresh
  /// [FlutterUwb] on next access.
  ///
  /// Idempotent — calling [dispose] twice is a no-op.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    UwbFlutterApi.setup(null);
    await Future.wait<void>([
      _deviceFound.close(),
      _deviceLost.close(),
      _samples.close(),
      _peerLost.close(),
      _errors.close(),
      _incomingRequests.close(),
    ]);
    if (identical(FlutterUwb._instance, this)) FlutterUwb._instance = null;
  }
}

/// Carries a platform error raised inside an active ranging session.
class RangingErrorEvent {
  RangingErrorEvent(this.deviceId, this.code, this.message);

  /// The peer whose session produced the error.
  final String deviceId;

  /// Stable error category mapped from the platform reason code.
  final UwbErrorCode code;

  /// Human-readable description of the error.
  final String message;
}

class _FlutterApiHandler extends UwbFlutterApi {
  _FlutterApiHandler(this.parent);
  final FlutterUwb parent;

  @override
  void onDeviceFound(UwbDevice device) {
    if (parent._disposed) return;
    parent._knownDevices[device.id] = device;
    parent._deviceFound.add(device);
  }

  @override
  void onDeviceLost(String deviceId) {
    if (parent._disposed) return;
    parent._knownDevices.remove(deviceId);
    parent._deviceLost.add(deviceId);
  }

  @override
  void onRangingSample(RangingSample sample) {
    if (parent._disposed) return;
    parent._samples.add(sample);
  }

  @override
  void onPeerLost(String deviceId) {
    if (parent._disposed) return;
    parent._peerLost.add(deviceId);
  }

  @override
  void onRangingError(String deviceId, RangingError error) {
    if (parent._disposed) return;
    parent._errors.add(RangingErrorEvent(deviceId, error.code, error.message));
  }

  @override
  void onIncomingRequest(UwbDevice device, TokenPayload peerToken) {
    if (parent._disposed) return;
    parent._incomingRequests.add(IncomingRequest(device, peerToken.bytes));
  }

  @override
  void onAccessoryHandshakeEvent(
    String deviceId,
    AccessoryHandshakeEvent event,
  ) {
    if (parent._disposed) return;
    parent._adapterRunner.onEvent(deviceId, event);
  }
}

/// Pair request received from a peer over the OOB transport.
class IncomingRequest {
  IncomingRequest(this.device, this.peerToken);

  /// The peer that sent the request.
  final UwbDevice device;

  /// The peer's UWB token, ready to feed into a local ranging session.
  final Uint8List peerToken;
}

// -------- Backwards-compatible top-level functions --------
// Each call resolves through the static getter so dispose() / hot reload
// transparently swap the underlying instance.

Future<void> startDiscovery(String localName) =>
    FlutterUwb.instance.startDiscovery(localName);
Future<void> stopDiscovery() => FlutterUwb.instance.stopDiscovery();
Future<List<UwbDevice>> getDiscovered() => FlutterUwb.instance.getDiscovered();
Future<void> acceptRequest(String deviceId, Uint8List myToken) =>
    FlutterUwb.instance.acceptRequest(deviceId, myToken);
Future<void> declineRequest(String deviceId) =>
    FlutterUwb.instance.declineRequest(deviceId);
Future<void> registerAccessoryProfile({
  required String serviceUuid,
  required String rxUuid,
  required String txUuid,
  String? vendorTag,
}) =>
    FlutterUwb.instance.registerAccessoryProfile(
      serviceUuid: serviceUuid,
      rxUuid: rxUuid,
      txUuid: txUuid,
      vendorTag: vendorTag,
    );
Future<void> unregisterAccessoryProfile(String serviceUuid) =>
    FlutterUwb.instance.unregisterAccessoryProfile(serviceUuid);
Future<Uint8List> exchangeTokens(String deviceId, Uint8List myToken) =>
    FlutterUwb.instance.exchangeTokens(deviceId, myToken);
Future<bool> isUwbAvailable() => FlutterUwb.instance.isUwbAvailable();
Future<Uint8List> getLocalToken(UwbRole role) =>
    FlutterUwb.instance.getLocalToken(role);
Future<void> pairWith(String deviceId, {UwbRole role = UwbRole.controller}) =>
    FlutterUwb.instance.pairWith(deviceId, role: role);
Future<void> startRanging(String deviceId, {RangingOptions? options}) =>
    FlutterUwb.instance.startRanging(deviceId, options: options);
Future<DeviceCapabilities> getDeviceCapabilities() =>
    FlutterUwb.instance.getDeviceCapabilities();
Future<UwbReadiness> checkReadiness() => FlutterUwb.instance.checkReadiness();
Future<void> stopRanging() => FlutterUwb.instance.stopRanging();
Future<void> registerAccessoryAdapter(AccessoryAdapter adapter) =>
    FlutterUwb.instance.registerAccessoryAdapter(adapter);
Future<void> unregisterAccessoryAdapter(String vendorTag) =>
    FlutterUwb.instance.unregisterAccessoryAdapter(vendorTag);
