import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_uwb/src/oob_capability.dart';

void main() {
  group('OobCapability', () {
    test('reserves stable wire values across the three peer kinds', () {
      expect(OobCapability.iosPeer, 0x01);
      expect(OobCapability.androidPeer, 0x02);
      expect(OobCapability.accessoryHost, 0x03);
    });

    test('falls back to Android peer when the byte is missing', () {
      expect(OobCapability.unknownDefault, OobCapability.androidPeer);
    });
  });
}
