import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_uwb_example/main.dart';

void main() {
  testWidgets('Example app renders the tabbed home scaffold', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Ranging'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.textContaining('UWB · RANGING'), findsOneWidget);
  });

  testWidgets('Settings tab opens from the navigation bar', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();

    await tester.tap(find.text('Settings'));
    await tester.pump();

    expect(find.textContaining('UWB · RANGING'), findsNothing);
  });
}
