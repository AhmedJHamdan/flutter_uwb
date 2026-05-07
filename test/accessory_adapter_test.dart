import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_uwb/flutter_uwb.dart';
import 'package:flutter_uwb/src/accessory/_adapter_registry.dart';
import 'package:flutter_uwb/src/accessory/apple_protocol.dart';
import 'package:flutter_uwb/src/accessory/built_in/apple_ni_accessory_adapter.dart';
import 'package:flutter_uwb/src/accessory/built_in/static_pair_accessory_adapter.dart';
import 'package:flutter_uwb/src/pigeon/uwb.g.dart' as pigeon;

String _hostChan(String method) =>
    'dev.flutter.pigeon.flutter_uwb.UwbHostApi.$method';
String _flutterChan(String method) =>
    'dev.flutter.pigeon.flutter_uwb.UwbFlutterApi.$method';

class _RecordingAdapter implements AccessoryAdapter {
  _RecordingAdapter({
    required this.vendorTag,
    Duration? timeout,
    Future<FiraSessionParams> Function(AccessoryConnection)? onHandshake,
  })  : handshakeTimeout = timeout ?? const Duration(seconds: 30),
        _onHandshake = onHandshake;

  @override
  final String vendorTag;

  @override
  final Duration handshakeTimeout;

  final Future<FiraSessionParams> Function(AccessoryConnection)? _onHandshake;
  final Completer<AccessoryConnection> seen = Completer<AccessoryConnection>();

  @override
  Future<FiraSessionParams> handshake(AccessoryConnection conn) {
    if (!seen.isCompleted) seen.complete(conn);
    if (_onHandshake != null) return _onHandshake(conn);
    return _defaultParams();
  }
}

Future<FiraSessionParams> _defaultParams() async => FiraSessionParams(
      sessionId: 0xCAFE,
      channel: 9,
      preambleIndex: 11,
      slotDurationMs: 2,
      slotsPerRangingRound: 6,
      rangingIntervalMs: 240,
      sessionKeyInfo: Uint8List.fromList(
        [0x08, 0x07, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
      ),
      peerShortAddress: Uint8List.fromList([0x00, 0x01]),
      roleIsController: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const hostCodec = pigeon.UwbHostApi.pigeonChannelCodec;
  const flutterCodec = pigeon.UwbFlutterApi.pigeonChannelCodec;

  // Tear down any custom handlers between tests so they don't leak. The
  // `flutter_uwb_test.dart` suite covers the existing methods; we add the
  // five new HostApi channel names here.
  tearDown(() async {
    for (final m in [
      'setRegisteredAdapterTags',
      'beginAccessoryHandshake',
      'accessoryProtocolWrite',
      'completeAccessoryHandshake',
      'failAccessoryHandshake',
    ]) {
      binaryMessenger.setMockMessageHandler(_hostChan(m), null);
    }
    if (!FlutterUwb.instance.isDisposed) {
      await FlutterUwb.instance.dispose();
    }
  });

  void mockOk(String method, [void Function(List<Object?>)? capture]) {
    binaryMessenger.setMockMessageHandler(_hostChan(method),
        (ByteData? message) async {
      if (capture != null) {
        final args = hostCodec.decodeMessage(message)! as List<Object?>;
        capture(args);
      }
      return hostCodec.encodeMessage(<Object?>[pigeon.VoidResult(ok: true)]);
    });
  }

  Future<void> fireDeviceFound(UwbDevice device) async {
    final msg = flutterCodec.encodeMessage(<Object?>[device]);
    await binaryMessenger.handlePlatformMessage(
      _flutterChan('onDeviceFound'),
      msg,
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> fireHandshakeEvent(
    String deviceId,
    AccessoryHandshakeEvent event,
  ) async {
    final msg =
        flutterCodec.encodeMessage(<Object?>[deviceId, event]);
    await binaryMessenger.handlePlatformMessage(
      _flutterChan('onAccessoryHandshakeEvent'),
      msg,
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  group('AdapterRegistry', () {
    test('register pushes the tag set to native', () async {
      final pushes = <List<String?>>[];
      binaryMessenger.setMockMessageHandler(_hostChan('setRegisteredAdapterTags'),
          (ByteData? message) async {
        final args = hostCodec.decodeMessage(message)! as List<Object?>;
        pushes.add((args[0]! as List<Object?>).cast<String?>());
        return hostCodec.encodeMessage(<Object?>[pigeon.VoidResult(ok: true)]);
      });

      final registry = AdapterRegistry(api: pigeon.UwbHostApi());
      registry.register(_RecordingAdapter(vendorTag: 'a'));
      registry.register(_RecordingAdapter(vendorTag: 'b'));
      // Allow the Pigeon fire-and-forget calls to drain.
      await Future<void>.delayed(Duration.zero);
      expect(pushes, hasLength(2));
      expect(pushes[0], equals(<String?>['a']));
      expect(pushes[1], containsAll(<String?>['a', 'b']));

      registry.unregister('a');
      await Future<void>.delayed(Duration.zero);
      expect(pushes, hasLength(3));
      expect(pushes[2], equals(<String?>['b']));
    });

    test('lookup returns the registered adapter', () {
      final registry = AdapterRegistry(api: pigeon.UwbHostApi());
      final adapter = _RecordingAdapter(vendorTag: 'tag');
      registry.registerWithoutPush(adapter);
      expect(registry.lookup('tag'), same(adapter));
      expect(registry.lookup('other'), isNull);
    });

    test('re-registering same vendorTag replaces (custom shadows built-in)',
        () {
      final registry = AdapterRegistry(api: pigeon.UwbHostApi());
      final builtIn = _RecordingAdapter(vendorTag: 'shared');
      final custom = _RecordingAdapter(vendorTag: 'shared');
      registry.registerWithoutPush(builtIn);
      registry.registerWithoutPush(custom);
      expect(registry.lookup('shared'), same(custom));
    });
  });

  group('FlutterUwb adapter wiring', () {
    test('registerAccessoryAdapter pushes vendor tags through Pigeon',
        () async {
      final pushed = <List<String?>>[];
      binaryMessenger.setMockMessageHandler(
          _hostChan('setRegisteredAdapterTags'), (ByteData? message) async {
        final args = hostCodec.decodeMessage(message)! as List<Object?>;
        pushed.add((args[0]! as List<Object?>).cast<String?>());
        return hostCodec.encodeMessage(<Object?>[pigeon.VoidResult(ok: true)]);
      });

      // Trigger an initial push so we know the baseline. Built-in
      // adapters are registered without push at construction; the
      // first user adapter triggers the first push, which contains
      // the built-ins plus the new tag.
      await FlutterUwb.instance
          .registerAccessoryAdapter(_RecordingAdapter(vendorTag: 'demo'));
      await Future<void>.delayed(Duration.zero);
      expect(pushed.last, contains('demo'));
      // Built-ins are also present.
      expect(pushed.last, contains('__apple_ni_default__'));
      expect(pushed.last, contains('qorvo-static'));

      await FlutterUwb.instance.unregisterAccessoryAdapter('demo');
      await Future<void>.delayed(Duration.zero);
      expect(pushed.last, isNot(contains('demo')));
      // Built-ins remain after the user adapter is gone.
      expect(pushed.last, contains('__apple_ni_default__'));
    });

    test('connected event triggers handshake on the matching adapter',
        () async {
      final captured = <Object?>[];
      mockOk('setRegisteredAdapterTags');
      mockOk('completeAccessoryHandshake', captured.addAll);
      // Adapter that simply returns canned params after a single notify.
      final adapter = _RecordingAdapter(
        vendorTag: 'demo',
        onHandshake: (conn) async {
          final reply = await conn.notifyStream.first;
          expect(reply, equals(Uint8List.fromList([0x42])));
          return _defaultParams();
        },
      );
      await FlutterUwb.instance.registerAccessoryAdapter(adapter);
      await fireDeviceFound(UwbDevice(
        id: 'dev-1',
        name: 'demo',
        platform: 'accessory:demo',
      ));
      await fireHandshakeEvent(
        'dev-1',
        AccessoryHandshakeEvent(kind: AccessoryHandshakeEventKind.connected),
      );
      await fireHandshakeEvent(
        'dev-1',
        AccessoryHandshakeEvent(
          kind: AccessoryHandshakeEventKind.notifyBytes,
          bytes: Uint8List.fromList([0x42]),
        ),
      );
      // Wait for the adapter Future to resolve and the Pigeon
      // completeAccessoryHandshake call to land in our handler.
      for (var i = 0; i < 10 && captured.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(captured, isNotEmpty);
      expect(captured.first, equals('dev-1'));
      expect(captured[1], isA<pigeon.FiraSessionParams>());
    });

    test('AccessoryConnection.write round-trips through accessoryProtocolWrite',
        () async {
      final writes = <Uint8List>[];
      mockOk('setRegisteredAdapterTags');
      mockOk('completeAccessoryHandshake');
      mockOk('accessoryProtocolWrite', (args) {
        writes.add(args[1]! as Uint8List);
      });
      final adapter = _RecordingAdapter(
        vendorTag: 'demo2',
        onHandshake: (conn) async {
          await conn.write(Uint8List.fromList([0xAA, 0xBB]));
          return _defaultParams();
        },
      );
      await FlutterUwb.instance.registerAccessoryAdapter(adapter);
      await fireDeviceFound(UwbDevice(
        id: 'dev-2',
        name: 'x',
        platform: 'accessory:demo2',
      ));
      await fireHandshakeEvent(
        'dev-2',
        AccessoryHandshakeEvent(kind: AccessoryHandshakeEventKind.connected),
      );
      for (var i = 0; i < 10 && writes.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(writes, hasLength(1));
      expect(writes.single, equals(Uint8List.fromList([0xAA, 0xBB])));
    });

    test('adapter throwing inside handshake reports failAccessoryHandshake',
        () async {
      String? failMessage;
      mockOk('setRegisteredAdapterTags');
      mockOk('failAccessoryHandshake', (args) {
        failMessage = args[1]! as String;
      });
      final adapter = _RecordingAdapter(
        vendorTag: 'fails',
        onHandshake: (_) async {
          throw StateError('boom');
        },
      );
      await FlutterUwb.instance.registerAccessoryAdapter(adapter);
      await fireDeviceFound(UwbDevice(
        id: 'dev-3',
        name: 'fails',
        platform: 'accessory:fails',
      ));
      await fireHandshakeEvent(
        'dev-3',
        AccessoryHandshakeEvent(kind: AccessoryHandshakeEventKind.connected),
      );
      for (var i = 0; i < 10 && failMessage == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(failMessage, contains('boom'));
    });

    test('disconnected event before handshake completes fails the adapter',
        () async {
      String? failMessage;
      mockOk('setRegisteredAdapterTags');
      mockOk('failAccessoryHandshake', (args) {
        failMessage = args[1]! as String;
      });
      // Adapter awaits notify — it never completes on its own.
      final adapter = _RecordingAdapter(
        vendorTag: 'never',
        onHandshake: (conn) => conn.notifyStream.first.then((_) async {
          fail('should not have received notify');
        }),
      );
      await FlutterUwb.instance.registerAccessoryAdapter(adapter);
      await fireDeviceFound(UwbDevice(
        id: 'dev-4',
        name: 'x',
        platform: 'accessory:never',
      ));
      await fireHandshakeEvent(
        'dev-4',
        AccessoryHandshakeEvent(kind: AccessoryHandshakeEventKind.connected),
      );
      await fireHandshakeEvent(
        'dev-4',
        AccessoryHandshakeEvent(kind: AccessoryHandshakeEventKind.disconnected),
      );
      for (var i = 0; i < 10 && failMessage == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(failMessage, contains('disconnected'));
    });

    test('handshake timeout fires failAccessoryHandshake', () async {
      String? failMessage;
      mockOk('setRegisteredAdapterTags');
      mockOk('failAccessoryHandshake', (args) {
        failMessage = args[1]! as String;
      });
      final adapter = _RecordingAdapter(
        vendorTag: 'slow',
        timeout: const Duration(milliseconds: 30),
        onHandshake: (_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return _defaultParams();
        },
      );
      await FlutterUwb.instance.registerAccessoryAdapter(adapter);
      await fireDeviceFound(UwbDevice(
        id: 'dev-5',
        name: 'slow',
        platform: 'accessory:slow',
      ));
      await fireHandshakeEvent(
        'dev-5',
        AccessoryHandshakeEvent(kind: AccessoryHandshakeEventKind.connected),
      );
      // Wait past the configured timeout.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(failMessage, contains('timed out'));
    });

    test(
        'custom adapter registered with built-in vendorTag overrides the built-in',
        () async {
      mockOk('setRegisteredAdapterTags');
      // Track which adapter saw the connection.
      final builtIn = _RecordingAdapter(vendorTag: 'override-tag');
      final custom = _RecordingAdapter(vendorTag: 'override-tag');
      mockOk('completeAccessoryHandshake');
      // Register the built-in first, then the custom.
      await FlutterUwb.instance.registerAccessoryAdapter(builtIn);
      await FlutterUwb.instance.registerAccessoryAdapter(custom);
      await fireDeviceFound(UwbDevice(
        id: 'dev-6',
        name: 'x',
        platform: 'accessory:override-tag',
      ));
      await fireHandshakeEvent(
        'dev-6',
        AccessoryHandshakeEvent(kind: AccessoryHandshakeEventKind.connected),
      );
      await Future<void>.delayed(Duration.zero);
      expect(custom.seen.isCompleted, isTrue);
      expect(builtIn.seen.isCompleted, isFalse);
    });
  });

  group('AppleNiAccessoryAdapter', () {
    test('handshake writes Initialize then ConfigureAndStart and returns FiraSessionParams',
        () async {
      final inbound = StreamController<Uint8List>.broadcast();
      final writes = <Uint8List>[];
      final conn = AccessoryConnection(
        deviceId: 'apple-1',
        write: (bytes) async {
          writes.add(bytes);
          // Schedule the inbound reply via microtask so the adapter's
          // listener is set up before the bytes arrive on a broadcast
          // stream (broadcast streams drop events when no one is
          // listening).
          if (writes.length == 1) {
            scheduleMicrotask(() {
              final payload = Uint8List(37);
              // payload[33..34] hold the accessory's short address as
              // a little-endian u16; parseAccessoryShortAddress flips
              // them to MSB-first. Bytes 0xD8 (low), 0x91 (high)
              // decode to UwbAddress [0x91, 0xD8].
              payload[33] = 0xD8;
              payload[34] = 0x91;
              inbound.add(Uint8List.fromList([
                AppleAccessoryMessageId.accessoryConfigurationData.value,
                ...payload,
              ]));
            });
          } else if (writes.length == 2) {
            scheduleMicrotask(
              () => inbound.add(const AccessoryUwbDidStart().encode()),
            );
          }
        },
        notifyStream: inbound.stream,
        done: Completer<void>().future,
      );
      // Inject a deterministic Random so the test asserts canonical bytes.
      final adapter = AppleNiAccessoryAdapter(random: Random(42));

      final params = await adapter.handshake(conn);
      // First write was Initialize (1 byte: 0x0A).
      expect(writes.first, equals(Uint8List.fromList([0x0A])));
      // Second write was ConfigureAndStart with 30-byte AppleUWBConfigData
      // payload prepended by 0x0B.
      expect(writes[1].length, equals(31));
      expect(writes[1][0], equals(0x0B));

      // Returned params: roleIsController=true, slotDuration=2 ms,
      // peer short address parsed from the synthetic frame (offsets
      // 33..34 of the payload, MSB-first → 0x91, 0xD8).
      expect(params.roleIsController, isTrue);
      expect(params.slotDurationMs, equals(2));
      expect(params.peerShortAddress, equals(Uint8List.fromList([0x91, 0xD8])));
      // sessionKeyInfo is `vendorId(0x08, 0x07) || stsIv(6B)`.
      expect(params.sessionKeyInfo[0], equals(0x08));
      expect(params.sessionKeyInfo[1], equals(0x07));
      expect(params.sessionKeyInfo.length, equals(8));

      await inbound.close();
    });

    test('handshake throws when AccessoryConfigurationData payload is short',
        () async {
      final inbound = StreamController<Uint8List>.broadcast();
      final conn = AccessoryConnection(
        deviceId: 'apple-2',
        write: (_) async {
          // Schedule via microtask so the listener has time to attach.
          scheduleMicrotask(() {
            inbound.add(Uint8List.fromList([
              AppleAccessoryMessageId.accessoryConfigurationData.value,
              ...List.filled(10, 0),
            ]));
          });
        },
        notifyStream: inbound.stream,
        done: Completer<void>().future,
      );
      final adapter = AppleNiAccessoryAdapter();
      await expectLater(
        adapter.handshake(conn),
        throwsA(isA<StateError>()),
      );
      await inbound.close();
    });

    test('vendorTag is the Apple-NI fallback sentinel', () {
      expect(
        AppleNiAccessoryAdapter().vendorTag,
        equals(appleNiDefaultVendorTag),
      );
    });
  });

  group('StaticPairAccessoryAdapter', () {
    test('handshake returns the canonical Qorvo CLI params', () async {
      final adapter = const StaticPairAccessoryAdapter();
      final inbound = StreamController<Uint8List>.broadcast();
      final conn = AccessoryConnection(
        deviceId: staticPairQorvoDeviceId,
        write: (_) async => fail('static-pair adapter must not write to BLE'),
        notifyStream: inbound.stream,
        done: Completer<void>().future,
      );
      final params = await adapter.handshake(conn);
      expect(params.sessionId, equals(42));
      expect(params.slotDurationMs, equals(2));
      expect(params.slotsPerRangingRound, equals(6));
      expect(params.rangingIntervalMs, equals(240));
      expect(params.peerShortAddress, equals(Uint8List.fromList([0x00, 0x01])));
      expect(params.roleIsController, isTrue);
      // sessionKeyInfo mirrors the Qorvo CLI's
      // -VUPPER=08:07:00:11:22:33:44:55.
      expect(
        params.sessionKeyInfo,
        equals(Uint8List.fromList(
          [0x08, 0x07, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
        )),
      );
      await inbound.close();
    });
  });

  group('Static-pair tile seeding', () {
    test(
        'registerAccessoryProfile with vendorTag=qorvo surfaces a synthetic tile',
        () async {
      mockOk('registerAccessoryProfile');
      final found = <UwbDevice>[];
      final sub = FlutterUwb.instance.deviceFound.listen(found.add);
      await FlutterUwb.instance.registerAccessoryProfile(
        serviceUuid: '2E938FD0-6A61-11ED-A1EB-0242AC120002',
        rxUuid: '2E93998A-6A61-11ED-A1EB-0242AC120002',
        txUuid: '2E939AF2-6A61-11ED-A1EB-0242AC120002',
        vendorTag: 'qorvo',
      );
      // Allow the synchronous deviceFound add to drain.
      await Future<void>.delayed(Duration.zero);
      expect(found, hasLength(1));
      expect(found.first.id, equals(staticPairQorvoDeviceId));
      expect(found.first.platform, equals('accessory:qorvo-static'));
      await sub.cancel();
    });

    test(
        'registerAccessoryProfile with non-qorvo vendorTag does not surface the tile',
        () async {
      mockOk('registerAccessoryProfile');
      final found = <UwbDevice>[];
      final sub = FlutterUwb.instance.deviceFound.listen(found.add);
      await FlutterUwb.instance.registerAccessoryProfile(
        serviceUuid: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        rxUuid: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        txUuid: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        vendorTag: 'someone-else',
      );
      await Future<void>.delayed(Duration.zero);
      expect(found, isEmpty);
      await sub.cancel();
    });
  });
}
