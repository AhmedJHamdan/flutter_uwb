import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_uwb/flutter_uwb.dart';

/// `vendorTag` the [DemoTagAdapter] is registered under. The example
/// app surfaces a synthetic `accessory:demo-tag` device when the
/// adapter is enabled so the user can tap to exercise the
/// adapter-framework round-trip without any real hardware.
const String demoTagVendorTag = 'demo-tag';

/// `id` for the synthetic demo-tag device the example app seeds.
const String demoTagDeviceId = 'demo-tag-001';

/// Reference adapter showing the developer-facing pattern.
///
/// Pretends to be a "DemoTag" accessory: writes a single hello byte
/// (0x42), waits for a one-byte echo, then returns the same canonical
/// [FiraSessionParams] as the built-in static-pair adapter. The
/// expectation is that the developer pairs this with their own
/// firmware (or a Qorvo running CLI for bench tests).
///
/// In the example app the real BLE accessoryConnect will fail because
/// no DemoTag hardware exists — that's fine for the developer-experience
/// smoke test. The point is to show the API surface a real adapter
/// would use.
class DemoTagAdapter implements AccessoryAdapter {
  const DemoTagAdapter();

  @override
  String get vendorTag => demoTagVendorTag;

  @override
  Duration get handshakeTimeout => const Duration(seconds: 5);

  @override
  Future<FiraSessionParams> handshake(AccessoryConnection conn) async {
    developer.log(
      'demo-tag handshake: writing hello byte to $demoTagVendorTag',
      name: 'flutter_uwb.example',
    );
    await conn.write(Uint8List.fromList([0x42]));

    final reply = await conn.notifyStream.first;
    developer.log(
      'demo-tag handshake: got ${reply.length}-byte reply '
      '(${reply.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')})',
      name: 'flutter_uwb.example',
    );

    // Hardcoded params matching the Qorvo CLI's expected
    // `RESPF -ID=42 ...` configuration. A real adapter would derive
    // these from the bytes the accessory sent back.
    return FiraSessionParams(
      sessionId: 42,
      channel: 9,
      preambleIndex: 11,
      slotDurationMs: 2,
      slotsPerRangingRound: 6,
      rangingIntervalMs: 240,
      sessionKeyInfo: Uint8List.fromList(
        [0x08, 0x07, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
      ),
      peerShortAddress: Uint8List.fromList([0x00, 0x01]),
      roleIsController: true,
    );
  }
}
