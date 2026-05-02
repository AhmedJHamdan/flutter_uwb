# Changelog

## 0.2.0

Cross-platform v2: a single BLE GATT transport on both platforms plus
accessory-mode ranging via Apple's FiRa accessory BLE protocol.

### Added

- **iOS BLE GATT OOB** — drops MultipeerConnectivity in favour of the
  same custom-service BLE GATT scheme already used on Android, so iOS↔iOS
  and iOS↔Android peer-mode discovery share one transport.
- **Apple FiRa accessory protocol codec** — pure Dart at
  `lib/src/accessory/apple_protocol.dart` (sealed `AppleAccessoryMessage`
  with `Initialize` / `ConfigureAndStart` / `Stop` / `AccessoryConfigurationData`
  / `AccessoryUwbDidStart` / `AccessoryUwbDidStop`). Mirrored in Kotlin
  at `android/.../accessory/AppleProtocol.kt` so each native side can
  dispatch on byte 0 without a Pigeon round-trip per BLE notification.
- **`IosAccessoryStrategy`** (iOS 15+) drives the multi-message Apple
  handshake against an accessory or another phone speaking the same
  protocol, then runs `NINearbyAccessoryConfiguration` for ranging.
- **`AndroidControleeStrategy`** lets Android act as the accessory side
  of the same protocol (against an iPhone host or any Apple-protocol
  controller); maps the Apple shareable-config bytes into
  `RangingParameters` and runs `controleeSessionScope.prepareSession`.
- **`registerAccessoryProfile` / `unregisterAccessoryProfile`** Dart API
  for declaring an accessory's BLE service + rx/tx characteristics +
  optional vendor tag. Replaces an internal placeholder UUID set used
  during early development.
- **`UwbDevice.platform`** taxonomy extended: `"accessory"` for built-in
  Apple-protocol handling and `"accessory:<vendorTag>"` for registered
  vendor namespaces.
- **`RangingStrategy` interface** on both platforms (`RangingStrategy.swift`
  / `RangingStrategy.kt`) plus per-peer-kind concrete strategies
  (`IosPeerStrategy`, `IosAccessoryStrategy`, `AndroidPeerStrategy`,
  `AndroidControleeStrategy`). `UwbHostApiImpl` is now a strategy
  dispatcher.
- 25 Dart unit tests (`test/apple_protocol_test.dart`) plus 9 Kotlin
  unit tests (`AppleProtocolTest.kt`) for the codec, including
  randomised round-trip and malformed-input coverage.

### Changed

- iOS plugin no longer links `MultipeerConnectivity`. `Info.plist`
  drops `NSLocalNetworkUsageDescription` and `NSBonjourServices`.
- iOS accessory-mode ranging needs **iOS 15+**; peer-mode still works
  on iOS 14+.

### Removed

- `MultipeerConnectivity` dependency on iOS.
- The pre-existing scaffold Android test (`FlutterUwbPluginTest.kt`)
  with broken imports was deleted during the strategy refactor.

### Hardware verification gaps (called out so future maintainers can
plan around them)

- iPhone↔iPhone BLE pairing: code complete + sim runtime smoke OK; not
  yet exercised on a real two-iPhone setup.
- iPhone↔Android cross-platform: code complete; FiRa byte layout for
  `AccessoryConfigurationData` and the shareable portion of
  `ConfigureAndStart` carries `TODO(verify)` markers pending validation
  against an iPhone + Pixel-7-Pro-class pairing.
- Android↔accessory: same gating — needs a FiRa-compliant accessory
  with a known service UUID set.

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
