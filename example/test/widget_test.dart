import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_uwb_example/main.dart';

void main() {
  testWidgets('Example app renders the home scaffold', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();

    // Eyebrow text on the Ranging tab. The full string includes the
    // current signal status (`IDLE`/`SCAN`/`LIVE`) — matching just the
    // prefix avoids depending on the runtime state.
    expect(
      find.textContaining('UWB · RANGING'),
      findsOneWidget,
    );
    // Bottom navigation bar exposes both tabs.
    expect(find.text('Ranging'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
