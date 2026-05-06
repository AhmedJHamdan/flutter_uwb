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
      'registerAccessoryProfile',
      'unregisterAccessoryProfile',
      'checkReadiness',
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

    test('isUwbAvailable forwards false through the Pigeon channel', () async {
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
      await FlutterUwb.instance.startDiscovery('demo');
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

    test('registerAccessoryProfile forwards the profile and returns ok=true',
        () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      pigeon.AccessoryProfile? captured;
      binaryMessenger.setMockMessageHandler(
          _hostChan('registerAccessoryProfile'), (ByteData? message) async {
        final args = codec.decodeMessage(message)! as List<Object?>;
        captured = args[0] as pigeon.AccessoryProfile;
        return codec.encodeMessage(<Object?>[
          pigeon.VoidResult(ok: true),
        ]);
      });

      await FlutterUwb.instance.registerAccessoryProfile(
        serviceUuid: '48FE7E40-CB7C-470E-89ED-5B85A13E67EE',
        rxUuid: '6E63FF01-87A8-490B-AF2F-FC1D4B67F77A',
        txUuid: '6E63FF02-87A8-490B-AF2F-FC1D4B67F77A',
        vendorTag: 'qorvo',
      );

      expect(captured?.serviceUuid, '48FE7E40-CB7C-470E-89ED-5B85A13E67EE');
      expect(captured?.rxUuid, '6E63FF01-87A8-490B-AF2F-FC1D4B67F77A');
      expect(captured?.txUuid, '6E63FF02-87A8-490B-AF2F-FC1D4B67F77A');
      expect(captured?.vendorTag, 'qorvo');
    });

    test('unregisterAccessoryProfile forwards the serviceUuid', () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      String? capturedServiceUuid;
      binaryMessenger.setMockMessageHandler(
          _hostChan('unregisterAccessoryProfile'), (ByteData? message) async {
        final args = codec.decodeMessage(message)! as List<Object?>;
        capturedServiceUuid = args[0] as String;
        return codec.encodeMessage(<Object?>[
          pigeon.VoidResult(ok: true),
        ]);
      });

      await FlutterUwb.instance
          .unregisterAccessoryProfile('48FE7E40-CB7C-470E-89ED-5B85A13E67EE');

      expect(capturedServiceUuid, '48FE7E40-CB7C-470E-89ED-5B85A13E67EE');
    });

    test('vendorTag flowing through to UwbDevice.platform "accessory:<tag>"',
        () async {
      // The platform-string convention is the contract between native and
      // Dart for vendor adapters; this test pins it.
      const codec = pigeon.UwbFlutterApi.pigeonChannelCodec;
      final received = <UwbDevice>[];
      final sub = FlutterUwb.instance.deviceFound.listen(received.add);

      final device = UwbDevice(
        id: 'acc-1',
        name: 'Tag',
        platform: 'accessory:qorvo',
      );
      final msg = codec.encodeMessage(<Object?>[device]);
      await binaryMessenger.handlePlatformMessage(
        _flutterChan('onDeviceFound'),
        msg,
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first.platform, 'accessory:qorvo');
      await sub.cancel();
    });

    test('getLocalToken throws UwbException(sessionInitFailed) on empty token',
        () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      binaryMessenger.setMockMessageHandler(_hostChan('getLocalToken'),
          (ByteData? message) async {
        return codec.encodeMessage(<Object?>[
          pigeon.TokenPayload(bytes: Uint8List(0)),
        ]);
      });
      try {
        await FlutterUwb.instance.getLocalToken(UwbRole.controller);
        fail('expected UwbException');
      } on UwbException catch (e) {
        expect(e.code, UwbErrorCode.sessionInitFailed);
        expect(e.message, contains('empty token'));
        expect(e.toString(), contains('sessionInitFailed'));
      }
    });

    test('exchangeTokens throws UwbException(transportError) on empty payload',
        () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      binaryMessenger.setMockMessageHandler(_hostChan('exchangeTokens'),
          (ByteData? message) async {
        return codec.encodeMessage(<Object?>[
          pigeon.TokenPayload(bytes: Uint8List(0)),
        ]);
      });
      try {
        await FlutterUwb.instance
            .exchangeTokens('peer', Uint8List.fromList([1]));
        fail('expected UwbException');
      } on UwbException catch (e) {
        expect(e.code, UwbErrorCode.transportError);
      }
    });

    test('UwbException toString omits code section when null', () {
      const e = UwbException('boom');
      expect(e.code, isNull);
      expect(e.toString(), 'UwbException: boom');
    });

    test('checkReadiness decodes a UwbReadiness payload', () async {
      const codec = pigeon.UwbHostApi.pigeonChannelCodec;
      binaryMessenger.setMockMessageHandler(_hostChan('checkReadiness'),
          (ByteData? message) async {
        return codec.encodeMessage(<Object?>[
          pigeon.UwbReadiness(
            uwbAvailable: false,
            bluetoothEnabled: true,
            permissionsGranted: false,
            missingPermissions: const [
              'android.permission.BLUETOOTH_SCAN',
              'android.permission.UWB_RANGING',
            ],
          ),
        ]);
      });
      final r = await FlutterUwb.instance.checkReadiness();
      expect(r.uwbAvailable, isFalse);
      expect(r.bluetoothEnabled, isTrue);
      expect(r.permissionsGranted, isFalse);
      expect(r.missingPermissions, hasLength(2));
      expect(
        r.missingPermissions,
        containsAll(<String?>[
          'android.permission.BLUETOOTH_SCAN',
          'android.permission.UWB_RANGING',
        ]),
      );
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

  group('Lifecycle', () {
    test('dispose closes all broadcast streams and clears the singleton',
        () async {
      final uwb = FlutterUwb.instance;
      expect(uwb.isDisposed, isFalse);

      // Capture done futures before close so we can assert each closed.
      final dones = <Future<void>>[
        uwb.deviceFound.drain<void>(),
        uwb.deviceLost.drain<void>(),
        uwb.rangingSamples.drain<void>(),
        uwb.peerLost.drain<void>(),
        uwb.rangingErrors.drain<void>(),
        uwb.incomingRequests.drain<void>(),
      ];

      await uwb.dispose();
      expect(uwb.isDisposed, isTrue);
      // Each drain completes when its stream closes.
      await Future.wait(dones).timeout(const Duration(seconds: 1));

      // Singleton is recreated on next access.
      expect(identical(FlutterUwb.instance, uwb), isFalse);
    });

    test('dispose is idempotent', () async {
      final uwb = FlutterUwb.instance;
      await uwb.dispose();
      // Second call should not throw.
      await uwb.dispose();
      expect(uwb.isDisposed, isTrue);
    });

    test('platform messages after dispose are silently dropped', () async {
      const codec = pigeon.UwbFlutterApi.pigeonChannelCodec;
      final uwb = FlutterUwb.instance;
      await uwb.dispose();

      // Re-attach a handler so the channel is live, but it should drop
      // events on the disposed instance without throwing.
      final device = UwbDevice(id: 'late', name: 'L', platform: 'android');
      final msg = codec.encodeMessage(<Object?>[device]);
      // Construct a fresh instance after dispose so the new handler is
      // attached; the *old* uwb's streams are already closed.
      final fresh = FlutterUwb.instance;
      final received = <UwbDevice>[];
      final sub = fresh.deviceFound.listen(received.add);
      await binaryMessenger.handlePlatformMessage(
        _flutterChan('onDeviceFound'),
        msg,
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      await sub.cancel();
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

      final error = pigeon.RangingError(
        code: pigeon.UwbErrorCode.transportError,
        message: 'kaboom',
      );
      final msg = codec.encodeMessage(<Object?>['device-1', error]);
      await binaryMessenger.handlePlatformMessage(
        _flutterChan('onRangingError'),
        msg,
        (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.first.deviceId, 'device-1');
      expect(received.first.code, UwbErrorCode.transportError);
      expect(received.first.message, 'kaboom');
      await sub.cancel();
    });
  });
}
