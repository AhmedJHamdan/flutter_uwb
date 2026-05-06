<p align="center">
  <img src="assets/brand/flutter_uwb_banner.png" alt="flutter_uwb — Ultra-wideband proximity for Flutter" width="900"/>
</p>

<p align="center">
  <img src="assets/brand/badges/flutter_uwb_badge_shields.svg" alt="flutter_uwb"/>
  <a href="https://pub.dev/packages/flutter_uwb"><img src="https://img.shields.io/pub/v/flutter_uwb?color=00E5FF&labelColor=0A0E21&style=flat-square" alt="pub.dev"/></a>
  <a href="https://pub.dev/packages/flutter_uwb/score"><img src="https://img.shields.io/pub/points/flutter_uwb?color=00E5FF&labelColor=0A0E21&style=flat-square" alt="pub.dev points"/></a>
  <img src="https://img.shields.io/badge/platforms-iOS%20%7C%20Android-02569B?style=flat-square&labelColor=0A0E21" alt="platforms"/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-6B7392?style=flat-square&labelColor=0A0E21" alt="license"/></a>
</p>

## <img src="assets/brand/flutter_uwb_pulse.svg" width="20" align="left"/> Features

- **Distance + direction** — sub-10 cm distance and azimuth/elevation when the hardware supports it.
- **No signalling server** — peers find each other over BLE; the plugin handles the UWB token exchange.
- **One API, two platforms** — same Dart surface for Android (`androidx.core.uwb`) and iOS (`NearbyInteraction`).
- **Apple FiRa accessories** — talk to Qorvo, NXP and other certified tags out of the box.
- **End-to-end encrypted** — Android↔Android sessions are keyed by an X25519 ECDH handshake over BLE OOB.
- **Streams everywhere** — discovery, ranging samples, errors, and lifecycle events as `Stream`s you can plug into any state-management solution.

## Platform support

| Platform    | Minimum hardware                                                            | Notes                                                                                       |
| ----------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Android** | Pixel 6 Pro+, Galaxy S21 Ultra+, or any device exposing `FEATURE_UWB`        | Accessory/controlee mode requires Pixel 7 Pro+ on Android 14+.                              |
| **iOS**     | iPhone with U1/U2 chip (iPhone 11+, excluding SE 2/3) on iOS 16+             | Camera assist & extended distance gated by `RangingOptions`. iOS 14/15 hosts must pin to 0.3.1. |

`isUwbAvailable()` returns `false` on emulators, the iOS simulator, and devices without a UWB chip — always check it before calling discovery.

> **iOS 26 / U2 chip caveat.** Apple disabled `supportsDirectionMeasurement` for the U2 chip on iOS 26, so iPhone 15 Pro / Pro Max and the iPhone 16 series report `null` for `azimuthDegrees` and `elevationDegrees`. Distance is unaffected.

> **Cross-OS (iPhone ↔ Android) is experimental in 0.4.0.** BLE handshake and Android UWB session activation complete, but `androidx.core.uwb` rejects the slot duration Apple selects, so stable distance samples are not yet delivered. Same-OS pairs (iOS↔iOS, Android↔Android) are stable. iPhones are auto-discovered on Android and vice-versa — no `registerAccessoryProfile` boilerplate is needed for cross-OS.

## Installation

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
  await uwb.pairWith(device.id);     // exchanges UWB tokens
  await uwb.startRanging(device.id); // begin streaming samples
});

uwb.rangingSamples.listen((s) {
  print('${s.distanceMeters.toStringAsFixed(2)} m  '
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

## API

| Stream            | Fires when                                                |
| ----------------- | --------------------------------------------------------- |
| `deviceFound`     | A new peer is discovered via BLE                          |
| `deviceLost`      | A previously-discovered peer disappears                   |
| `rangingSamples`  | A new `RangingSample` arrives from the active session     |
| `peerLost`        | The ranging peer disconnects mid-session                  |
| `rangingErrors`   | A platform error occurs inside the active session         |
| `sessionState`    | Aggregate `idle → discovering → pairing → ranging` view   |

`RangingSample` exposes `distanceMeters`, `azimuthDegrees`, `elevationDegrees`, `elapsedRealtimeNanos` and the originating `deviceId`. All mutating methods throw `UwbException` on failure.

`startRanging` accepts an optional `RangingOptions(cameraAssist, extendedDistance)` for iOS opt-ins. Use `getDeviceCapabilities()` to gate the toggles in your UI.

For accessory mode (Qorvo, NXP, third-party FiRa tags), use `registerAccessoryProfile(serviceUuid, rxUuid, txUuid, vendorTag)`. iPhones running `flutter_uwb` are auto-discovered on Android without this step.

Full API docs: <https://pub.dev/documentation/flutter_uwb/latest/>

## Permissions

<details>
<summary><b>Android</b></summary>

The plugin manifest already declares the required `<uses-permission>` entries. Your app only needs to **request** them at runtime:

| API level | Runtime permissions                                                              |
| --------- | -------------------------------------------------------------------------------- |
| 31+       | `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`                      |
| ≤ 30      | `ACCESS_FINE_LOCATION`                                                           |
| 33+       | additionally `UWB_RANGING`                                                       |

```kotlin
import android.Manifest
import android.os.Build
import androidx.core.app.ActivityCompat

private val perms: Array<String> = buildList {
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
    add(Manifest.permission.BLUETOOTH_SCAN)
    add(Manifest.permission.BLUETOOTH_ADVERTISE)
    add(Manifest.permission.BLUETOOTH_CONNECT)
  } else {
    add(Manifest.permission.ACCESS_FINE_LOCATION)
  }
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
    add(Manifest.permission.UWB_RANGING)
  }
}.toTypedArray()

ActivityCompat.requestPermissions(this, perms, /*requestCode*/ 1)
```
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

## Example app

A runnable cross-platform demo lives in [`example/`](example/). It wires up discovery, pairing, and a live distance/azimuth readout for both same-OS and cross-OS pairs.

<p align="center">
  <img src="assets/brand/flutter_uwb_screenshot.png" alt="flutter_uwb example app" width="320"/>
</p>

## Troubleshooting

<details>
<summary><b><code>startDiscovery</code> succeeds on Android but no peers appear</b></summary>

Almost always missing runtime permissions. Android 12+ requires the user to grant `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` and `UWB_RANGING` at runtime — declaring them in the manifest is not enough. Use [`uwb.checkReadiness()`](#api) and request anything in `missingPermissions` (typically with [`permission_handler`](https://pub.dev/packages/permission_handler)) before calling `startDiscovery`.

If permissions are granted and you still see nothing, check that Bluetooth is actually powered on (`r.bluetoothEnabled`) and that the peer is also running 0.4.x — 0.4.x peers cannot pair with 0.3.x peers (see [`MIGRATION.md`](MIGRATION.md)).
</details>

<details>
<summary><b><code>UwbErrorCode.regionalRestriction</code> on first ranging call</b></summary>

UWB is disabled by the OS in a small number of jurisdictions (Russia, Indonesia, parts of South America). The hardware is present but the radio is locked. There's no programmatic recovery — surface a region-restriction notice to the user.
</details>

<details>
<summary><b><code>isUwbAvailable()</code> returns <code>false</code> on a Pixel 6/7/8</b></summary>

If the device has a UWB radio and isn't region-restricted, the most common cause is a stale `UwbManager` state after the screen-lock cycle. Toggle airplane mode once and retry. If it still returns false, confirm the build is on Android 14+ — older Android versions report UWB inconsistently.
</details>

<details>
<summary><b>iOS ranging starts then stops "randomly"</b></summary>

If the host app backgrounds during a session, the plugin tears down the active `NISession` and fires `onPeerLost` so the app can react (the alternative is undefined behaviour from `NISession` + `ARSession` left running across suspension). The host app should re-call `startRanging` on foreground if it wants ranging back.

If you see this without backgrounding, the most likely cause is camera-assist on a session whose `ARSession` hasn't received its first frame yet — that surfaces as `NIErrorCodeInvalidARConfiguration` (-5883). Disable `cameraAssist` in `RangingOptions` and retry.
</details>

<details>
<summary><b>Cross-OS (iPhone ↔ Android) pairs but never produces samples</b></summary>

Known limitation in 0.4.x. BLE discovery, the Apple-FiRa accessory handshake, and Android UWB session activation all complete, but `androidx.core.uwb` rejects the slot duration Apple selects so distance samples are not delivered. Same-OS pairs are unaffected. Tracked for v0.5.0.
</details>

<details>
<summary><b>How to enable verbose plugin logs</b></summary>

```dart
import 'package:flutter_uwb/flutter_uwb.dart';

void main() {
  if (kDebugMode) UwbLog.setLevel(UwbLogLevel.debug);
  UwbLog.setHandler((level, msg) => debugPrint('[uwb] [$level] $msg'));
  runApp(const MyApp());
}
```

Native logs: `adb logcat | grep flutter_uwb` on Android, Xcode console filtered by subsystem `flutter_uwb` on iOS.
</details>

## Architecture

For protocol details, token format, BLE/UWB topology, the ECDH-keyed Provisioned STS handshake, and the cross-OS capability-flag routing matrix, see [`doc/architecture.md`](doc/architecture.md).

## License

[MIT](LICENSE)
