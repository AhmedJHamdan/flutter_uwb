# Migrating from flutter_uwb v0.1.x to v0.2.0

v0.2.0 is **additive**. The peer-mode public API has not changed;
existing v0.1.0 code continues to work without source modifications.
Three things are worth knowing if you're upgrading:

## 1. iOS OOB transport switched from MultipeerConnectivity to BLE GATT

**Internal change.** No public API impact — `startDiscovery`,
`exchangeTokens`, `acceptRequest`, etc. behave the same. But because the
transport is different, host apps need to update `Info.plist`:

**Remove**:
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>...</string>
<key>NSBonjourServices</key>
<array>
  <string>_uwb-flutter._tcp</string>
  <string>_uwb-flutter._udp</string>
</array>
```

**Keep / add**:
```xml
<key>NSNearbyInteractionUsageDescription</key>
<string>Used to measure precise distance to nearby phones over UWB.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover nearby phones for UWB ranging.</string>
```

## 2. Accessory mode is new

Accessory-mode ranging adds two Dart APIs and a new `UwbDevice.platform`
value. None of this affects v0.1.0 code paths.

```dart
// New in v0.2.0
Future<VoidResult> registerAccessoryProfile({
  required String serviceUuid,
  required String rxUuid,
  required String txUuid,
  String? vendorTag,
});
Future<VoidResult> unregisterAccessoryProfile(String serviceUuid);
```

`UwbDevice.platform` may now be:
- `"ios"` / `"android"` — peer-mode (unchanged from v0.1.0).
- `"accessory"` — Apple-FiRa-spec accessory using the built-in handler.
- `"accessory:<vendorTag>"` — Apple-FiRa-spec accessory with a vendor
  tag from `registerAccessoryProfile`.

If your code does `switch (device.platform)` exhaustively, add cases
for the accessory variants (or treat `accessory:*` as a default).

For accessory-mode peers, you do **not** call `getLocalToken` /
`exchangeTokens`. Just `startRanging(deviceId)` after the peer appears
in `deviceFound`; the plugin drives the multi-message handshake
internally.

## 3. iOS 15+ required for accessory mode

Peer-mode (`NINearbyPeerConfiguration`) still works on iOS 14+.
Accessory-mode (`NINearbyAccessoryConfiguration`) is iOS 15+. The
plugin gates this with `@available(iOS 15.0, *)` and surfaces
"Accessory ranging requires iOS 15.0 or newer." as a `VoidResult.error`
if you call `startRanging` against an `accessory` device on iOS 14.

If your app already targets iOS 15+ in its podfile, you don't need to
do anything. Otherwise, bump the deployment target before relying on
accessory mode.

## Test plan

The peer-mode regression check is identical to v0.1.0 — start the
example on two same-platform devices, confirm discovery + token
exchange + ranging samples.

For the new accessory-mode functionality, the plan recommends:

| Test | Hardware needed | Notes |
| --- | --- | --- |
| iPhone↔iPhone BLE peer pairing | Two iPhones with U1/U2 | Phase A acceptance — also verifies the new BLE transport on iOS. |
| iPhone↔Android peer | One iPhone + one Pixel 6 Pro+ | Same flow as v0.1.0 token exchange but routed over BLE on both sides. |
| iPhone↔FiRa accessory | One iPhone + one accessory | Register the accessory's profile; expect `UwbDevice.platform = "accessory"`. |
| Android↔iPhone (Android-as-controlee) | Pixel 7 Pro+ on Android 14+ | Validates `AccessoryConfigurationData` byte layout; current implementation marks unverified parts with `TODO(verify)`. |
| Android↔FiRa accessory | Pixel 7 Pro+ + accessory | Same as iPhone↔accessory but Android plays the host role. |

When validating the cross-platform path, capture the bytes of the
`ConfigureAndStart` payload off-wire and compare to what
`apple_protocol.dart`'s `parseAccessoryConfigurationData` expects — the
FiRa byte layout is the most likely mismatch source.
