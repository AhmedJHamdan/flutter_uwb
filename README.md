# flutter_uwb

A Flutter plugin for **Ultra-Wideband (UWB) precise ranging** with built-in
out-of-band (OOB) device discovery and token exchange.

| Platform | Discovery / OOB        | Ranging                 | Min OS                |
| -------- | ---------------------- | ----------------------- | --------------------- |
| Android  | BLE GATT (custom svc)  | `androidx.core.uwb`     | API 23 (peer mode)    |
| iOS      | BLE GATT (custom svc)  | `NearbyInteraction`     | iOS 14 (peer mode), iOS 15 (accessory) |

## Status

`v0.2.0+1` — peer-mode UWB on Android↔Android and iOS↔iOS, plus
**accessory-mode** ranging on iOS via `NINearbyAccessoryConfiguration` and
on Android via `controleeSessionScope`. Cross-platform iOS↔Android, and
both-platforms-↔-accessory, ride on the same Apple FiRa accessory BLE
protocol.

The peer matrix:

| Peer A | Peer B | Status |
| --- | --- | --- |
| iPhone | iPhone | ✅ shipped |
| Android | Android | ✅ shipped |
| iPhone | Apple-spec accessory | ✅ shipped (code-complete; runtime verification gated on real accessory hardware) |
| iPhone | Android | ✅ shipped (code-complete; runtime verification gated on Pixel 7 Pro+ class device) |
| Android | Apple-spec accessory | ✅ shipped (Android-as-host; same gating) |

> **Verification gap.** iPhone↔iPhone BLE pairing has not yet been
> exercised on a two-iPhone hardware setup as of this release —
> functional sim verification only. iOS↔Android and any-↔-accessory
> require additional hardware (a Pixel 7 Pro+ class Android UWB device,
> and a FiRa-compliant Apple-protocol accessory) to validate the FiRa
> byte layouts. See `doc/migration-v1-to-v2.md` for the test plan.

## Install

```yaml
dependencies:
  flutter_uwb: ^0.2.0
```

## Quick start (peer mode)

```dart
import 'package:flutter_uwb/flutter_uwb.dart';

final uwb = FlutterUwb.instance;

// 1. Check hardware support.
if (!await uwb.isUwbAvailable()) return;

// 2. Discover peers via OOB. New peers stream in.
await uwb.startDiscovery('my-device-name');
uwb.deviceFound.listen((device) {
  print('found ${device.name} (${device.id}) on ${device.platform}');
});

// 3. Exchange platform-native tokens with the chosen peer.
final myToken = await uwb.getLocalToken(UwbRole.controller);
final peerToken = await uwb.exchangeTokens(deviceId, myToken);

// 4. Start a ranging session and consume samples.
await uwb.startRanging(deviceId);
uwb.rangingSamples.listen((s) {
  print('${s.distanceMeters?.toStringAsFixed(2)} m');
});

// 5. Tear down.
await uwb.stopRanging();
await uwb.stopDiscovery();
```

## Accessory mode

Apple-spec accessories (Qorvo NI, NXP Trimension UCI, etc.) and Android
devices speaking the Apple FiRa protocol are surfaced as
`UwbDevice.platform == "accessory"` (or `"accessory:<vendor>"` if a
`vendorTag` was registered).

```dart
// Register the accessory's BLE profile so the plugin scans for it.
await uwb.registerAccessoryProfile(
  serviceUuid: '48FE7E40-CB7C-470E-89ED-5B85A13E67EE',
  rxUuid:      '6E63FF01-87A8-490B-AF2F-FC1D4B67F77A',
  txUuid:      '6E63FF02-87A8-490B-AF2F-FC1D4B67F77A',
  vendorTag:   'qorvo', // optional — used to namespace platform string
);

await uwb.startDiscovery('my-device');
uwb.deviceFound
    .where((d) => (d.platform ?? '').startsWith('accessory'))
    .listen((d) {
  // No need to call exchangeTokens — the plugin drives the
  // Apple-protocol handshake internally.
  uwb.startRanging(d.id!);
});
```

The protocol's byte format is implemented in
`lib/src/accessory/apple_protocol.dart` (Dart) and mirrored in
`android/.../accessory/AppleProtocol.kt` (Kotlin). The exact UUIDs above
are sample values from Apple's WWDC 2022 reference; real accessories
ship vendor-specific service / characteristic UUIDs.

## Public API

```dart
class FlutterUwb {
  static final FlutterUwb instance;

  // Discovery / OOB
  Future<VoidResult> startDiscovery(String localName);
  Future<VoidResult> stopDiscovery();
  Future<List<UwbDevice>> getDiscovered();           // one-shot snapshot
  Stream<UwbDevice> get deviceFound;                 // preferred
  Stream<String>    get deviceLost;
  Future<VoidResult> acceptRequest(String id, Uint8List myToken);
  Future<VoidResult> declineRequest(String id);
  Future<Uint8List>  exchangeTokens(String id, Uint8List myToken);

  // Accessory profile registration (v0.2.0+)
  Future<VoidResult> registerAccessoryProfile({
    required String serviceUuid,
    required String rxUuid,
    required String txUuid,
    String? vendorTag,
  });
  Future<VoidResult> unregisterAccessoryProfile(String serviceUuid);

  // UWB
  Future<bool>      isUwbAvailable();
  Future<Uint8List> getLocalToken(UwbRole role);
  Future<VoidResult> startRanging(String id);
  Future<VoidResult> stopRanging();
  Stream<RangingSample>     get rangingSamples;
  Stream<String>            get peerLost;
  Stream<RangingErrorEvent> get rangingErrors;
}

enum UwbRole { controller, controlee }

class RangingSample {
  String? deviceId;
  double? distanceMeters;
  double? azimuthDegrees;
  double? elevationDegrees;
  int?    elapsedRealtimeNanos;
}
```

`UwbDevice.platform` taxonomy:

- `"ios"` / `"android"` — peer-mode device speaking the v1 9-byte token.
- `"accessory"` — Apple-FiRa-spec accessory (built-in handler).
- `"accessory:<tag>"` — Apple-FiRa-spec accessory with a registered
  vendor tag, useful for filtering when multiple vendor profiles are
  registered.

## Token format (peer mode)

`getLocalToken(role)` returns **opaque platform-specific bytes**. Do not
attempt to interpret them on the wire across platforms.

- **Android** — 9 bytes, little-endian:
  `[0]` role · `[1..2]` shortAddr · `[3]` channel · `[4]` preambleIndex ·
  `[5..8]` sessionId
- **iOS** — `NSKeyedArchiver`-encoded `NIDiscoveryToken`

Accessory mode does not use `getLocalToken` / `exchangeTokens`; the
multi-message Apple protocol is driven internally by the plugin.

## Permissions

### Android (declared by the plugin manifest)

```xml
<uses-feature android:name="android.hardware.bluetooth_le" android:required="true"/>
<uses-feature android:name="android.hardware.uwb"           android:required="false"/>
<uses-permission android:name="android.permission.BLUETOOTH"            android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"      android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"       android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.UWB_RANGING"/>
```

The host app must request the runtime permissions. On API ≥ 31 that is
`BLUETOOTH_SCAN`/`BLUETOOTH_ADVERTISE`/`BLUETOOTH_CONNECT`; on API ≤ 30
it is `ACCESS_FINE_LOCATION`. `UWB_RANGING` is required on API ≥ 33.

### iOS — add to `Info.plist`

```xml
<key>NSNearbyInteractionUsageDescription</key>
<string>Used to measure precise distance to nearby phones over UWB.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover nearby phones for UWB ranging.</string>
```

## Hardware requirements

- **Android** — UWB-capable device. Peer mode: Pixel 6 Pro+, Samsung
  Galaxy S21 Ultra+. Accessory-controlee mode (cross-platform with
  iPhone or Apple-spec accessory): Pixel 7 Pro+ on Android 14+
  recommended. `isUwbAvailable()` returns `false` on emulators and on
  devices lacking `FEATURE_UWB`.
- **iOS** — iPhone with U1 or U2 chip (iPhone 11+, except SE 2/3) on
  iOS 14+ for peer mode. Accessory mode requires **iOS 15+** for
  `NINearbyAccessoryConfiguration`. `isUwbAvailable()` returns `false`
  on the simulator.

## Example

A complete sample is included under `example/`. It scans, lists discovered
peers, exchanges tokens (peer mode), starts a ranging session, and
renders the latest distance/azimuth/elevation as samples arrive.

## Migration

If you're upgrading from `v0.1.0`, see
[`doc/migration-v1-to-v2.md`](doc/migration-v1-to-v2.md). The public
peer-mode API is unchanged; v2 is additive.

## License

See `LICENSE`.
