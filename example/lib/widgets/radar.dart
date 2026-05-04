import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../brand.dart';

/// Concentric-ring radar mirroring `assets/brand/flutter_uwb_pulse.svg`.
///
/// The painter scales the SVG's 320×320 logical canvas (rings at r=120, 84,
/// 48 and a core dot at r=10) to whatever box it's given. The tracked-point
/// dot is drawn at [trackedAngleRadians] / [trackedNormalizedDistance]
/// (0..1) so the parent can drive it from a live `RangingSample`.
class Radar extends StatelessWidget {
  const Radar({
    super.key,
    this.trackedNormalizedDistance,
    this.trackedAngleRadians,
  });

  /// 0..1 along the radar's outer ring (1 = ring r=120 in the SVG canvas).
  final double? trackedNormalizedDistance;

  /// Polar angle in radians (0 = right, increasing counter-clockwise).
  final double? trackedAngleRadians;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _RadarPainter(
          trackedNormalizedDistance: trackedNormalizedDistance,
          trackedAngleRadians: trackedAngleRadians,
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({this.trackedNormalizedDistance, this.trackedAngleRadians});

  final double? trackedNormalizedDistance;
  final double? trackedAngleRadians;

  static const double _canvas = 320; // matches the SVG viewBox
  static const double _ringOuter = 120;
  static const double _ringMid = 84;
  static const double _ringInner = 48;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _canvas;
    final center = size.center(Offset.zero);

    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          Brand.primary.withValues(alpha: 0.35),
          Brand.primary.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.6],
      ).createShader(Rect.fromCircle(center: center, radius: 80 * scale));
    canvas.drawCircle(center, 80 * scale, glow);

    final secondaryStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * scale
      ..color = Brand.secondary;
    canvas.drawCircle(center, _ringOuter * scale, secondaryStroke);
    canvas.drawCircle(
      center,
      _ringMid * scale,
      secondaryStroke..color = Brand.secondary.withValues(alpha: 0.85),
    );

    final primaryStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * scale
      ..color = Brand.primary;
    canvas.drawCircle(center, _ringInner * scale, primaryStroke);

    canvas.drawCircle(center, 10 * scale, Paint()..color = Brand.primary);
    canvas.drawCircle(center, 4 * scale, Paint()..color = Brand.background);

    if (trackedNormalizedDistance != null) {
      final r =
          (trackedNormalizedDistance!.clamp(0.0, 1.0)) * _ringOuter * scale;
      final a = trackedAngleRadians ?? -math.pi / 2;
      final dot = center + Offset(r * math.cos(a), -r * math.sin(a));
      canvas.drawCircle(dot, 6 * scale, Paint()..color = Brand.primary);
      canvas.drawCircle(
        dot,
        12 * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * scale
          ..color = Brand.primary.withValues(alpha: 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.trackedNormalizedDistance != trackedNormalizedDistance ||
      old.trackedAngleRadians != trackedAngleRadians;
}
