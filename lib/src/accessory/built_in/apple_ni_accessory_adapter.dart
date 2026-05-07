import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../accessory_adapter.dart';
import '../apple_protocol.dart';

/// Sentinel vendor tag used by the framework to look up the Apple-NI
/// fallback adapter when no other adapter is registered for an
/// `accessory:<tag>` device.
const String appleNiDefaultVendorTag = '__apple_ni_default__';

/// Built-in adapter that drives Apple's NI Accessory Protocol from the
/// Android side as the host (UWB controller). Replaces the
/// pre-Phase-3 native `AndroidControllerStrategy` — same wire format,
/// same FiRa params, but the byte-fiddling lives in Dart so app
/// developers can copy/fork it.
///
/// The adapter writes:
///   1. `Initialize` (0x0A) — accessory replies with
///      `AccessoryConfigurationData` (0x01).
///   2. `ConfigureAndStart` (0x0B + 30-byte AppleUWBConfigData) —
///      accessory replies with `AccessoryUwbDidStart` (0x02).
///
/// Slot duration is 2 ms (2400 RSTU) with ranging interval 240 ms —
/// the values Jetpack picks for `RANGING_UPDATE_RATE_AUTOMATIC` with
/// `CONFIG_UNICAST_DS_TWR`. The session-key vendor id is 0x0807
/// (matches NXP's Qorvo example firmware).
class AppleNiAccessoryAdapter implements AccessoryAdapter {
  AppleNiAccessoryAdapter({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  @override
  String get vendorTag => appleNiDefaultVendorTag;

  @override
  Duration get handshakeTimeout => const Duration(seconds: 30);

  @override
  Future<FiraSessionParams> handshake(AccessoryConnection conn) async {
    // Generate a session id and 6-byte STS IV. The same values flow
    // into the AppleUWBConfigData blob and the FiRa sessionKeyInfo so
    // the accessory and Android chip derive matching STS scrambling.
    final sessionId = 1 + _random.nextInt(0x7FFFFFFE);
    final stsIv = Uint8List(6);
    for (var i = 0; i < stsIv.length; i++) {
      stsIv[i] = _random.nextInt(256);
    }

    // Subscribe to inbound notifies once. Apple-NI handshakes are short
    // enough that we can buffer everything in a StreamQueue and read
    // sequentially.
    final inbound = _Queue(conn.notifyStream);
    try {
      // 1. Initialize.
      await conn.write(const Initialize().encode());

      // 2. Wait for AccessoryConfigurationData.
      final accCfg = await inbound.expect<AccessoryConfigurationData>(
        'AccessoryConfigurationData',
      );
      final peer = parseAccessoryShortAddress(accCfg.configData);
      if (peer == null) {
        throw StateError(
          'AccessoryConfigurationData payload too short: '
          '${accCfg.configData.length} bytes',
        );
      }

      // 3. Build and send ConfigureAndStart with our session params.
      // Channel/preamble/controller-address are placeholders the
      // native side overrides with the values the local UWB chip
      // selected. The accessory only validates structural correctness
      // of this blob; it overrides our params with its own
      // AppleUWBConfigData.
      final configData = buildAppleUwbConfigData(
        sessionId: sessionId,
        channel: 9,
        preambleIndex: 11,
        slotsPerRound: 6,
        slotDurationRstu: 2400,
        rangingIntervalMs: 240,
        stsIv: stsIv,
        controllerShortAddress: Uint8List.fromList([0x00, 0x00]),
      );
      await conn.write(ConfigureAndStart(configData).encode());

      // 4. Wait for AccessoryUwbDidStart.
      await inbound.expect<AccessoryUwbDidStart>('AccessoryUwbDidStart');

      // 5. Return FiRa params. sessionKeyInfo layout is
      // `vendorId(2B, LE) || stsIv(6B)`. Vendor 0x0807 matches the
      // pre-Phase-3 native strategy and Qorvo's example firmware.
      final sessionKeyInfo = Uint8List(8);
      sessionKeyInfo[0] = 0x08;
      sessionKeyInfo[1] = 0x07;
      sessionKeyInfo.setRange(2, 8, stsIv);

      return FiraSessionParams(
        sessionId: sessionId,
        channel: 9,
        preambleIndex: 11,
        slotDurationMs: 2,
        slotsPerRangingRound: 6,
        rangingIntervalMs: 240,
        sessionKeyInfo: sessionKeyInfo,
        peerShortAddress: peer,
        roleIsController: true,
      );
    } finally {
      await inbound.close();
    }
  }
}

/// Tiny buffering wrapper around the broadcast notify stream. Subscribes
/// once at construction so events that arrive between awaits don't fall
/// on the floor.
class _Queue {
  _Queue(Stream<Uint8List> source) {
    _sub = source.listen(
      (bytes) {
        if (_pending == null) {
          _buffer.add(bytes);
        } else {
          final c = _pending!;
          _pending = null;
          c.complete(bytes);
        }
      },
      onError: (Object error) {
        if (_pending != null) {
          final c = _pending!;
          _pending = null;
          c.completeError(error);
        }
      },
      onDone: () {
        _closed = true;
        if (_pending != null) {
          final c = _pending!;
          _pending = null;
          c.completeError(
            StateError('Apple-NI handshake: notify stream closed'),
          );
        }
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<Uint8List> _buffer = [];
  Completer<Uint8List>? _pending;
  bool _closed = false;

  Future<T> expect<T extends AppleAccessoryMessage>(String label) async {
    final bytes = await _next();
    final msg = AppleAccessoryMessage.decode(bytes);
    if (msg is T) return msg;
    throw StateError(
      'Apple-NI handshake: expected $label, got ${msg.id.name}',
    );
  }

  Future<Uint8List> _next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    if (_closed) {
      return Future.error(
        StateError('Apple-NI handshake: notify stream already closed'),
      );
    }
    final c = Completer<Uint8List>();
    _pending = c;
    return c.future;
  }

  Future<void> close() => _sub.cancel();
}
