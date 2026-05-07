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

- **Distance + direction** — centimeter-level distance and azimuth/elevation when the hardware supports it.
- **No signalling server** — peers discover each other over BLE / MultipeerConnectivity; the plugin handles UWB token exchange end-to-end.
- **One Dart API, two platforms** — same surface for Android (`androidx.core.uwb`) and iOS (`NearbyInteraction`).
- **Apple FiRa accessories** — talk to Qorvo, NXP, and other certified UWB tags from iOS out of the box.
- **End-to-end encrypted** — every Android↔Android session uses a fresh per-pair key; iOS rides Apple's protected discovery channels.
- **Production-ready** — readiness checks tell you what's supported and which permissions to ask for; typed error codes tell you exactly why something failed, so apps can recover gracefully instead of showing platform stack traces.
- **Streams everywhere** — discovery, ranging samples, errors, and lifecycle events as `Stream`s you can plug into any state-management solution.

## What ranges against what

| Pair                                       | Status |
| ------------------------------------------ | ------ |
| **iPhone ↔ iPhone**                        | ✅ Stable |
| **Android ↔ Android**                      | ✅ Stable |
| **iPhone ↔ Apple-FiRa accessory** (Qorvo, NXP, MFi tag) | ✅ Stable |
| iPhone ↔ Android (cross-OS)                | ❌ Not supported (see [Architecture](#architecture)) |

## Platform support

| Platform    | Minimum hardware                                                            | Notes                                                                                       |
| ----------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Android** | Pixel 6 Pro+, Galaxy S21 Ultra+, or any device exposing `FEATURE_UWB`        | Android 14+ recommended for stable `UwbAvailabilityCallback` behavior.                      |
| **iOS**     | iPhone with U1/U2 chip (iPhone 11+, excluding SE 2/3) on iOS 16+             | Camera assist & extended distance gated by `RangingOptions`. iOS 14/15 hosts must pin to 0.3.1. |

`isUwbAvailable()` returns `false` on emulators, the iOS simulator, and devices without a UWB chip — always check it before calling discovery.

> **iOS 26 / U2 chip caveat.** Apple disabled `supportsDirectionMeasurement` for the U2 chip on iOS 26, so iPhone 15 Pro / Pro Max and the iPhone 16 series report `null` for `azimuthDegrees` and `elevationDegrees`. Distance is unaffected.

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

// Acceptor side — auto-respond when a peer initiates pairing.
uwb.incomingRequests.listen((req) async {
  final myToken = await uwb.getLocalToken(UwbRole.controlee);
  await uwb.acceptRequest(req.device.id, myToken);
  await uwb.startRanging(req.device.id);
});

uwb.rangingSamples.listen((s) {
  print('${s.distanceMeters.toStringAsFixed(2)} m  '
        '${s.azimuthDegrees?.toStringAsFixed(1)}°');
});

await uwb.startDiscovery('phone-A');

// Initiator side — call from your UI when the user picks a peer.
Future<void> pairAndRange(UwbDevice device) async {
  // Accessories handshake via the Apple NI Accessory Protocol — skip pairWith.
  if (!device.platform.startsWith('accessory')) {
    await uwb.pairWith(device.id);
  }
  await uwb.startRanging(device.id);
}
```

When you're done:

```dart
await uwb.stopRanging();
await uwb.stopDiscovery();
```

> Pairing is asymmetric: one side calls `pairWith` (the initiator); the other side's `incomingRequests` stream fires and that side calls `acceptRequest`. Both sides then call `startRanging`. Trigger the initiator from your own UI — a button, a QR scan, a server event, whatever fits.

### Apple-FiRa accessories (iOS only)

To range against a Qorvo, NXP, or third-party Apple-FiRa tag, register the vendor's BLE service triplet before `startDiscovery`:

```dart
await uwb.registerAccessoryProfile(
  serviceUuid: '<accessory service UUID>',
  rxUuid:      '<accessory rx UUID>',
  txUuid:      '<accessory tx UUID>',
  vendorTag:   'my-tag', // optional — surfaces as `accessory:my-tag`
);
```

The accessory shows up in `deviceFound` with `device.platform == 'accessory:my-tag'`. The Quick Start's `pairAndRange` already handles it — the platform check skips `pairWith` and lets `startRanging` drive Apple's NI Accessory Protocol. Calling `registerAccessoryProfile` on Android throws `UwbException` (iOS-only in 1.0.0).

See [`example/lib/main.dart`](example/lib/main.dart) for a working Qorvo DWM3001CDK profile.

A complete runnable demo lives in [`example/`](example/).

## API

| Stream             | Fires when                                                |
| ------------------ | --------------------------------------------------------- |
| `deviceFound`      | A new peer is discovered via BLE / MPC                    |
| `deviceLost`       | A previously-discovered peer disappears                   |
| `incomingRequests` | A peer sends us their UWB token; reply with `acceptRequest` or `declineRequest` |
| `rangingSamples`   | A new `RangingSample` arrives from the active session     |
| `peerLost`         | The ranging peer disconnects mid-session                  |
| `rangingErrors`    | A platform error occurs inside the active session         |

`RangingSample` exposes `distanceMeters`, `azimuthDegrees`, `elevationDegrees`, `elapsedRealtimeNanos` and the originating `deviceId`. All mutating methods throw `UwbException` on failure.

`startRanging` accepts an optional `RangingOptions(cameraAssist, extendedDistance)` for iOS opt-ins. Use `getDeviceCapabilities()` to gate the toggles in your UI.

`checkReadiness()` returns a snapshot of the UWB radio, Bluetooth, and runtime-permission state — use it before `startDiscovery` / `startRanging` to drive an onboarding flow without trying to range first and catching the failure.

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

The Bonjour service names must match exactly. If you only target FiRa accessories, the local-network keys are optional but harmless.
</details>

## Example app

A runnable demo lives in [`example/`](example/). It wires up discovery, pairing, and a live distance/azimuth readout for same-OS pairs and (on iOS) Apple-FiRa accessories.

<p align="center">
  <img src="assets/brand/flutter_uwb_screenshot.png" alt="flutter_uwb example app" width="320"/>
</p>

## Troubleshooting

<details>
<summary><b><code>startDiscovery</code> succeeds on Android but no peers appear</b></summary>

Almost always missing runtime permissions. Android 12+ requires the user to grant `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` and `UWB_RANGING` at runtime — declaring them in the manifest is not enough. Use [`uwb.checkReadiness()`](#api) and request anything in `missingPermissions` (typically with [`permission_handler`](https://pub.dev/packages/permission_handler)) before calling `startDiscovery`.

If permissions are granted and you still see nothing, check that Bluetooth is actually powered on (`r.bluetoothEnabled`) and that the peer is also running 1.0.x — wire-format compatibility with 0.3.x peers ended in 0.4.0.
</details>

<details>
<summary><b><code>UwbErrorCode.regionalRestriction</code> on first ranging call</b></summary>

UWB is regulated and the OS disables ranging in some jurisdictions even on hardware that ships with the radio. There's no programmatic recovery — surface a region-restriction notice to the user.
</details>

<details>
<summary><b>iOS ranging starts then stops "randomly"</b></summary>

If the host app backgrounds during a session, the plugin tears down the active `NISession` and fires `onPeerLost` so the app can react (the alternative is undefined behaviour from `NISession` + `ARSession` left running across suspension). The host app should re-call `startRanging` on foreground if it wants ranging back.

If you see this without backgrounding, the most likely cause is camera-assist on a session whose `ARSession` hasn't received its first frame yet — that surfaces as `NIErrorCodeInvalidARConfiguration` (-5883). Disable `cameraAssist` in `RangingOptions` and retry.
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

For protocol details, token format, BLE/UWB topology, and the ECDH-keyed Provisioned STS handshake on Android, see [`doc/architecture.md`](doc/architecture.md).

## License

[MIT](LICENSE)
