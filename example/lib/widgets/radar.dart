import 'package:flutter/material.dart';

import '../brand.dart';

/// Animated radar shown while UWB is ranging without direction (AoA).
///
/// Three staggered pulse rings expand from the centre and fade as they reach
/// the edge, layered over a faint static guide ring. There's no tracked-dot —
/// without azimuth, the only honest signal is "we're locked on", which is
/// what the pulse conveys.
class Radar extends StatefulWidget {
  const Radar({super.key, this.active = true});

  /// When `false`, the radar renders a static guide ring + centre dot with
  /// no pulse animation (used while idle / not ranging).
  final bool active;

  @override
  State<Radar> createState() => _RadarState();
}

class _RadarState extends State<Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    if (widget.active) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant Radar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _RadarPainter(progress: _ctrl.value, active: widget.active),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progress, required this.active});

  /// 0..1 — global animation phase. Each pulse ring offsets from this.
  final double progress;
  final bool active;

  static const _pulseCount = 3;

  static const double _canvas = 320;
  static const double _ringOuter = 120;
  static const double _ringMid = 84;
  static const double _ringInner = 48;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;

    if (active) {
      for (var i = 0; i < _pulseCount; i++) {
        final phase = (progress + i / _pulseCount) % 1.0;
        final radius = maxRadius * phase;
        final opacity = (1.0 - phase).clamp(0.0, 1.0);
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = Brand.primary.withValues(alpha: 0.55 * opacity);
        canvas.drawCircle(center, radius, ring);
      }

      final corePulse = 0.5 + 0.5 * (progress * 2 % 1.0);
      final coreGlow = Paint()
        ..shader =
            RadialGradient(
              colors: [
                Brand.primary.withValues(alpha: 0.35 * corePulse),
                Brand.primary.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 1.0],
            ).createShader(
              Rect.fromCircle(center: center, radius: maxRadius * 0.32),
            );
      canvas.drawCircle(center, maxRadius * 0.32, coreGlow);
      canvas.drawCircle(center, 6, Paint()..color = Brand.primary);
      return;
    }

    // Inactive: draw the brand logo (concentric SVG rings + core dot).
    final scale = size.shortestSide / _canvas;

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
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.progress != progress || old.active != active;
}
