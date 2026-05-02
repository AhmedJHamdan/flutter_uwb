/// Apple FiRa accessory BLE protocol codec.
///
/// This is the message format defined by Apple's WWDC 2022 sample
/// *"Implementing Spatial Interactions with Third-Party Accessories Using
/// the U1 Chip"* and used between an iPhone (host / UWB controller) and an
/// accessory (UWB controlee) — a 3rd-party tag, smart lock, car key, etc.
///
/// flutter_uwb uses this same protocol on the iOS↔Android cross-platform
/// path: the Android side speaks Apple's protocol so the iPhone perceives it
/// as just another accessory.
///
/// ## Direction matrix
///
/// | Message id | Direction              | Body                              |
/// | ---------- | ---------------------- | --------------------------------- |
/// | 0x01       | accessory  → iPhone    | accessory's configuration bytes   |
/// | 0x02       | accessory  → iPhone    | (empty)                           |
/// | 0x03       | accessory  → iPhone    | (empty)                           |
/// | 0x0A       | iPhone     → accessory | (empty) — request init bytes      |
/// | 0x0B       | iPhone     → accessory | iPhone's `NIAccessoryConfig` data |
/// | 0x0C       | iPhone     → accessory | (empty) — stop the session        |
///
/// Direction is informational; the codec round-trips any valid id without
/// asserting which side is sending.
library;

import 'dart:typed_data';

/// 1-byte tag at offset 0 of every Apple-accessory protocol message.
///
/// Values are taken from Apple's WWDC 2022 `NIAccessory.swift` sample. They
/// are stable across Apple's published reference firmware.
enum AppleAccessoryMessageId {
  /// Accessory replies with its configuration blob. The body becomes
  /// `NINearbyAccessoryConfiguration(data:)` on the iPhone.
  accessoryConfigurationData(0x01),

  /// Accessory acknowledges that its UWB radio has started.
  accessoryUwbDidStart(0x02),

  /// Accessory acknowledges that its UWB radio has stopped.
  accessoryUwbDidStop(0x03),

  /// iPhone asks the accessory to send its configuration data.
  initialize(0x0A),

  /// iPhone hands the accessory its UWB session parameters and asks the
  /// accessory to start the radio.
  configureAndStart(0x0B),

  /// iPhone tells the accessory to stop the UWB session.
  stop(0x0C);

  const AppleAccessoryMessageId(this.value);

  /// The byte value as it appears on the wire.
  final int value;

  /// Reverse lookup. Returns `null` for unknown bytes.
  static AppleAccessoryMessageId? fromByte(int byte) {
    for (final id in AppleAccessoryMessageId.values) {
      if (id.value == byte) return id;
    }
    return null;
  }
}

/// A decoded Apple-accessory protocol message.
///
/// Use [decode] to parse a message off the wire and [encode] to serialise
/// one back. Each subclass corresponds to one [AppleAccessoryMessageId]
/// value.
sealed class AppleAccessoryMessage {
  const AppleAccessoryMessage();

  /// The message id this instance encodes to. Equivalent to byte 0 of the
  /// wire form.
  AppleAccessoryMessageId get id;

  /// Serialise to wire bytes.
  Uint8List encode();

  /// Parse a fully-reassembled message off the wire.
  ///
  /// Throws [AppleAccessoryProtocolException] if [bytes] is empty, has an
  /// unknown id byte, or the payload is malformed for the recognised id.
  static AppleAccessoryMessage decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const AppleAccessoryProtocolException('Empty message');
    }
    final id = AppleAccessoryMessageId.fromByte(bytes[0]);
    if (id == null) {
      throw AppleAccessoryProtocolException(
        'Unknown message id: 0x${bytes[0].toRadixString(16).padLeft(2, '0')}',
      );
    }
    final payload = bytes.sublist(1);
    return switch (id) {
      AppleAccessoryMessageId.accessoryConfigurationData =>
        AccessoryConfigurationData(payload),
      AppleAccessoryMessageId.accessoryUwbDidStart =>
        _decodeEmpty(id, payload, const AccessoryUwbDidStart()),
      AppleAccessoryMessageId.accessoryUwbDidStop =>
        _decodeEmpty(id, payload, const AccessoryUwbDidStop()),
      AppleAccessoryMessageId.initialize =>
        _decodeEmpty(id, payload, const Initialize()),
      AppleAccessoryMessageId.configureAndStart =>
        ConfigureAndStart(payload),
      AppleAccessoryMessageId.stop =>
        _decodeEmpty(id, payload, const Stop()),
    };
  }

  static T _decodeEmpty<T extends AppleAccessoryMessage>(
    AppleAccessoryMessageId id,
    Uint8List payload,
    T value,
  ) {
    if (payload.isNotEmpty) {
      throw AppleAccessoryProtocolException(
        'Message ${id.name} expects an empty payload, got '
        '${payload.length} byte(s)',
      );
    }
    return value;
  }

  Uint8List _encodeIdOnly() => Uint8List.fromList([id.value]);

  Uint8List _encodeWithPayload(Uint8List payload) {
    final out = Uint8List(1 + payload.length);
    out[0] = id.value;
    out.setRange(1, out.length, payload);
    return out;
  }
}

/// `0x01` accessory → iPhone. Carries the accessory's
/// `NINearbyAccessoryConfiguration` data blob.
final class AccessoryConfigurationData extends AppleAccessoryMessage {
  AccessoryConfigurationData(Uint8List configData)
    : configData = Uint8List.fromList(configData);

  final Uint8List configData;

  @override
  AppleAccessoryMessageId get id =>
      AppleAccessoryMessageId.accessoryConfigurationData;

  @override
  Uint8List encode() => _encodeWithPayload(configData);
}

/// `0x02` accessory → iPhone. Sent after the accessory's radio has come up.
final class AccessoryUwbDidStart extends AppleAccessoryMessage {
  const AccessoryUwbDidStart();

  @override
  AppleAccessoryMessageId get id =>
      AppleAccessoryMessageId.accessoryUwbDidStart;

  @override
  Uint8List encode() => _encodeIdOnly();
}

/// `0x03` accessory → iPhone. Sent after the accessory's radio has shut down.
final class AccessoryUwbDidStop extends AppleAccessoryMessage {
  const AccessoryUwbDidStop();

  @override
  AppleAccessoryMessageId get id =>
      AppleAccessoryMessageId.accessoryUwbDidStop;

  @override
  Uint8List encode() => _encodeIdOnly();
}

/// `0x0A` iPhone → accessory. Triggers the accessory to send its
/// [AccessoryConfigurationData] in reply.
final class Initialize extends AppleAccessoryMessage {
  const Initialize();

  @override
  AppleAccessoryMessageId get id => AppleAccessoryMessageId.initialize;

  @override
  Uint8List encode() => _encodeIdOnly();
}

/// `0x0B` iPhone → accessory. Hands the accessory the iPhone's
/// `NINearbyAccessoryConfiguration` shareable data and asks it to start.
final class ConfigureAndStart extends AppleAccessoryMessage {
  ConfigureAndStart(Uint8List shareableConfigData)
    : shareableConfigData = Uint8List.fromList(shareableConfigData);

  final Uint8List shareableConfigData;

  @override
  AppleAccessoryMessageId get id => AppleAccessoryMessageId.configureAndStart;

  @override
  Uint8List encode() => _encodeWithPayload(shareableConfigData);
}

/// `0x0C` iPhone → accessory. Asks the accessory to halt its UWB session.
final class Stop extends AppleAccessoryMessage {
  const Stop();

  @override
  AppleAccessoryMessageId get id => AppleAccessoryMessageId.stop;

  @override
  Uint8List encode() => _encodeIdOnly();
}

/// Thrown by [AppleAccessoryMessage.decode] when input bytes are malformed.
class AppleAccessoryProtocolException implements Exception {
  const AppleAccessoryProtocolException(this.message);

  final String message;

  @override
  String toString() => 'AppleAccessoryProtocolException: $message';
}
