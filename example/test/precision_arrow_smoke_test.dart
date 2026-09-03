import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_uwb_example/widgets/precision_arrow.dart';

double _paintedAngle(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(PrecisionArrow),
      matching: find.byType(CustomPaint),
    ),
  );
  return (paint.painter as dynamic).angle as double;
}

Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Widget _host(double azimuth, {double? elevation, double distance = 2.0}) {
  return MaterialApp(
    home: Scaffold(
      body: PrecisionArrow(
        azimuthDegrees: azimuth,
        distanceMeters: distance,
        elevationDegrees: elevation,
      ),
    ),
  );
}

void main() {
  testWidgets('renders and converges to a new azimuth', (tester) async {
    await tester.pumpWidget(_host(0));
    expect(_paintedAngle(tester), moreOrLessEquals(0, epsilon: 0.01));

    await tester.pumpWidget(_host(90));
    await _pumpFrames(tester, 60);
    expect(_paintedAngle(tester), moreOrLessEquals(math.pi / 2, epsilon: 0.03));
    expect(tester.takeException(), isNull);
  });

  testWidgets('takes the shortest arc across the ±180° wrap', (tester) async {
    await tester.pumpWidget(_host(170));
    await tester.pumpWidget(_host(-170));
    await _pumpFrames(tester, 60);
    final angle = _paintedAngle(tester);
    expect(
      math.sin(angle),
      moreOrLessEquals(math.sin(_rad(-170)), epsilon: 0.05),
    );
    expect(
      math.cos(angle),
      moreOrLessEquals(math.cos(_rad(-170)), epsilon: 0.05),
    );
    expect(angle, greaterThan(_rad(170)));
  });

  testWidgets('holds a lone spike but accepts a confirmed fast turn', (
    tester,
  ) async {
    await tester.pumpWidget(_host(0));
    await _pumpFrames(tester, 30);

    await tester.pumpWidget(_host(150));
    await _pumpFrames(tester, 30);
    expect(
      _paintedAngle(tester),
      moreOrLessEquals(0, epsilon: 0.05),
      reason: 'a single outlier sample must not move the arrow',
    );

    await tester.pumpWidget(_host(148));
    await _pumpFrames(tester, 90);
    expect(
      _paintedAngle(tester),
      moreOrLessEquals(_rad(148), epsilon: 0.05),
      reason: 'a confirming second sample must be believed',
    );
  });

  testWidgets('null elevation renders and widget disposes cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(_host(45, elevation: null));
    await _pumpFrames(tester, 10);
    await tester.pumpWidget(_host(45, elevation: 30));
    await _pumpFrames(tester, 10);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

double _rad(double deg) => deg * math.pi / 180.0;
