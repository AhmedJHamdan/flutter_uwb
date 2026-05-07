/// Public types for the Dart-driven accessory adapter framework.
///
/// An [AccessoryAdapter] lets app developers ship their own BLE-OOB
/// protocol while flutter_uwb keeps owning the BLE transport and the
/// FiRa session lifecycle. The plugin invokes [AccessoryAdapter.handshake]
/// each time the user calls `startRanging` against an
/// `accessory:<vendorTag>` device whose tag matches the adapter's
/// [AccessoryAdapter.vendorTag].
///
/// Android-only in v1: iOS accessory mode keeps its hard-coded
/// `IosAccessoryStrategy`, so adapters registered on iOS are recorded
/// but not invoked. See `docs/agents/plans/2026-05-07-accessory-adapter-framework.md`
/// for the design notes.
library;

import 'dart:async';
import 'dart:typed_data';

import '../pigeon/uwb.g.dart' as pigeon;

/// Re-export of the Pigeon-generated [pigeon.FiraSessionParams] type so
/// callers can construct one from the public `flutter_uwb` API surface
/// without importing the generated file directly.
typedef FiraSessionParams = pigeon.FiraSessionParams;

/// Re-export of the Pigeon-generated [pigeon.AccessoryHandshakeEvent]
/// type. Most adapter authors never touch this — the framework
/// translates events into [AccessoryConnection.notifyStream] and
/// [AccessoryConnection.done] for you.
typedef AccessoryHandshakeEvent = pigeon.AccessoryHandshakeEvent;

/// Re-export of [pigeon.AccessoryHandshakeEventKind].
typedef AccessoryHandshakeEventKind = pigeon.AccessoryHandshakeEventKind;

/// Implement this to ship a custom BLE-OOB protocol against your
/// own UWB accessory firmware.
///
/// The plugin instantiates one adapter per active ranging attempt
/// against an `accessory:<vendorTag>` device whose tag matches
/// [vendorTag]. After [handshake] returns, the plugin opens a
/// FiRa ranging session with the returned [FiraSessionParams] and
/// keeps the [AccessoryConnection] open for the duration of ranging
/// so application code can implement custom keep-alive or reconfig
/// logic.
abstract class AccessoryAdapter {
  /// Tag matched against `UwbDevice.platform = "accessory:<tag>"`.
  ///
  /// Pick something stable and unique to your firmware vendor — e.g.
  /// `"acme-tag-v1"`. The plugin's built-in adapters use the
  /// sentinel tags `"__apple_ni_default__"` (Apple-NI fallback) and
  /// `"qorvo-static"` (no-OOB Qorvo CLI demo).
  String get vendorTag;

  /// How long the framework waits for [handshake] to return a
  /// [FiraSessionParams] before tearing down the BLE link and
  /// emitting a `sessionInitFailed` ranging error. Override to give
  /// long-running protocols more time. Defaults to 30 s.
  Duration get handshakeTimeout => const Duration(seconds: 30);

  /// Drive the BLE-OOB exchange and return the FiRa parameters the
  /// plugin should open the ranging session with.
  ///
  /// The framework guarantees:
  ///   - [conn] is connected and notifications are subscribed before
  ///     this method is invoked.
  ///   - [AccessoryConnection.write] writes go to the matched profile's
  ///     `rxUuid` characteristic.
  ///   - [AccessoryConnection.notifyStream] emits every frame received
  ///     on the matched profile's `txUuid` characteristic.
  ///   - [AccessoryConnection.done] completes when the BLE link drops
  ///     or `stopRanging` is called.
  ///
  /// Throwing or returning past [handshakeTimeout] reports the failure
  /// to the host app via the `rangingErrors` stream.
  Future<FiraSessionParams> handshake(AccessoryConnection conn);
}

/// Long-lived BLE link the plugin gives the adapter for the duration
/// of the handshake AND of the subsequent ranging session.
///
/// The connection stays open from the moment [AccessoryAdapter.handshake]
/// is invoked until either the user calls `stopRanging` or the BLE peer
/// drops. This lets the adapter schedule its own keep-alive writes,
/// query firmware state mid-session, etc., without needing a heartbeat
/// API in the plugin.
class AccessoryConnection {
  /// Constructed by [_AdapterRunner] — adapter authors do not call this.
  AccessoryConnection({
    required this.deviceId,
    required Future<void> Function(Uint8List) write,
    required Stream<Uint8List> notifyStream,
    required Future<void> done,
  })  : _write = write,
        _notifyStream = notifyStream,
        _done = done;

  /// The peer's BLE device id (mirrors `UwbDevice.id`).
  final String deviceId;

  final Future<void> Function(Uint8List) _write;
  final Stream<Uint8List> _notifyStream;
  final Future<void> _done;

  /// Push bytes to the accessory's `rxUuid` characteristic.
  ///
  /// Apple-NI accessories cap frames at 32 bytes; longer writes work
  /// transparently if the peer negotiated a larger MTU.
  Future<void> write(Uint8List bytes) => _write(bytes);

  /// Inbound frames from the accessory's `txUuid` characteristic.
  ///
  /// Broadcast stream — multiple awaits / listens see the same
  /// frames concurrently.
  Stream<Uint8List> get notifyStream => _notifyStream;

  /// Completes when the plugin tears down the connection (user
  /// called `stopRanging`, BLE link dropped, or the handshake timed
  /// out). Adapter code can `await conn.done` to interleave cleanup
  /// with handshake state.
  Future<void> get done => _done;
}
