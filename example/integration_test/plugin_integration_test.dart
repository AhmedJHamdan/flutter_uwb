import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_uwb/flutter_uwb.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('isUwbAvailable returns a bool on the host platform', (_) async {
    final available = await FlutterUwb.instance.isUwbAvailable();
    expect(available, isA<bool>());
  });

  testWidgets('startDiscovery + stopDiscovery round-trip succeeds', (_) async {
    await FlutterUwb.instance.startDiscovery('integration-test');
    await FlutterUwb.instance.stopDiscovery();
  });

  testWidgets('getLocalToken returns non-empty bytes when UWB is available', (
    _,
  ) async {
    if (!await FlutterUwb.instance.isUwbAvailable()) {
      // Emulator/simulator: getLocalToken will fail or return empty.
      // Treat as a soft skip.
      return;
    }
    final token = await FlutterUwb.instance.getLocalToken(UwbRole.controller);
    expect(token.isNotEmpty, isTrue);
  });
}
