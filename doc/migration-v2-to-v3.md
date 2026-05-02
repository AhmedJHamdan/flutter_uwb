# Migrating from v0.2 to v0.3

v0.3.0 is a breaking release. All changes are in the public Dart API;
no platform (Kotlin/Swift) code or Pigeon layer changed.

## VoidResult → exceptions

Every method that previously returned `Future<VoidResult>` now returns
`Future<void>` and throws `UwbException` on failure.

**Before**

```dart
final result = await uwb.startDiscovery('my-device');
if (!(result.ok ?? false)) {
  print('error: ${result.error}');
}
```

**After**

```dart
try {
  await uwb.startDiscovery('my-device');
} on UwbException catch (e) {
  print('error: ${e.message}');
}
```

Affected methods: `startDiscovery`, `stopDiscovery`, `acceptRequest`,
`declineRequest`, `registerAccessoryProfile`, `unregisterAccessoryProfile`,
`startRanging`, `stopRanging`.

## StateError → UwbException

`getLocalToken` and `exchangeTokens` previously threw `StateError` on an
empty platform token. They now throw `UwbException` for consistency.

```dart
// Before
try {
  final token = await uwb.getLocalToken(UwbRole.controller);
} on StateError catch (e) { ... }

// After
try {
  final token = await uwb.getLocalToken(UwbRole.controller);
} on UwbException catch (e) { ... }
```

## VoidResult no longer exported

`VoidResult` is no longer part of the public API. Remove any import or
reference to it in your code.

## New: pairWith()

`pairWith(deviceId, {role})` replaces the `getLocalToken` + `exchangeTokens`
two-step sequence for the common peer-mode case.

```dart
// Before
final myToken = await uwb.getLocalToken(UwbRole.controller);
await uwb.exchangeTokens(deviceId, myToken);

// After
await uwb.pairWith(deviceId); // role defaults to UwbRole.controller
```

The individual `getLocalToken` and `exchangeTokens` methods remain available
for advanced use cases.
