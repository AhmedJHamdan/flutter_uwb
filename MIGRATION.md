# Migration guide

Steps to take when upgrading `flutter_uwb` across a breaking version
boundary. Bug-fix and additive releases are not listed here — see
[`CHANGELOG.md`](CHANGELOG.md) for the full history.

---

## 0.3.x → 0.4.0

### What broke

- **Android↔Android peers running 0.4.x cannot pair with peers on
  0.3.x.** The OOB BLE handshake now ends with an X25519 ECDH +
  HKDF-SHA256 envelope and HMAC-authenticated token writes; 0.3.x
  peers see a `transportError` event instead of a session.
- **iOS↔Android pairs auto-route to accessory mode.** The discovered
  `UwbDevice.platform` is `accessory:ios` (Android side) or
  `accessory:android` (iOS side) instead of the previous symmetric
  `peer` value that crashed on token parse.
- **Pigeon model fields are non-null where guaranteed.**
  `UwbDevice.id`, `name`, `platform`; `RangingSample.deviceId`,
  `distanceMeters`, `elapsedRealtimeNanos`. Code that treated them
  as nullable now sees analyzer warnings.
- **`onRangingError` signature changed.**
  `void onRangingError(String deviceId, String message)` →
  `void onRangingError(String deviceId, RangingError error)` with a
  typed `UwbErrorCode`.
- **iOS minimum is iOS 16.0** (`flutter_uwb.podspec`,
  `s.platform = :ios, '16.0'`). Hosts on iOS 14 or 15 must pin to
  `^0.3.1`.

### What you need to change

**1. Update peers in lockstep.** Roll out 0.4.x to every device in
your fleet before any of them attempts to range. There is no
mixed-version compatibility on Android↔Android.

**2. Switch error handling to the typed code.**

```dart
// before — 0.3.x
uwb.rangingErrors.listen((event) {
  if (event.message.contains('permission')) { ... }
});

// after — 0.4.0
uwb.rangingErrors.listen((event) {
  if (event.code == UwbErrorCode.permissionDenied) { ... }
});
```

**3. Drop nullability on Pigeon fields.**

```dart
// before
final id = device.id ?? 'unknown';

// after
final id = device.id;  // String, non-nullable
```

**4. Bump the iOS deployment target.** In your example app's
`ios/Podfile`:

```ruby
platform :ios, '16.0'
```

Then run `pod install` from `ios/`.

**5. iOS↔Android pairs**: handle the new `accessory:ios` /
`accessory:android` platform string the same way you handle other
accessories — the public API for both is identical (`pairWith`,
`startRanging`).

---

## 0.2.x → 0.3.0

### What broke

- **All mutating methods throw `UwbException` on failure** instead of
  returning `VoidResult`. Affected:
  `startDiscovery`, `stopDiscovery`, `acceptRequest`,
  `declineRequest`, `registerAccessoryProfile`,
  `unregisterAccessoryProfile`, `startRanging`, `stopRanging`.
- **`getLocalToken` and `exchangeTokens` throw `UwbException` instead
  of `StateError`** for consistency.
- **`VoidResult` is no longer exported** from the public API.

### What you need to change

```dart
// before — 0.2.x
final r = await uwb.startDiscovery('me');
if (!r.ok) showError(r.error);

// after — 0.3.x
try {
  await uwb.startDiscovery('me');
} on UwbException catch (e) {
  showError(e.message);
}
```

If you wrapped multiple calls in a `try` block before, the same block
keeps working — the exception type is the same across all of them.

---

## 0.1.x → 0.2.0

### What broke

- **iOS plugin no longer links `MultipeerConnectivity`.** The iOS↔iOS
  OOB transport moved to the same BLE GATT scheme used on Android.
- **`Info.plist` drops `NSLocalNetworkUsageDescription` and
  `NSBonjourServices`** — they're no longer needed on 0.2.0 (but
  see the 0.3.1 note below if you skipped 0.2.x).
- **Accessory-mode ranging needs iOS 15+.** Peer-mode still works on
  iOS 14+.

### What you need to change

**1. Remove the iOS multipeer keys** from your example app's
`Info.plist` if you had them:

```xml
<!-- delete these lines -->
<key>NSLocalNetworkUsageDescription</key>
<string>...</string>
<key>NSBonjourServices</key>
<array>
  <string>_flutteruwb-uwb._tcp</string>
  <string>_flutteruwb-uwb._udp</string>
</array>
```

> [!NOTE]
> 0.3.1 brought multipeer back for iOS↔iOS to fix the iOS 17 ranging
> hang. If you're going from 0.1.x straight to 0.3.1+, leave the
> Info.plist keys alone (or re-add them per the 0.3.1 changelog).

**2. If you registered accessory profiles** with placeholder UUIDs
during early development, switch to the real UUIDs your accessory
firmware advertises:

```dart
await uwb.registerAccessoryProfile(
  serviceUuid: '<vendor service UUID>',
  rxUuid: '<characteristic accessory listens on>',
  txUuid: '<characteristic accessory pushes on>',
  vendorTag: 'qorvo',  // becomes UwbDevice.platform = "accessory:qorvo"
);
```
