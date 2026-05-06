import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_uwb/flutter_uwb.dart';

void main() {
  // Each test resets the logger to its defaults so order doesn't matter.
  setUp(() {
    UwbLog.setLevel(UwbLogLevel.off);
    UwbLog.setHandler(null);
  });

  group('UwbLog', () {
    test('default level is off — nothing reaches the handler', () {
      final lines = <String>[];
      UwbLog.setHandler((_, msg) => lines.add(msg));
      UwbLog.error('boom');
      UwbLog.debug('chatter');
      expect(lines, isEmpty);
    });

    test('setLevel(debug) lets all severities through', () {
      final lines = <(UwbLogLevel, String)>[];
      UwbLog.setHandler((l, msg) => lines.add((l, msg)));
      UwbLog.setLevel(UwbLogLevel.debug);
      UwbLog.debug('d');
      UwbLog.info('i');
      UwbLog.warn('w');
      UwbLog.error('e');
      expect(lines, hasLength(4));
      expect(lines.map((p) => p.$1).toList(), [
        UwbLogLevel.debug,
        UwbLogLevel.info,
        UwbLogLevel.warn,
        UwbLogLevel.error,
      ]);
    });

    test('setLevel(warn) drops debug and info but keeps warn and error', () {
      final lines = <UwbLogLevel>[];
      UwbLog.setHandler((l, _) => lines.add(l));
      UwbLog.setLevel(UwbLogLevel.warn);
      UwbLog.debug('d');
      UwbLog.info('i');
      UwbLog.warn('w');
      UwbLog.error('e');
      expect(lines, [UwbLogLevel.warn, UwbLogLevel.error]);
    });

    test('setLevel(off) silences everything including error', () {
      final lines = <String>[];
      UwbLog.setHandler((_, msg) => lines.add(msg));
      UwbLog.setLevel(UwbLogLevel.off);
      UwbLog.error('boom');
      expect(lines, isEmpty);
    });

    test('setHandler(null) restores default routing (no exception)', () {
      UwbLog.setLevel(UwbLogLevel.debug);
      UwbLog.setHandler((_, __) {});
      UwbLog.setHandler(null);
      // Default routing goes to dart:developer log; we just verify the
      // call site doesn't throw.
      expect(() => UwbLog.info('via developer.log'), returnsNormally);
    });

    test('handler receives the same message that was emitted', () {
      String? captured;
      UwbLog.setHandler((_, msg) => captured = msg);
      UwbLog.setLevel(UwbLogLevel.info);
      UwbLog.info('hello');
      expect(captured, 'hello');
    });
  });
}
