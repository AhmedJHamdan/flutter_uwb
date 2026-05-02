import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_uwb_example/main.dart';

void main() {
  testWidgets('Example app renders the discovery scaffold', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();

    expect(find.text('flutter_uwb example'), findsOneWidget);
    expect(find.text('Start discovery'), findsOneWidget);
    expect(find.text('UWB hardware'), findsOneWidget);
  });
}
