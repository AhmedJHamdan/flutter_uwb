# flutter_uwb — Architecture & Protocol Notes

Internal reference for contributors and anyone curious about how the plugin
works under the hood.

---

## Peer matrix

| Peer A | Peer B | Routing | Status |
|--------|--------|---------|--------|
| iPhone | iPhone | peer mode (`NINearbyPeerConfiguration` over MPC) | ✅ shipped |
| Android | Android | peer mode (`UwbControllerSessionScope` over BLE OOB + ECDH-keyed Provisioned STS, 0.4.0+) | ✅ shipped |
| iPhone | Android | accessory mode (Apple FiRa over the symmetric BLE service) — auto-routed via the `OobCapability` flag, no `registerAccessoryProfile` boilerplate | 🚧 experimental in 0.4.0; the BLE handshake completes and an Android UWB session reaches `ACTIVE`, but `androidx.core.uwb` rejects the slot duration Apple selects, so stable samples are not yet delivered |
| iPhone | Apple-spec accessory | accessory mode (Apple FiRa over BLE) | ✅ code-complete (real FiRa accessory required) |
| Android | Apple-spec accessory | accessory mode (Android-as-host) | ✅ code-complete (same hardware gating) |

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

iOS publishes the same service via `CBPeripheralManager` so the
service is discoverable from Android centrals. iOS BLE advertisements
cannot carry service-data (Apple strips it), so an Android scan that
matches the symmetric UUID with no service-data is treated as an iOS
peer by convention — Android always emits `[0x02]`.

When the symmetric service hosts a cross-OS pair, the GATT server
sniffs the first byte written to `CHAR_WRITE`: `0x0A`/`0x0B`/`0x0C`
flips the central into Apple-FiRa accessory mode and routes inbound
bytes to the `AndroidControleeStrategy`; `0x01`/`0x02` keeps it on the
ECDH peer-handshake path. Replies go back through `CHAR_NOTIFY` either
way.

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

## OobCapability flag (cross-OS routing)

Every flutter_uwb peer advertises a 1-byte capability flag in its OOB
channel. Both natives parse it on discovery and pin
`UwbDevice.platform` accordingly so the strategy dispatcher routes the
session without guessing.

| Wire byte | Meaning             | Carrier on Android (BLE service-data of `4F1A9A1C-…`) | Carrier on iOS (`MCNearbyServiceAdvertiser.discoveryInfo`) |
|-----------|---------------------|--------------------------------------------------------|------------------------------------------------------------|
| `0x01`    | iOS peer            | (not advertised by Android)                            | `{"caps": "0x01"}`                                         |
| `0x02`    | Android peer        | `[0x02]`                                               | (not advertised by iOS)                                    |
| `0x03`    | Accessory host (reserved) | —                                                | —                                                          |
| missing   | back-compat default | treated as `0x01` on Android scans of the symmetric service (iOS BLE strips service-data, so absence implies an iOS peer) | treated as `0x01` on iOS MPC parses |

Routing matrix — what `UwbDevice.platform` becomes on each side after
parsing the remote flag:

| Local stack | Remote flag | `UwbDevice.platform` | Strategy                  |
|-------------|-------------|----------------------|---------------------------|
| Android     | `0x02`      | `android`            | `AndroidPeerStrategy`     |
| Android     | `0x01`      | `accessory:ios`      | `AndroidControleeStrategy`|
| iOS         | `0x01`      | `ios`                | `IosPeerStrategy`         |
| iOS         | `0x02`      | `accessory:android`  | `IosAccessoryStrategy`    |

The Dart constant set is in `lib/src/oob_capability.dart`; the native
mirrors are `OobCapability.kt` and `OobCapability.swift`. Reserved
values `0x03`–`0xFF` map to the back-compat default until a future
release claims them.

---

## Provisioned STS (Android↔Android)

0.4.0 wraps the BLE OOB token swap in an ECDH-keyed envelope so the
UWB radio session that follows is encrypted under a key both peers
agree on out-of-band, instead of running with `sessionKeyInfo = null`
like 0.3.x did.

Layered handshake on top of the existing GATT service:

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
| ECDH + HKDF + envelope    | `android/.../oob/OobHandshake.kt` (+ `OobHandshake.swift` for future iOS↔Android peer transports) |
| Chunked framing           | `android/.../oob/BleFramer.kt`             |
| Per-connection state machine | `android/.../oob/BleOob.kt`             |
| sessionKey storage        | `android/.../oob/TokenStore.kt`            |
| Hand-off into UWB radio   | `android/.../strategy/AndroidPeerStrategy.kt` (`sessionKeyInfo`) |

iOS↔iOS peer pairing keeps MultipeerConnectivity's `.required`
encryption — no ECDH layer added on top, by design.

iOS↔Android cross-OS pairs route through the Apple FiRa accessory
protocol, where STS material comes from the iPhone's `NISession` and
is forwarded into the Android radio via
`AppleProtocol.parseAppleUWBConfigData`. The 30-byte
`AppleUWBConfigData` payload's byte layout (session id, channel,
preamble, 6-byte STS IV, peer short address) is pinned by golden
fixtures in `android/src/test/resources/apple_protocol/` captured
from a real iPhone. Cross-OS ranging is experimental in 0.4.0.

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
