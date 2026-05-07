import 'dart:typed_data';

import '../accessory_adapter.dart';

/// Vendor tag the [StaticPairAccessoryAdapter] is registered under.
/// Distinct from the example app's `_QorvoProfile.vendorTag = 'qorvo'`
/// so the static-pair path coexists with a real BLE Qorvo discovery.
const String staticPairQorvoVendorTag = 'qorvo-static';

/// Synthetic device id used by the dispatcher; mirrored by the seeder
/// in `FlutterUwb` so tapping the tile routes to this adapter.
const String staticPairQorvoDeviceId = 'qorvo-static-001';

/// Display name for the synthetic device tile.
const String staticPairQorvoDeviceName = 'Qorvo (static demo)';

/// Built-in adapter for the no-OOB Qorvo CLI demo. Returns hardcoded
/// FiRa params matching the Qorvo CLI `RESPF` command form
///
/// ```text
/// RESPF -CHAN=<chip-chosen> -PCODE=<chip-chosen> -ID=42 -SLOT=2400
///       -ROUND=6 -BLOCK=240 -RRU=DSTWR -ADDR=1
///       -PADDR=<chip-chosen> -VUPPER=00:11:22:33:44:55:08:07
/// ```
///
/// The Qorvo board must be configured out-of-band via its USB CLI
/// before tapping. `tools/qorvo/auto_sync.py` watches Galaxy logcat
/// for the matching `DIAG static-pair-info` line emitted by
/// `DartDrivenAccessoryStrategy` and auto-issues the right `RESPF`.
///
/// Useful for developer-bench validation against a Qorvo DWM3001CDK
/// running CLI firmware.
class StaticPairAccessoryAdapter implements AccessoryAdapter {
  const StaticPairAccessoryAdapter();

  @override
  String get vendorTag => staticPairQorvoVendorTag;

  @override
  Duration get handshakeTimeout => const Duration(seconds: 5);

  @override
  Future<FiraSessionParams> handshake(AccessoryConnection conn) async {
    // No OOB exchange — the Qorvo CLI is configured manually via USB
    // before the user taps. Just return the canned params; the native
    // side picks channel/preamble at scope-acquisition time and logs
    // the effective values via `DIAG static-pair-info` so the
    // operator (or `auto_sync.py`) can mirror them on the Qorvo CLI.
    return FiraSessionParams(
      sessionId: 42,
      channel: 9,
      preambleIndex: 11,
      slotDurationMs: 2,
      slotsPerRangingRound: 6,
      rangingIntervalMs: 240,
      sessionKeyInfo: Uint8List.fromList(
        // 8-byte FiRa Static-STS sessionKeyInfo. Layout =
        // `vendorId(2B) || stsIv(6B)`. Mirrors the Qorvo CLI's
        // `-VUPPER=08:07:00:11:22:33:44:55` so the STS scrambling
        // derivation matches on both ends.
        [0x08, 0x07, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
      ),
      peerShortAddress: Uint8List.fromList([0x00, 0x01]),
      roleIsController: true,
    );
  }
}
