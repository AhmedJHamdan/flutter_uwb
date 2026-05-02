import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_uwb/src/accessory/apple_protocol.dart';

void main() {
  group('AppleAccessoryMessageId', () {
    test('byte values match Apple WWDC 2022 NIAccessory.swift', () {
      expect(AppleAccessoryMessageId.accessoryConfigurationData.value, 0x01);
      expect(AppleAccessoryMessageId.accessoryUwbDidStart.value, 0x02);
      expect(AppleAccessoryMessageId.accessoryUwbDidStop.value, 0x03);
      expect(AppleAccessoryMessageId.initialize.value, 0x0A);
      expect(AppleAccessoryMessageId.configureAndStart.value, 0x0B);
      expect(AppleAccessoryMessageId.stop.value, 0x0C);
    });

    test('fromByte returns null for unknown ids', () {
      expect(AppleAccessoryMessageId.fromByte(0x00), isNull);
      expect(AppleAccessoryMessageId.fromByte(0x04), isNull);
      expect(AppleAccessoryMessageId.fromByte(0x09), isNull);
      expect(AppleAccessoryMessageId.fromByte(0x0D), isNull);
      expect(AppleAccessoryMessageId.fromByte(0xFF), isNull);
    });

    test('fromByte resolves all known ids', () {
      for (final id in AppleAccessoryMessageId.values) {
        expect(AppleAccessoryMessageId.fromByte(id.value), id);
      }
    });
  });

  group('Golden bytes', () {
    test('Initialize encodes to [0x0A]', () {
      expect(const Initialize().encode(), Uint8List.fromList([0x0A]));
    });

    test('Stop encodes to [0x0C]', () {
      expect(const Stop().encode(), Uint8List.fromList([0x0C]));
    });

    test('AccessoryUwbDidStart encodes to [0x02]', () {
      expect(
        const AccessoryUwbDidStart().encode(),
        Uint8List.fromList([0x02]),
      );
    });

    test('AccessoryUwbDidStop encodes to [0x03]', () {
      expect(
        const AccessoryUwbDidStop().encode(),
        Uint8List.fromList([0x03]),
      );
    });

    test('AccessoryConfigurationData encodes [id, ...payload]', () {
      final payload = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      expect(
        AccessoryConfigurationData(payload).encode(),
        Uint8List.fromList([0x01, 0xDE, 0xAD, 0xBE, 0xEF]),
      );
    });

    test('ConfigureAndStart encodes [id, ...payload]', () {
      final payload = Uint8List.fromList([0x11, 0x22, 0x33]);
      expect(
        ConfigureAndStart(payload).encode(),
        Uint8List.fromList([0x0B, 0x11, 0x22, 0x33]),
      );
    });

    test('AccessoryConfigurationData with empty payload encodes to [0x01]',
        () {
      expect(
        AccessoryConfigurationData(Uint8List(0)).encode(),
        Uint8List.fromList([0x01]),
      );
    });
  });

  group('Round-trip', () {
    test('Initialize', () {
      final decoded = AppleAccessoryMessage.decode(const Initialize().encode());
      expect(decoded, isA<Initialize>());
    });

    test('Stop', () {
      final decoded = AppleAccessoryMessage.decode(const Stop().encode());
      expect(decoded, isA<Stop>());
    });

    test('AccessoryUwbDidStart', () {
      final decoded = AppleAccessoryMessage.decode(
        const AccessoryUwbDidStart().encode(),
      );
      expect(decoded, isA<AccessoryUwbDidStart>());
    });

    test('AccessoryUwbDidStop', () {
      final decoded = AppleAccessoryMessage.decode(
        const AccessoryUwbDidStop().encode(),
      );
      expect(decoded, isA<AccessoryUwbDidStop>());
    });

    test('AccessoryConfigurationData preserves payload', () {
      final payload = Uint8List.fromList(
        List<int>.generate(64, (i) => i & 0xFF),
      );
      final decoded = AppleAccessoryMessage.decode(
        AccessoryConfigurationData(payload).encode(),
      );
      expect(decoded, isA<AccessoryConfigurationData>());
      expect(
        (decoded as AccessoryConfigurationData).configData,
        equals(payload),
      );
    });

    test('ConfigureAndStart preserves payload', () {
      final payload = Uint8List.fromList(
        List<int>.generate(128, (i) => (i * 7) & 0xFF),
      );
      final decoded = AppleAccessoryMessage.decode(
        ConfigureAndStart(payload).encode(),
      );
      expect(decoded, isA<ConfigureAndStart>());
      expect(
        (decoded as ConfigureAndStart).shareableConfigData,
        equals(payload),
      );
    });

    test('payload-bearing messages survive empty payloads', () {
      final c1 = AppleAccessoryMessage.decode(
        AccessoryConfigurationData(Uint8List(0)).encode(),
      );
      expect(
        (c1 as AccessoryConfigurationData).configData,
        equals(Uint8List(0)),
      );

      final c2 = AppleAccessoryMessage.decode(
        ConfigureAndStart(Uint8List(0)).encode(),
      );
      expect(
        (c2 as ConfigureAndStart).shareableConfigData,
        equals(Uint8List(0)),
      );
    });
  });

  group('Property: random payloads round-trip', () {
    test('AccessoryConfigurationData over 200 random sizes', () {
      final rng = Random(0xC0FFEE);
      for (var i = 0; i < 200; i++) {
        final size = rng.nextInt(512); // 0..511 bytes
        final bytes = Uint8List.fromList(
          List<int>.generate(size, (_) => rng.nextInt(256)),
        );
        final decoded = AppleAccessoryMessage.decode(
          AccessoryConfigurationData(bytes).encode(),
        );
        expect(decoded, isA<AccessoryConfigurationData>());
        expect(
          (decoded as AccessoryConfigurationData).configData,
          equals(bytes),
        );
      }
    });

    test('ConfigureAndStart over 200 random sizes', () {
      final rng = Random(0xBADF00D);
      for (var i = 0; i < 200; i++) {
        final size = rng.nextInt(512);
        final bytes = Uint8List.fromList(
          List<int>.generate(size, (_) => rng.nextInt(256)),
        );
        final decoded = AppleAccessoryMessage.decode(
          ConfigureAndStart(bytes).encode(),
        );
        expect(decoded, isA<ConfigureAndStart>());
        expect(
          (decoded as ConfigureAndStart).shareableConfigData,
          equals(bytes),
        );
      }
    });
  });

  group('Defensive copy on construction', () {
    test('AccessoryConfigurationData stored bytes are independent of caller',
        () {
      final source = Uint8List.fromList([1, 2, 3, 4]);
      final msg = AccessoryConfigurationData(source);
      source[0] = 99;
      expect(msg.configData[0], 1);
    });

    test('ConfigureAndStart stored bytes are independent of caller', () {
      final source = Uint8List.fromList([10, 20, 30]);
      final msg = ConfigureAndStart(source);
      source[1] = 99;
      expect(msg.shareableConfigData[1], 20);
    });
  });

  group('Malformed input', () {
    test('empty bytes throws', () {
      expect(
        () => AppleAccessoryMessage.decode(Uint8List(0)),
        throwsA(isA<AppleAccessoryProtocolException>()),
      );
    });

    test('unknown id byte throws', () {
      for (final unknown in [0x00, 0x04, 0x09, 0x0D, 0x10, 0xFF]) {
        expect(
          () => AppleAccessoryMessage.decode(Uint8List.fromList([unknown])),
          throwsA(isA<AppleAccessoryProtocolException>()),
          reason: 'id 0x${unknown.toRadixString(16)} should be rejected',
        );
      }
    });

    test('empty-body message rejects extra bytes', () {
      // id=Initialize (0x0A) but with a stray payload byte — must throw.
      expect(
        () => AppleAccessoryMessage.decode(Uint8List.fromList([0x0A, 0x42])),
        throwsA(isA<AppleAccessoryProtocolException>()),
      );
      expect(
        () => AppleAccessoryMessage.decode(Uint8List.fromList([0x0C, 0x00])),
        throwsA(isA<AppleAccessoryProtocolException>()),
      );
      expect(
        () => AppleAccessoryMessage.decode(Uint8List.fromList([0x02, 0x01])),
        throwsA(isA<AppleAccessoryProtocolException>()),
      );
    });
  });

  group('Decode dispatches by id', () {
    test('all known ids resolve to the correct subclass', () {
      // Use a 1-byte payload for id values that accept payloads, 0-byte for
      // the empty-body ones — the resolved subclass is what matters here.
      Uint8List one(int id) => Uint8List.fromList([id]);
      Uint8List two(int id) => Uint8List.fromList([id, 0x00]);

      expect(
        AppleAccessoryMessage.decode(two(0x01)),
        isA<AccessoryConfigurationData>(),
      );
      expect(
        AppleAccessoryMessage.decode(one(0x02)),
        isA<AccessoryUwbDidStart>(),
      );
      expect(
        AppleAccessoryMessage.decode(one(0x03)),
        isA<AccessoryUwbDidStop>(),
      );
      expect(AppleAccessoryMessage.decode(one(0x0A)), isA<Initialize>());
      expect(
        AppleAccessoryMessage.decode(two(0x0B)),
        isA<ConfigureAndStart>(),
      );
      expect(AppleAccessoryMessage.decode(one(0x0C)), isA<Stop>());
    });
  });
}
