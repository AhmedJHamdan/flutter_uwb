import 'dart:async';
import 'dart:typed_data';

import '../pigeon/uwb.g.dart' as pigeon;
import 'accessory_adapter.dart';
import '_adapter_registry.dart';

/// Bridges native handshake events to the registered [AccessoryAdapter]
/// callbacks. Owns one [AccessoryConnection] per active handshake and
/// fans inbound `notifyBytes` events into the right connection's
/// stream.
///
/// Package-private — instantiated by `FlutterUwb` and wired through
/// `_FlutterApiHandler.onAccessoryHandshakeEvent`.
class AdapterRunner {
  AdapterRunner({
    required AdapterRegistry registry,
    required pigeon.UwbHostApi api,
    required String Function(String deviceId) vendorTagFor,
  })  : _registry = registry,
        _api = api,
        _vendorTagFor = vendorTagFor;

  final AdapterRegistry _registry;
  final pigeon.UwbHostApi _api;
  final String Function(String deviceId) _vendorTagFor;

  final Map<String, _ActiveHandshake> _active = {};

  /// Entry point from `_FlutterApiHandler.onAccessoryHandshakeEvent`.
  void onEvent(String deviceId, pigeon.AccessoryHandshakeEvent event) {
    switch (event.kind) {
      case pigeon.AccessoryHandshakeEventKind.connected:
        _onConnected(deviceId);
      case pigeon.AccessoryHandshakeEventKind.notifyBytes:
        final bytes = event.bytes;
        if (bytes != null) _active[deviceId]?.deliverNotify(bytes);
      case pigeon.AccessoryHandshakeEventKind.transportError:
        _active[deviceId]?.failWithMessage(
          event.errorMessage ?? 'transport error',
        );
      case pigeon.AccessoryHandshakeEventKind.disconnected:
        _active[deviceId]?.failWithMessage('peer disconnected');
      case pigeon.AccessoryHandshakeEventKind.stopRequested:
        _active[deviceId]?.failWithMessage('stop requested');
    }
  }

  /// Sentinel tag the framework looks up when no adapter is registered
  /// for a given accessory's vendor tag. The Apple-NI built-in adapter
  /// registers under this tag and acts as the fallback for any
  /// `accessory:<unregistered-tag>` device — preserving zero-code-change
  /// compatibility for apps that today register only an
  /// [registerAccessoryProfile] without an accompanying adapter.
  static const String _appleNiFallbackTag = '__apple_ni_default__';

  void _onConnected(String deviceId) {
    final tag = _vendorTagFor(deviceId);
    final adapter = _registry.lookup(tag) ?? _registry.lookup(_appleNiFallbackTag);
    if (adapter == null) {
      _api.failAccessoryHandshake(
        deviceId,
        'no adapter registered for vendorTag "$tag"',
      );
      return;
    }
    final notifyController = StreamController<Uint8List>.broadcast();
    final doneCompleter = Completer<void>();
    final conn = AccessoryConnection(
      deviceId: deviceId,
      write: (bytes) async {
        final r = await _api.accessoryProtocolWrite(deviceId, bytes);
        if (!r.ok) {
          throw StateError(r.error ?? 'accessoryProtocolWrite failed');
        }
      },
      notifyStream: notifyController.stream,
      done: doneCompleter.future,
    );
    final active = _ActiveHandshake(
      deviceId: deviceId,
      adapter: adapter,
      api: _api,
      notifyController: notifyController,
      doneCompleter: doneCompleter,
      conn: conn,
      onFinished: () => _active.remove(deviceId),
    );
    _active[deviceId] = active;
    active.start();
  }
}

class _ActiveHandshake {
  _ActiveHandshake({
    required this.deviceId,
    required this.adapter,
    required this.api,
    required this.notifyController,
    required this.doneCompleter,
    required this.conn,
    required this.onFinished,
  });

  final String deviceId;
  final AccessoryAdapter adapter;
  final pigeon.UwbHostApi api;
  final StreamController<Uint8List> notifyController;
  final Completer<void> doneCompleter;
  final AccessoryConnection conn;
  final void Function() onFinished;

  bool _settled = false;

  void deliverNotify(Uint8List bytes) {
    if (_settled) return;
    if (notifyController.isClosed) return;
    notifyController.add(bytes);
  }

  void failWithMessage(String message) {
    _settle();
    api.failAccessoryHandshake(deviceId, message);
  }

  void start() {
    Future<FiraSessionParams> run() => adapter.handshake(conn);

    run().timeout(
      adapter.handshakeTimeout,
      onTimeout: () =>
          throw TimeoutException('adapter handshake timed out', adapter.handshakeTimeout),
    ).then(
      (params) {
        if (_settled) return;
        _settle();
        api.completeAccessoryHandshake(deviceId, params);
      },
      onError: (error, stack) {
        if (_settled) return;
        _settle();
        api.failAccessoryHandshake(deviceId, error.toString());
      },
    );
  }

  void _settle() {
    if (_settled) return;
    _settled = true;
    if (!doneCompleter.isCompleted) doneCompleter.complete();
    if (!notifyController.isClosed) notifyController.close();
    onFinished();
  }
}
