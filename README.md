# flutter_uwb

Flutter plugin for **UWB precise ranging** with BLE out-of-band device
discovery on Android and iOS.

![Android](https://img.shields.io/badge/Android-API%2023%2B-brightgreen?logo=android)
![iOS](https://img.shields.io/badge/iOS-14%2B-blue?logo=apple)

---

## Installation

```yaml
dependencies:
  flutter_uwb: ^0.3.1
```

---

## Quick start

```dart
import 'package:flutter_uwb/flutter_uwb.dart';

final uwb = FlutterUwb.instance;

// Check hardware support first.
if (!await uwb.isUwbAvailable()) return;

// Start BLE discovery. New peers arrive on deviceFound.
await uwb.startDiscovery('my-device');
uwb.deviceFound.listen((device) async {
  // Pair (exchange UWB tokens) then start ranging.
  try {
    await uwb.pairWith(device.id!);
    await uwb.startRanging(device.id!);
  } on UwbException catch (e) {
    print('error: ${e.message}');
  }
});

// Consume ranging samples as they arrive.
uwb.rangingSamples.listen((sample) {
  print('${sample.distanceMeters?.toStringAsFixed(2)} m  '
      '${sample.azimuthDegrees?.toStringAsFixed(1)}°');
});

// Tear down when done.
await uwb.stopRanging();
await uwb.stopDiscovery();
```

> **Both devices** must call `pairWith` before either calls `startRanging`.
> Coordinate the exchange over your own signalling channel (UI button tap,
> QR code, server event, etc.).

---

## Accessory mode

Accessories that speak the Apple FiRa protocol — and Android devices
acting as an accessory — are surfaced as `UwbDevice.platform == "accessory"`
(or `"accessory:<vendorTag>"` when a `vendorTag` is set).

```dart
// Register the accessory's vendor-specific BLE service UUIDs.
await uwb.registerAccessoryProfile(
  serviceUuid: '48FE7E40-CB7C-470E-89ED-5B85A13E67EE',
  rxUuid:      '6E63FF01-87A8-490B-AF2F-FC1D4B67F77A',
  txUuid:      '6E63FF02-87A8-490B-AF2F-FC1D4B67F77A',
  vendorTag:   'qorvo', // optional, namespaces the platform string
);

await uwb.startDiscovery('my-device');
uwb.deviceFound
    .where((d) => (d.platform ?? '').startsWith('accessory'))
    .listen((d) async {
  // No token exchange needed — the Apple protocol handshake runs
  // internally. Just start ranging.
  try {
    await uwb.startRanging(d.id!);
  } on UwbException catch (e) {
    print('accessory ranging error: ${e.message}');
  }
});
```

---

## Streams

| Stream | Fires when |
|--------|-----------|
| `deviceFound` | A new peer is discovered via BLE |
| `deviceLost` | A previously discovered peer disappears |
| `rangingSamples` | A new `RangingSample` arrives from the active session |
| `peerLost` | The ranging peer disconnects mid-session |
| `rangingErrors` | A platform error occurs inside the active session |

---

## API reference

```dart
class FlutterUwb {
  static final FlutterUwb instance;

  // Discovery
  Future<void>         startDiscovery(String localName);
  Future<void>         stopDiscovery();
  Future<List<UwbDevice>> getDiscovered();
  Stream<UwbDevice>    get deviceFound;
  Stream<String>       get deviceLost;

  // Pairing (peer mode)
  Future<void>         pairWith(String deviceId, {UwbRole role});
  Future<Uint8List>    getLocalToken(UwbRole role);     // advanced use
  Future<Uint8List>    exchangeTokens(String deviceId, Uint8List myToken);
  Future<void>         acceptRequest(String deviceId, Uint8List myToken);
  Future<void>         declineRequest(String deviceId);

  // Accessory profiles
  Future<void>         registerAccessoryProfile({
                         required String serviceUuid,
                         required String rxUuid,
                         required String txUuid,
                         String? vendorTag,
                       });
  Future<void>         unregisterAccessoryProfile(String serviceUuid);

  // Ranging
  Future<bool>         isUwbAvailable();
  Future<void>         startRanging(String deviceId);
  Future<void>         stopRanging();
  Stream<RangingSample>     get rangingSamples;
  Stream<String>            get peerLost;
  Stream<RangingErrorEvent> get rangingErrors;
}
```

All mutating methods throw `UwbException` on failure.

```dart
enum UwbRole { controller, controlee }

class RangingSample {
  String? deviceId;
  double? distanceMeters;
  double? azimuthDegrees;
  double? elevationDegrees;
  int?    elapsedRealtimeNanos;
}

class UwbException implements Exception {
  final String message;
}
```

`UwbDevice.platform` values:

| Value | Meaning |
|-------|---------|
| `"ios"` | iOS peer (peer mode) |
| `"android"` | Android peer (peer mode) |
| `"accessory"` | Apple FiRa accessory (built-in handler) |
| `"accessory:<tag>"` | Apple FiRa accessory with registered vendor tag |

---

## Permissions

### Android

The plugin manifest already declares all required permissions. Your app
must request the runtime permissions:

- **API ≥ 31** — `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`
- **API ≤ 30** — `ACCESS_FINE_LOCATION`
- **API ≥ 33** — additionally `UWB_RANGING`

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.UWB_RANGING"/>
```

### iOS

Add the following keys to your app's `Info.plist`. The `usage description`
strings are shown to the user in the system permission prompts, so phrase
them in a way that fits your product.

```xml
<!-- Required: shown when the app first uses Nearby Interaction (UWB). -->
<key>NSNearbyInteractionUsageDescription</key>
<string>Used to measure precise distance to nearby devices over UWB.</string>

<!-- Required: shown when the app first scans / advertises over BLE. -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover nearby devices for UWB ranging.</string>

<!-- Required for iOS↔iOS pairing on iOS 17+. The plugin uses
     MultipeerConnectivity to keep an AWDL sidechannel alive while
     ranging — without it, NearbyInteraction silently never produces
     samples. The Bonjour service name MUST match exactly. -->
<key>NSLocalNetworkUsageDescription</key>
<string>Used to coordinate UWB ranging with nearby iPhones.</string>
<key>NSBonjourServices</key>
<array>
  <string>_flutteruwb-uwb._tcp</string>
  <string>_flutteruwb-uwb._udp</string>
</array>
```

> If your app talks only to Android peers or to FiRa accessories, the
> `NSLocalNetworkUsageDescription` and `NSBonjourServices` keys are not
> strictly required — but adding them is harmless and keeps iOS↔iOS
> ranging working out of the box if a user pairs two iPhones.

---

## Hardware requirements

**Android** — UWB-capable device (Pixel 6 Pro+, Samsung Galaxy S21 Ultra+
or newer). Accessory/controlee mode requires Pixel 7 Pro+ on Android 14+.
`isUwbAvailable()` returns `false` on emulators and devices without the
`FEATURE_UWB` system feature.

**iOS** — iPhone with U1 or U2 chip (iPhone 11+, excluding SE 2nd/3rd gen)
on iOS 14+ for peer mode. Accessory mode requires **iOS 15+**.
`isUwbAvailable()` returns `false` on the simulator.

> **Direction (azimuth / elevation) on iOS 26.** Apple disabled
> `supportsDirectionMeasurement` for the U2 chip on iOS 26, so phones
> with the U2 (iPhone 15 Pro / Pro Max, iPhone 16 series) report `null`
> for `azimuthDegrees` / `elevationDegrees`. Distance is unaffected.
> When pairing a U1 phone with a U2 phone, the U1 side will still
> produce direction values, but only when the phones are roughly
> facing each other. See Apple Developer Forums thread 822522.

---

## Migration

- **v0.2 → v0.3** — see [`doc/migration-v2-to-v3.md`](doc/migration-v2-to-v3.md)
- **v0.1 → v0.2** — see [`doc/migration-v1-to-v2.md`](doc/migration-v1-to-v2.md)

For protocol internals, token formats, and BLE topology see
[`doc/architecture.md`](doc/architecture.md).

---

## License

[MIT](LICENSE)
