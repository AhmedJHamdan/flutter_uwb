import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_uwb_example/main.dart';

void main() {
  testWidgets('Example app renders the home scaffold', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();

    expect(find.text('flutter_uwb'), findsOneWidget);
    expect(find.text('UWB · RANGING'), findsOneWidget);
  });
}
