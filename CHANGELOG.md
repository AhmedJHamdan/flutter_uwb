# Changelog

## 0.5.0 (unreleased)

### Added

- **Accessory adapter framework on Android.** Implement
  `AccessoryAdapter.handshake(AccessoryConnection)` to ship your own
  BLE-OOB protocol against custom UWB hardware. The plugin keeps
  owning BLE transport and the FiRa session lifecycle; your adapter
  drives the byte-level exchange and returns a `FiraSessionParams`
  the plugin uses to open `controllerSessionScope`. The connection
  stays alive across the entire ranging session so adapters can
  schedule keep-alive writes or read state mid-session at the
  application level.
- `FlutterUwb.registerAccessoryAdapter` / `unregisterAccessoryAdapter`
  Dart API plus `AccessoryAdapter`, `AccessoryConnection`, and
  `FiraSessionParams` types in the public surface.
- `StaticPairAccessoryAdapter` (built-in, `vendorTag = 'qorvo-static'`)
  for developer-bench validation against a Qorvo DWM3001CDK running
  CLI firmware. Surfaces a synthetic "Qorvo (static demo)" tile when
  the host registers a Qorvo accessory profile so the framework
  round-trip is exercisable without rewriting an existing app.
- `tools/qorvo/` checked-in helper scripts (`qorvo_send.py`,
  `qorvo_cli.py`, `auto_sync.py`) for driving a Qorvo CLI from a
  Mac during the static-pair demo.

### Changed

- The existing Apple-NI accessory mode on Android is repackaged as
  the built-in `AppleNiAccessoryAdapter`. **No code changes
  required** for apps that today register an `AccessoryProfile`
  without an accompanying adapter — the framework falls back to the
  built-in for unregistered tags and the discovered
  `accessory:<vendor>` device routes through it transparently.
- iOS accessory mode is unchanged; the framework is Android-only in
  v1. iOS Pigeon stubs throw `unsupported` if a developer mistakenly
  calls a framework method on iOS.

### Notes

- Slot duration via Jetpack `androidx.core.uwb` stays gated to {1, 2}
  ms. Adapters that need the Apple-NI 3 ms slot duration get a clear
  "unsupported on this Android version" error from
  `completeAccessoryHandshake`; an `android.ranging.*` fallback is a
  follow-up.

## 0.4.1

- Shrink the brand shields-style badge SVG to 137×20 (was 220×32) so
  it lines up vertically with the flat-square shields.io badges next
  to it on the README hero. Asset content unchanged — only the outer
  `<svg>` width/height; viewBox preserves the layout. No code changes.

## 0.4.0

**BREAKING release.** Closes the security gap on Android↔Android UWB
ranging, fixes the silently-broken iOS↔Android peer-mode dispatch,
brings the Android stack onto `androidx.core.uwb:1.0.0-rc01`, and
tightens the Pigeon schema.

> **Cross-OS (iPhone ↔ Android) is experimental in 0.4.0.** BLE
> discovery, the Apple-FiRa accessory handshake, and Android UWB
> session activation all complete, but the underlying
> `androidx.core.uwb` API rejects the slot duration Apple selects, so
> stable distance samples are not yet delivered. Same-OS pairs are
> unaffected.

### Added

- **Provisioned STS for Android↔Android peer ranging.** Every BLE OOB
  exchange now begins with an X25519 ECDH handshake (HKDF-SHA256
  derivation of a 16-byte UWB session key + a 16-byte HMAC key). The
  derived session key is fed into `RangingParameters.sessionKeyInfo`
  so the UWB radio session is encrypted end-to-end. Token writes are
  HMAC-authenticated; tampered or replayed tokens are rejected before
  reaching the UWB stack.
- `OobCapability` byte advertised in BLE service-data on Android and
  in `MCNearbyServiceAdvertiser.discoveryInfo` on iOS so cross-OS
  pairs auto-route to accessory mode and same-OS pairs stay on peer
  mode without guessing. Peers running 0.3.x advertise no byte; on
  Android scans of the symmetric service the absence is now treated
  as `iosPeer` (iOS BLE strips service-data from advertisements, so
  missing service-data unambiguously means an iOS host).
- iOS now publishes the symmetric BLE service via
  `CBPeripheralManager` and scans for it as a central, mirroring
  Android's existing GATT setup. An iPhone shows up in an Android
  device list as `accessory:ios` and a Galaxy in an iPhone list as
  `accessory:android` automatically — no `registerAccessoryProfile`
  boilerplate required for cross-OS pairs.
- The Android GATT server now sniffs the first byte on the symmetric
  `CHAR_WRITE` to dispatch a connecting central into either the
  Apple-FiRa accessory protocol (Initialize/ConfigureAndStart/Stop)
  or the ECDH peer-handshake path. Replies route back through the
  shared `CHAR_NOTIFY`.
- `RangingOptions` Pigeon struct on `startRanging` (`cameraAssist`,
  `extendedDistance`).
- `DeviceCapabilities` Pigeon struct + `getDeviceCapabilities()`
  unifying `NIDeviceCapability` (iOS) and `RangingCapabilities`
  (Android).
- `UwbErrorCode` typed error code returned via the new
  `RangingError(code, message)` event.
- `Stream<UwbSessionState>` aggregate on the Dart facade.
- `androidx.core.uwb:1.0.0-rc01` (was `1.0.0-alpha07`):
  `UwbManager.isAvailable()`,
  `subscribeToUwbAvailability(UwbAvailabilityCallback)`,
  `RangingResultInitialized` / `RangingResultFailure(reasonCode)`.
- `compileSdk` / `targetSdk` bumped to 35.
- BLE OOB now requests an ATT MTU of 247 with a chunked-write
  fallback (`BleFramer`) when the negotiation stays at the default
  23-byte window.
- Symmetric `incomingRequests` on Android — the Pigeon
  `onIncomingRequest` now fires on both platforms (was iOS only).
- `UwbHostApiImpl.dispose()` is wired through
  `FlutterUwbPlugin.onDetachedFromEngine` (Android) and
  `detachFromEngine` (iOS) so hot-restart no longer leaks BLE
  resources.

### Changed (BREAKING)

- **0.4.0 peers cannot pair with 0.3.x peers over Android↔Android
  BLE OOB.** The new ECDH+HMAC envelope is incompatible. 0.3.x peers
  fail with a `transportError` event instead of silently hanging.
- iOS↔Android pairs now auto-route to accessory mode. The discovered
  `UwbDevice.platform` is `accessory:ios` (Android side) /
  `accessory:android` (iOS side) instead of the previous symmetric
  `peer` value that crashed on token parse.
- Pigeon model fields go non-null where guaranteed (`UwbDevice.id`,
  `name`, `platform`; `RangingSample.deviceId`, `distanceMeters`,
  `elapsedRealtimeNanos`). Dart code that treated them as nullable
  now sees analyzer warnings.
- `void onRangingError(String deviceId, String message)` becomes
  `void onRangingError(String deviceId, RangingError error)` with a
  typed `UwbErrorCode`.
- iOS minimum bumps to **iOS 16.0** (`flutter_uwb.podspec`,
  `s.platform`). Hosts on iOS 14/15 must pin to 0.3.1.

### Notes

- `OobHandshake.swift` is published for wire-compatibility but is not
  on any active code path in 0.4.0 — cross-OS pairs go through Apple's
  FiRa accessory protocol whose STS material comes from `NISession`.
- The Apple-FiRa accessory protocol decoder
  (`AppleProtocol.parseAppleUWBConfigData`) reads the iPhone-emitted
  30-byte `AppleUWBConfigData` payload (session id, channel, preamble,
  6-byte STS IV, peer short address). The byte layout is pinned by
  golden fixtures captured from a real iPhone, stored under
  `android/src/test/resources/apple_protocol/`.

## 0.3.1

### Added

- `FlutterUwb.incomingRequests` — broadcast `Stream<IncomingRequest>`
  that fires when a peer sends us their token over the OOB transport
  (peer-initiated pairing). The companion class `IncomingRequest`
  carries the originating `UwbDevice` and the peer's token bytes,
  ready to feed into a local ranging session via `acceptRequest` +
  `startRanging`. The example app now auto-accepts incoming requests
  to demonstrate the symmetric pairing flow.

### Fixed

- **iOS↔iOS ranging on iOS 17+ / iOS 26 no longer hangs.** The plugin
  now uses `MultipeerConnectivity` for the iOS↔iOS out-of-band token
  exchange, which keeps an AWDL sidechannel alive during ranging.
  Previously, with the BLE-only OOB transport introduced in 0.2.0,
  `NINearbyPeerConfiguration` would stay in `nearbyd #lifecycle
  DISCOVERY active` indefinitely and never produce samples on
  iOS 17+. iOS↔Android (FiRa accessory) and Android↔Android paths are
  unchanged. See Apple Developer Forums thread 802204 for context.

### iOS host apps must add two `Info.plist` keys

Existing apps that integrate `flutter_uwb` need to add the following to
their `Info.plist`, otherwise iOS↔iOS discovery silently returns no
peers:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Used to coordinate UWB ranging with nearby iPhones.</string>
<key>NSBonjourServices</key>
<array>
  <string>_flutteruwb-uwb._tcp</string>
  <string>_flutteruwb-uwb._udp</string>
</array>
```

The Bonjour service name must match exactly. See the README for
context.

### Removed (internal)

- The dormant BLE GATT peer-mode code path on iOS (`CBPeripheralManager`
  advertise + custom-service GATT server, `BleOob.exchange` /
  `BleOob.accept` / `BleOob.decline`). It was no longer invoked once
  iOS↔iOS pairing moved to MultipeerConnectivity, and removing it
  shrinks `BleOob.swift` to its accessory-mode responsibilities only.
  No public Dart API change.

### Unchanged

- All previously-existing Dart API methods, types, and streams keep
  their current signatures. `incomingRequests` is purely additive —
  apps that don't listen to it behave exactly as before.
- Android plugin code and the iOS↔Android (FiRa accessory) /
  Android↔Android transports.

### Hardware verification

- iPhone 12 (U1, iOS 26.4.1) ↔ iPhone 16 Pro Max (U2, iOS 26.4):
  pairing succeeds, distance updates in real time. As documented by
  Apple, the U2 chip on iOS 26 reports `nil` for direction, so
  azimuth/elevation are only available on the U1 side and only when
  the phones are roughly facing each other.

## 0.3.0

### Changed

- All mutating methods now throw `UwbException` on failure instead of
  returning `VoidResult`. Affected: `startDiscovery`, `stopDiscovery`,
  `acceptRequest`, `declineRequest`, `registerAccessoryProfile`,
  `unregisterAccessoryProfile`, `startRanging`, `stopRanging`.
- `getLocalToken` and `exchangeTokens` now throw `UwbException` instead
  of `StateError` for consistency.
- `VoidResult` is no longer exported from the public API.

### Added

- `pairWith(String deviceId, {UwbRole role})` — convenience method that
  combines `getLocalToken` + `exchangeTokens` in a single call.

## 0.2.0+1

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
- iPhone↔Android cross-platform: BLE handshake and Android UWB session
  activation work end-to-end; stable distance samples are blocked by
  `androidx.core.uwb` slot-duration constraints (see the experimental
  note above).
- Android↔accessory: needs a FiRa-compliant accessory with a known
  service UUID set.

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
