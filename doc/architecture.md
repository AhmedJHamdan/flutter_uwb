# flutter_uwb — Architecture & Protocol Notes

Internal reference for contributors and anyone curious about how the plugin
works under the hood.

---

## Peer matrix

| Peer A | Peer B | Routing |
|--------|--------|---------|
| iPhone | iPhone | peer mode (`NINearbyPeerConfiguration` over MultipeerConnectivity) |
| Android | Android | peer mode (`UwbControllerSessionScope` over BLE OOB + ECDH-keyed Provisioned STS) |
| iPhone | Apple FiRa accessory (Qorvo / NXP / MFi tag) | accessory mode (Apple NI Accessory Protocol over BLE) |

Cross-OS (iPhone ↔ Android) is not supported in 1.0.0. Both attempted
paths — `androidx.core.uwb` driving an Apple-FiRa controlee on Android,
and the Galaxy ↔ Qorvo CLI fallback — hit chip / firmware-level walls
that aren't fixable from the plugin layer.

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
multi-message Apple NI Accessory Protocol is driven internally by the
plugin.

---

## BLE OOB transport (Android↔Android)

Two Android peers run a symmetric GATT setup using these UUIDs:

| UUID | Role |
|------|------|
| `4F1A9A1C-08D8-4B2E-BC6B-6B1D9F8D7B21` | flutter_uwb peer service |
| `B2D2A7F9-8C2A-4D7E-A89D-1D3A4E5F6A70` | Write characteristic (peer sends its token here) |
| `C9A0A82B-0C5A-4B8E-9E2E-5DBE2D08F7C3` | Notify characteristic (reply token arrives here) |

Each device advertises the service UUID and scans for it
simultaneously. Whichever side calls `pairWith` / `exchangeTokens`
first becomes the GATT client; the other side is the GATT server.
After the one-shot token swap both sides call `startRanging` and the
BLE link is dropped.

Device identifiers are platform-local UUIDs:
- Central side: BLE MAC address (Android `BluetoothDevice.address`).
- Peripheral side: BLE MAC address.

**Foreground-only.** BLE peripheral mode does not include the service
UUID in the main advertising packet while backgrounded.

---

## Apple FiRa accessory protocol (iOS-only)

The accessory-mode byte protocol is Apple's NI Accessory Protocol,
documented in Apple's WWDC 2022 sample *"Implementing Spatial
Interactions with Third-Party Accessories Using the U1 Chip"*.

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
`registerAccessoryProfile`. The protocol byte format is fixed; only
the BLE UUIDs are vendor-chosen.

Driven by `IosAccessoryStrategy` on iOS. `registerAccessoryProfile`
returns an error on Android in 1.0.0 — Android-as-accessory never
delivered samples and was dropped.

---

## Provisioned STS (Android↔Android)

The BLE OOB token swap is wrapped in an ECDH-keyed envelope so the UWB
radio session that follows is encrypted under a key both peers agree
on out-of-band.

Layered handshake on top of the GATT service above:

```
Client (initiator)                              Server (acceptor)

connectGatt
  → requestMtu(247)                             onMtuChanged(247)
  → discoverServices

write CHAR_WRITE = [0x01 || pubkey_C]   ────►   onCharacteristicWriteRequest
                                                derive(privkey_S, pubkey_C)
                                                store SessionKeys[client]
                                       ◄────    notify CHAR_NOTIFY = [0x01 || pubkey_S]
derive(privkey_C, pubkey_S)
store SessionKeys[server]

write CHAR_WRITE = [0x02 ||             ────►   onCharacteristicWriteRequest
   HMAC-SHA256_truncated[16] || token_C]        verify HMAC, drop on mismatch
                                                TokenStore.put(token_C, sessionKey)
                                                onIncomingRequest()
                                                accept(token_S)
                                       ◄────    notify CHAR_NOTIFY = [0x02 ||
                                                  HMAC-SHA256_truncated[16] || token_S]
verify HMAC, drop on mismatch
TokenStore.put(token_S, sessionKey)
onPeer(token_S)
```

Wire format:

- Inner messages are prefixed with a 1-byte type:
  - `0x01` — handshake (followed by 32-byte X25519 raw public key, RFC 7748 little-endian).
  - `0x02` — token (followed by `[16-byte HMAC tag || token bytes]`).
- Outer framing is `BleFramer` chunked: 1-byte header `[isLast<<7 | seq]`
  + body. With MTU 247 most messages fit in one fragment; with MTU 23
  the handshake pubkey takes two fragments.

Key derivation:

- Curve: X25519 (RFC 7748).
- KDF: HKDF-SHA256 with salt `"flutter_uwb v1 hkdf salt"`.
- Outputs: 16-byte UWB session key (`info = "flutter_uwb v1 session key"`)
  and 16-byte HMAC key (`info = "flutter_uwb v1 mac key"`).
- The session key is fed verbatim into
  `RangingParameters.sessionKeyInfo`. The HMAC key is kept in-process
  for the lifetime of the BLE connection.

Implementation files:

| Layer                     | File                                       |
|---------------------------|--------------------------------------------|
| ECDH + HKDF + envelope    | `android/.../oob/OobHandshake.kt`          |
| Chunked framing           | `android/.../oob/BleFramer.kt`             |
| Per-connection state machine | `android/.../oob/BleOob.kt`             |
| sessionKey storage        | `android/.../oob/TokenStore.kt`            |
| Hand-off into UWB radio   | `android/.../strategy/AndroidPeerStrategy.kt` (`sessionKeyInfo`) |

iOS↔iOS peer pairing keeps MultipeerConnectivity's `.required`
encryption — no ECDH layer added on top, by design.

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
