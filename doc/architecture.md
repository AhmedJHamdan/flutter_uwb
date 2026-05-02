# flutter_uwb — Architecture & Protocol Notes

Internal reference for contributors and anyone curious about how the plugin
works under the hood.

---

## Peer matrix

| Peer A | Peer B | Status |
|--------|--------|--------|
| iPhone | iPhone | ✅ shipped |
| Android | Android | ✅ shipped |
| iPhone | Android | ✅ code-complete (runtime verification requires Pixel 7 Pro+ on Android 14+) |
| iPhone | Apple-spec accessory | ✅ code-complete (runtime verification requires real FiRa accessory hardware) |
| Android | Apple-spec accessory | ✅ code-complete (Android-as-host; same hardware gating) |

---

## Token format (peer mode)

`getLocalToken(role)` returns **opaque, platform-specific bytes**. Do not
interpret them on the wire across platforms.

**Android** — 9 bytes, little-endian:

| Offset | Field | Notes |
|--------|-------|-------|
| `[0]` | role | `0` = controller, `1` = controlee |
| `[1..2]` | shortAddr | u16 |
| `[3]` | channel | u8, controller only |
| `[4]` | preambleIndex | u8, controller only |
| `[5..8]` | sessionId | u32, controller only |

**iOS** — `NSKeyedArchiver`-encoded `NIDiscoveryToken`. Opaque; NI sessions
are symmetric so the role byte has no effect on iOS.

Accessory mode does not use `getLocalToken` / `exchangeTokens`. The
multi-message Apple FiRa protocol is driven internally by the plugin.

---

## BLE OOB transport

Both platforms run a symmetric GATT setup using the same UUIDs:

| UUID | Role |
|------|------|
| `4F1A9A1C-08D8-4B2E-BC6B-6B1D9F8D7B21` | Custom flutter_uwb service |
| `B2D2A7F9-8C2A-4D7E-A89D-1D3A4E5F6A70` | Write characteristic (peer sends its token here) |
| `C9A0A82B-0C5A-4B8E-9E2E-5DBE2D08F7C3` | Notify characteristic (reply token arrives here) |

Each device advertises the service UUID and scans for it simultaneously.
Whichever side calls `pairWith` / `exchangeTokens` first becomes the GATT
client; the other side is the GATT server. After the one-shot token swap
both sides call `startRanging` and the BLE link is dropped.

Device identifiers are platform-local UUIDs:
- Central side: `CBPeripheral.identifier.uuidString` (iOS) / BLE MAC address (Android).
- Peripheral side: `CBCentral.identifier.uuidString` (iOS) / BLE MAC address (Android).

**Foreground-only.** iOS BLE peripheral mode does not include the service
UUID in the main advertising packet while backgrounded.

---

## Apple FiRa accessory protocol

The accessory-mode byte protocol is documented in
`lib/src/accessory/apple_protocol.dart` and in Apple's WWDC 2022 sample
*"Implementing Spatial Interactions with Third-Party Accessories Using the
U1 Chip"*.

Message IDs:

| ID | Direction | Body |
|----|-----------|------|
| `0x01` | accessory → iPhone | `NINearbyAccessoryConfiguration` data blob |
| `0x02` | accessory → iPhone | empty (UWB radio started) |
| `0x03` | accessory → iPhone | empty (UWB radio stopped) |
| `0x0A` | iPhone → accessory | empty (request config) |
| `0x0B` | iPhone → accessory | `NIAccessoryConfig` shareable data |
| `0x0C` | iPhone → accessory | empty (stop session) |

Vendor-specific service / characteristic UUIDs are registered via
`registerAccessoryProfile`. The protocol byte format is fixed; only the
BLE UUIDs are vendor-chosen.

---

## Pigeon code generation

The platform channel contract is defined in `pigeons/uwb_api.dart` and
generated with:

```sh
dart run pigeon --input pigeons/uwb_api.dart
```

Generated output lives in `lib/src/pigeon/uwb.g.dart` (Dart),
`android/src/main/kotlin/…/uwb.g.kt` (Kotlin), and
`ios/Classes/uwb.g.swift` (Swift). Do not edit generated files by hand.
