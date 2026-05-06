# flutter_uwb example

A Find-My-style demo that exercises the public `flutter_uwb` API
end-to-end: BLE discovery, OOB pairing, live distance / azimuth /
elevation readout, and a precision-find arrow that rotates toward
the peer.

## What the app demonstrates

- **Discovery + pairing** via the BLE OOB transport (`startDiscovery`,
  `pairWith`, `startRanging`).
- **Real-time ranging samples** rendered as both an animated radar
  (distance only) and a rotating cyan arrow (when the peer reports a
  direction vector).
- **Precision Find toggles** — camera assist, extended distance, raw
  AoA — moved into the Settings tab.
- **Capability surface** — what `getDeviceCapabilities()` returns on
  the current device, surfaced as the right-hand "Settings" tab.
- **Accessory profiles** — register an Apple-FiRa accessory's BLE
  service / Rx / Tx UUIDs at runtime.

## Running the app

```sh
cd example
flutter pub get
flutter run -d <device-id>
```

UWB ranging only produces samples on real hardware. The iOS simulator
and most Android emulators report `isUwbAvailable() == false`; the
app still launches but the Ranging tab will show "UWB unavailable on
this device" until you run on a supported phone.

### Supported hardware

| Platform | Minimum |
| --- | --- |
| iOS | iPhone 11 or newer (U1 or U2 chip), iOS 16+ |
| Android | Pixel 6 Pro+, Pixel 7+, Pixel 8+, or any phone exposing `FEATURE_UWB` |

For accessory mode, the demo is verified against the Qorvo DWM3001CDK
reference firmware. Other Apple-NI-compatible accessories should work
once their BLE service UUIDs are registered (Settings tab → Accessory
profiles).

## Permissions

On startup the app calls `uwb.checkReadiness()` and feeds any
ungranted Android permissions into
[`permission_handler`](https://pub.dev/packages/permission_handler).
A banner across the Ranging tab tells the user when Bluetooth is
off, when permissions are still missing, or when the device has no
UWB radio.

The check re-runs on `AppLifecycleState.resumed`, so a user who
walks to system Settings to grant a permission and comes back sees
the banner clear without restarting the app.

iOS exposes no runtime API to query Bluetooth / Nearby Interaction
permission — the OS prompts on first use driven by the Info.plist
usage descriptions, and `checkReadiness().permissionsGranted` is
always `true` on iOS.

## Where things live

| File | What it does |
| --- | --- |
| `lib/main.dart` | Tab scaffold, ranging state machine, accessory-profile UI |
| `lib/brand.dart` | Brand tokens (cyan #00E5FF, navy #0A0E21) and the `ThemeData` builder |
| `lib/widgets/precision_arrow.dart` | Rotating chevron with a proximity-tinted radial glow; replaces the radar when direction is available |
| `lib/widgets/radar.dart` | Animated pulse radar shown when ranging is active without direction |
| `lib/widgets/readout_card.dart` | Distance / azimuth / elevation readout cards |

## Troubleshooting

If something looks wrong, the
[main README's Troubleshooting section](../README.md#troubleshooting)
covers the common cases. For the example specifically:

- "Settings tab shows everything as `false`" → you're on a simulator
  or a device without UWB; `getDeviceCapabilities()` returns the
  conservative fallback.
- "Discovery never finds the peer" → both phones must run the
  example app simultaneously and have the same plugin major version.
  See [`MIGRATION.md`](../MIGRATION.md) for cross-version
  compatibility notes.
