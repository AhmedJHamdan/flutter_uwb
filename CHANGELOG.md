# Changelog

## 0.1.0

Initial public release. Same-platform UWB ranging only (Android↔Android,
iOS↔iOS). Cross-platform iOS↔Android is tracked for v2.

### Android

- Jetpack UWB ranging (`androidx.core.uwb:1.0.0-alpha07`) via
  `controllerSessionScope` / `controleeSessionScope` and a coroutine
  `prepareSession(...).collect { ... }` pipeline. Samples surface to Dart via
  `UwbFlutterApi.onRangingSample`.
- BLE GATT-based OOB transport for discovery and token exchange. Custom
  service UUID `4f1a9a1c-08d8-4b2e-bc6b-6b1d9f8d7b21`.
- Manifest declares the full BLE/UWB permission set, branched by API level
  (legacy `BLUETOOTH`/`ACCESS_FINE_LOCATION` for API ≤ 30, runtime
  `BLUETOOTH_SCAN`/`ADVERTISE`/`CONNECT` for API ≥ 31, `UWB_RANGING` for
  API ≥ 33).
- API-33 4-arg `notifyCharacteristicChanged` form on Android 13+, falling
  back to the deprecated form on older devices.
- Multi-peer-aware GATT server (no single-slot pending-central race).
- Emulator detection — `isUwbAvailable()` returns `false` on Android
  emulators that fake `FEATURE_UWB`.

### iOS

- `NearbyInteraction` (`NISession`) ranging with `NINearbyPeerConfiguration`.
  Samples surface via the same `UwbFlutterApi.onRangingSample` channel.
- `MultipeerConnectivity` for OOB device discovery and `NIDiscoveryToken`
  exchange. Service type `uwb-flutter`.
- Simulator guard — `isUwbAvailable()` returns `false` on the iOS simulator
  (NI is hardware-only).
- Podspec set to `s.platform = :ios, '14.0'` and links
  `NearbyInteraction`/`CoreBluetooth`/`MultipeerConnectivity` frameworks.

### Dart

- Public facade `FlutterUwb.instance` exposing future-returning methods
  and broadcast streams (`deviceFound`, `deviceLost`, `rangingSamples`,
  `peerLost`, `rangingErrors`).
- Pigeon-typed schema with `@async` long-running operations and a
  `@FlutterApi` event channel.
- Top-level convenience functions retained as a thin compat layer.

### Schema

- `UwbHostApi` — 11 methods, 4 of them `@async`.
- `UwbFlutterApi` — 5 callbacks (`onDeviceFound`, `onDeviceLost`,
  `onRangingSample`, `onPeerLost`, `onRangingError`).

### Known limitations

- Cross-platform iOS↔Android UWB pairing is not supported. Tokens are
  opaque platform-specific bytes (Android: 9-byte little-endian blob;
  iOS: `NSKeyedArchiver` of `NIDiscoveryToken`).
- The example app does not request runtime BLE permissions; the host app
  must do that before calling `startDiscovery` on Android 12+.
