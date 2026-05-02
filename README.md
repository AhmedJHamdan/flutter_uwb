<h1 align="center">flutter_uwb</h1>

<p align="center">
  <b>Centimeter-accurate ranging for Flutter.</b><br/>
  Ultra-Wideband distance &amp; direction with zero-config BLE peer discovery — Android &amp; iOS.
</p>

<p align="center">
  <a href="https://pub.dev/packages/flutter_uwb"><img src="https://img.shields.io/pub/v/flutter_uwb.svg?label=pub&color=blue" alt="pub.dev"/></a>
  <img src="https://img.shields.io/badge/Android-API%2023%2B-3DDC84?logo=android&logoColor=white" alt="Android"/>
  <img src="https://img.shields.io/badge/iOS-14%2B-000000?logo=apple&logoColor=white" alt="iOS"/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-purple.svg" alt="License"/></a>
</p>

---

## Why flutter_uwb?

- **Distance + direction** — sub-10 cm distance and azimuth/elevation when the hardware supports it.
- **No signalling server** — peers find each other over BLE; the plugin handles the UWB token exchange.
- **One API, two platforms** — same Dart surface for Android (`androidx.core.uwb`) and iOS (`NearbyInteraction`).
- **Apple FiRa accessories** — talk to Qorvo, NXP and other certified tags out of the box.
- **Streams everywhere** — discovery, ranging samples, errors, and lifecycle events as `Stream`s you can plug into any state-management solution.

## Install

```bash
flutter pub add flutter_uwb
```

> Requires Flutter `>=3.22` and Dart `>=3.3`.

## Quick start

Both peers run the same code. Pick a unique `localName` for each side.

```dart
import 'package:flutter_uwb/flutter_uwb.dart';

final uwb = FlutterUwb.instance;

if (!await uwb.isUwbAvailable()) return;

await uwb.startDiscovery('phone-A');

uwb.deviceFound.listen((device) async {
  await uwb.pairWith(device.id!);     // exchanges UWB tokens
  await uwb.startRanging(device.id!); // begin streaming samples
});

uwb.rangingSamples.listen((s) {
  print('${s.distanceMeters?.toStringAsFixed(2)} m  '
        '${s.azimuthDegrees?.toStringAsFixed(1)}°');
});
```

When you're done:

```dart
await uwb.stopRanging();
await uwb.stopDiscovery();
```

> **Both** peers must call `pairWith` before either calls `startRanging`. Trigger this from your own UI (a button, a QR scan, a server event — whatever fits).

A complete runnable demo lives in [`example/`](example/).

## Streams

| Stream            | Fires when                                                |
| ----------------- | --------------------------------------------------------- |
| `deviceFound`     | A new peer is discovered via BLE                          |
| `deviceLost`      | A previously-discovered peer disappears                   |
| `rangingSamples`  | A new `RangingSample` arrives from the active session     |
| `peerLost`        | The ranging peer disconnects mid-session                  |
| `rangingErrors`   | A platform error occurs inside the active session         |

`RangingSample` exposes `distanceMeters`, `azimuthDegrees`, `elevationDegrees`, `elapsedRealtimeNanos` and the originating `deviceId`. All mutating methods throw `UwbException` on failure.

Full API docs: <https://pub.dev/documentation/flutter_uwb/latest/>

## Accessory mode (Apple FiRa tags)

Register the accessory's vendor BLE UUIDs once, then range like any other peer — no token exchange required.

```dart
await uwb.registerAccessoryProfile(
  serviceUuid: '48FE7E40-CB7C-470E-89ED-5B85A13E67EE',
  rxUuid:      '6E63FF01-87A8-490B-AF2F-FC1D4B67F77A',
  txUuid:      '6E63FF02-87A8-490B-AF2F-FC1D4B67F77A',
  vendorTag:   'qorvo', // optional, namespaces the platform string
);

uwb.deviceFound
   .where((d) => (d.platform ?? '').startsWith('accessory'))
   .listen((d) => uwb.startRanging(d.id!));
```

`UwbDevice.platform` will be `"ios"`, `"android"`, `"accessory"`, or `"accessory:<vendorTag>"`.

## Platform setup

<details>
<summary><b>Android</b></summary>

The plugin manifest already declares the required `<uses-permission>` entries. Your app only needs to **request** them at runtime:

| API level | Runtime permissions                                                              |
| --------- | -------------------------------------------------------------------------------- |
| 31+       | `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`                      |
| ≤ 30      | `ACCESS_FINE_LOCATION`                                                           |
| 33+       | additionally `UWB_RANGING`                                                       |

Use [`permission_handler`](https://pub.dev/packages/permission_handler) or your preferred approach.
</details>

<details>
<summary><b>iOS</b></summary>

Add to `ios/Runner/Info.plist`:

```xml
<key>NSNearbyInteractionUsageDescription</key>
<string>Used to measure precise distance to nearby devices over UWB.</string>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover nearby devices for UWB ranging.</string>

<!-- Required for iOS↔iOS pairing on iOS 17+ (keeps the AWDL sidechannel alive). -->
<key>NSLocalNetworkUsageDescription</key>
<string>Used to coordinate UWB ranging with nearby iPhones.</string>
<key>NSBonjourServices</key>
<array>
  <string>_flutteruwb-uwb._tcp</string>
  <string>_flutteruwb-uwb._udp</string>
</array>
```

The Bonjour service names must match exactly. If you only target Android peers or FiRa accessories, the local-network keys are optional but harmless.
</details>

## Hardware support

| Platform    | Minimum hardware                                                            | Notes                                                                                       |
| ----------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Android** | Pixel 6 Pro+, Galaxy S21 Ultra+, or any device exposing `FEATURE_UWB`        | Accessory/controlee mode requires Pixel 7 Pro+ on Android 14+                               |
| **iOS**     | iPhone with U1/U2 chip (iPhone 11+, excluding SE 2/3) on iOS 14+             | Accessory mode needs iOS 15+                                                                |

`isUwbAvailable()` returns `false` on emulators, the iOS simulator, and devices without a UWB chip — always check it before calling discovery.

> **iOS 26 / U2 chip caveat.** Apple disabled `supportsDirectionMeasurement` for the U2 chip on iOS 26, so iPhone 15 Pro / Pro Max and the iPhone 16 series report `null` for `azimuthDegrees` and `elevationDegrees`. Distance is unaffected. See Apple Developer Forums thread 822522.

## Architecture

For protocol details, token format, and the BLE topology used for discovery and out-of-band exchange, see [`doc/architecture.md`](doc/architecture.md).

## License

[MIT](LICENSE)
