import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_uwb/flutter_uwb.dart';
import 'package:flutter_uwb/src/pigeon/uwb.g.dart' as pigeon;

/// Channel name helper to avoid string drift between tests and codegen.
String _hostChan(String method) =>
    'dev.flutter.pigeon.flutter_uwb.UwbHostApi.$method';
String _flutterChan(String method) =>
    'dev.flutter.pigeon.flutter_uwb.UwbFlutterApi.$method';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    for (final m in [
      'startDiscovery',
      'stopDiscovery',
      'getDiscovered',
      'acceptRequest',
      'declineRequest',
      'exchangeTokens',
      'isUwbAvailable',
      'getLocalToken',
      'startRanging',
      'stopRanging',
    ]) {
      binaryMessenger.setMockMessageHandler(_hostChan(m), null);
    }
  });

  group('FlutterUwb facade', () {
    test('public API surface', () {
      final uwb = FlutterUwb.instance;
      expect(uwb.startDiscovery, isA<Function>());
      expect(uwb.stopDiscovery, isA<Function>());
      expect(uwb.getDiscovered, isA<Function>());
      expect(uwb.acceptRequest, isA<Function>());
      expect(uwb.declineRequest, isA<Function>());
      expect(uwb.exchangeTokens, isA<Function>());
      expect(uwb.isUwbAvailable, isA<Function>());
      expect(uwb.getLocalToken, isA<Function>());
      expect(uwb.startRanging, isA<Function>());
      expect(uwb.stopRanging, isA<Function>());
      expect(uwb.deviceFound, isA<Stream<UwbDevice>>());
      expect(uwb.deviceLost, isA<Stream<String>>());
      expect(uwb.rangingSamples, isA<Stream<RangingSample>>());
      expect(uwb.peerLost, isA<Stream<String>>());
      expect(uwb.rangingErrors, isA<Stream<RangingErrorEvent>>());
    });

    test('isUwbAvailable forwards true through the Pigeon channel', () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      binaryMessenger.setMockMessageHandler(_hostChan('isUwbAvailable'),
          (ByteData? message) async => codec.encodeMessage(<Object?>[true]));
      expect(await FlutterUwb.instance.isUwbAvailable(), isTrue);
    });

    test('isUwbAvailable forwards false through the Pigeon channel',
        () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      binaryMessenger.setMockMessageHandler(_hostChan('isUwbAvailable'),
          (ByteData? message) async => codec.encodeMessage(<Object?>[false]));
      expect(await FlutterUwb.instance.isUwbAvailable(), isFalse);
    });

    test('startDiscovery decodes VoidResult.ok=true', () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      binaryMessenger.setMockMessageHandler(_hostChan('startDiscovery'),
          (ByteData? message) async {
        return codec.encodeMessage(<Object?>[
          pigeon.VoidResult(ok: true),
        ]);
      });
      final result = await FlutterUwb.instance.startDiscovery('demo');
      expect(result.ok, isTrue);
    });

    test('exchangeTokens returns the bytes from the host', () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      final canned = Uint8List.fromList([10, 20, 30, 40]);
      binaryMessenger.setMockMessageHandler(_hostChan('exchangeTokens'),
          (ByteData? message) async {
        return codec.encodeMessage(<Object?>[
          pigeon.TokenPayload(bytes: canned),
        ]);
      });
      final out = await FlutterUwb.instance
          .exchangeTokens('peer-id', Uint8List.fromList([1, 2, 3]));
      expect(out, equals(canned));
    });

    test('getLocalToken returns bytes for both roles', () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      final canned = Uint8List.fromList(List<int>.generate(9, (i) => i));
      binaryMessenger.setMockMessageHandler(_hostChan('getLocalToken'),
          (ByteData? message) async {
        return codec.encodeMessage(<Object?>[
          pigeon.TokenPayload(bytes: canned),
        ]);
      });
      expect(
          await FlutterUwb.instance.getLocalToken(UwbRole.controller), canned);
      expect(
          await FlutterUwb.instance.getLocalToken(UwbRole.controlee), canned);
    });
  });

  group('Stream wiring (FlutterApi → broadcast streams)', () {
    test('onDeviceFound pushes into the deviceFound stream', () async {
      const codec = pigeon.UwbFlutterApi.pigeonChannelCodec;
      final received = <UwbDevice>[];
      final sub = FlutterUwb.instance.deviceFound.listen(received.add);

      final device = UwbDevice(id: 'abc', name: 'Bob', platform: 'android');
      final msg = codec.encodeMessage(<Object?>[device]);
      await binaryMessenger.handlePlatformMessage(
        _flutterChan('onDeviceFound'),
        msg,
        (_) {},
      );

      // Allow the stream microtask to drain.
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.first.id, 'abc');
      expect(received.first.name, 'Bob');
      expect(received.first.platform, 'android');
      await sub.cancel();
    });

    test('onRangingSample pushes into the rangingSamples stream', () async {
      const codec = pigeon.UwbFlutterApi.pigeonChannelCodec;
      final received = <RangingSample>[];
      final sub = FlutterUwb.instance.rangingSamples.listen(received.add);

      final sample = RangingSample(
        deviceId: 'peer',
        distanceMeters: 1.5,
        azimuthDegrees: 12.3,
        elevationDegrees: -4.5,
        elapsedRealtimeNanos: 1234567890,
      );
      final msg = codec.encodeMessage(<Object?>[sample]);
      await binaryMessenger.handlePlatformMessage(
        _flutterChan('onRangingSample'),
        msg,
        (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.first.distanceMeters, 1.5);
      expect(received.first.deviceId, 'peer');
      await sub.cancel();
    });

    test('onRangingError pushes a RangingErrorEvent', () async {
      const codec = pigeon.UwbFlutterApi.pigeonChannelCodec;
      final received = <RangingErrorEvent>[];
      final sub = FlutterUwb.instance.rangingErrors.listen(received.add);

      final msg = codec.encodeMessage(<Object?>['device-1', 'kaboom']);
      await binaryMessenger.handlePlatformMessage(
        _flutterChan('onRangingError'),
        msg,
        (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.first.deviceId, 'device-1');
      expect(received.first.message, 'kaboom');
      await sub.cancel();
    });
  });
}
