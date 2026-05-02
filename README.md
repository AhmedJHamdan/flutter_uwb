# flutter_uwb

A Flutter plugin for **Ultra-Wideband (UWB) precise ranging** with built-in
out-of-band (OOB) device discovery and token exchange.

| Platform | Discovery / OOB        | Ranging                 | Min OS  |
| -------- | ---------------------- | ----------------------- | ------- |
| Android  | BLE GATT (custom svc)  | `androidx.core.uwb`     | API 23  |
| iOS      | BLE GATT (custom svc)  | `NearbyInteraction`     | iOS 14  |

## Status

`v0.1.0` — works **same-platform**: Android↔Android and iOS↔iOS.
**Cross-platform** (iOS↔Android) UWB requires the FiRa accessory protocol
(`NINearbyAccessoryConfiguration` on iOS + matching FiRa controlee on
Android 14+) and is **not supported in v1**. Tracked as a v2 follow-up.

## Install

```yaml
dependencies:
  flutter_uwb: ^0.1.0
```

## Quick start

```dart
import 'package:flutter_uwb/flutter_uwb.dart';

final uwb = FlutterUwb.instance;

// 1. Check hardware support.
if (!await uwb.isUwbAvailable()) return;

// 2. Discover peers via OOB. New peers stream in.
await uwb.startDiscovery('my-device-name');
uwb.deviceFound.listen((device) {
  print('found ${device.name} (${device.id})');
});

// 3. Exchange platform-native tokens with the chosen peer.
//    Pick a role: only one side becomes controller.
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

## Token format

`getLocalToken(role)` returns **opaque platform-specific bytes**. Do not
attempt to interpret them on the wire across platforms.

- **Android** — 9 bytes, little-endian:
  `[0]` role · `[1..2]` shortAddr · `[3]` channel · `[4]` preambleIndex ·
  `[5..8]` sessionId
- **iOS** — `NSKeyedArchiver`-encoded `NIDiscoveryToken`

Cross-platform pairing must wait for v2.

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

- **Android** — UWB-capable device. Verified models include Pixel 6 Pro and
  later, Samsung Galaxy S21 Ultra and later. `isUwbAvailable()` returns
  `false` on emulators and on devices that lack `FEATURE_UWB`.
- **iOS** — iPhone with U1 or U2 chip (iPhone 11 and later, except SE 2/3).
  `isUwbAvailable()` returns `false` on the simulator.

## Example

A complete sample is included under `example/`. It scans, lists discovered
peers, exchanges tokens, starts a ranging session, and renders the latest
distance/azimuth/elevation as samples arrive.

## License

See `LICENSE`.
