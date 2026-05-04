# Apple accessory protocol fixtures

Byte-level fixtures for the Apple-FiRa accessory message format used by the
`AccessoryConfigurationData` / `ConfigureAndStart` exchange between an
iPhone (`NIAccessoryConfiguration`) and a FiRa-compatible accessory.

## Files

- `initialize.bin` — `[0x0A]`, sent host→accessory to start the dance.
- `accessory_uwb_did_start.bin` — `[0x02]`, accessory→host signal.
- `accessory_uwb_did_stop.bin` — `[0x03]`, accessory→host signal.
- `stop.bin` — `[0x0C]`, host→accessory teardown.
- `accessory_configuration_data_synthetic.bin` — `[0x01, ...]`. **Synthetic.**
  The Apple-protocol Dart codec round-trip test uses this file purely to
  verify the envelope framing — it does not assert on the inner FiRa
  payload structure.
- `configure_and_start_synthetic.bin` — `[0x0B, ...]`. **Synthetic.** Same
  caveat as above. (Real iPhone-emitted `AppleUWBConfigData` payloads
  used by the Android-side parser tests live separately under
  `android/src/test/resources/apple_protocol/`.)

## Why synthetic for the configuration messages

The inner payloads of `AccessoryConfigurationData` (the
`NINearbyAccessoryConfiguration` shareable bytes) and `ConfigureAndStart`
(the FiRa shareable config) are produced by Apple's `NearbyInteraction`
framework on a real iPhone with a real `NIDiscoveryToken`. They are not
defined by Apple as a stable public byte format and we cannot fabricate
correct ones without running the framework.

The fixtures here use the documented envelope (1-byte message id followed
by an opaque payload) with a deterministic synthetic payload so that:

- The codec's framing logic is pinned by a golden file.
- The Dart codec is decoupled from the inner FiRa payload's byte layout,
  which is parsed on the Android side from real iPhone captures.

## How to capture real fixtures

On an iPhone with the WWDC22 `NIAccessory` sample app modified to log the
bytes written to the accessory's Rx characteristic, dump the raw
characteristic-write `Data` to a file and copy it here. Replace the
`*_synthetic.bin` files and drop the `_synthetic` suffix.
