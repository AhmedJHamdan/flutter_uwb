import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../brand.dart';

/// Find-My-style rotating chevron with a proximity-tinted radial glow.
///
/// Both `azimuthDegrees` and `elevationDegrees` are tweened (350 ms,
/// `easeOutCubic`) so the arrow glides instead of snapping. The shortest-arc
/// path is taken across the ±180° wrap. Rotation is the spin around the
/// screen normal; elevation tilts the chevron forward/back via a 3D
/// perspective `Transform`.
class PrecisionArrow extends StatefulWidget {
  const PrecisionArrow({
    super.key,
    required this.azimuthDegrees,
    required this.distanceMeters,
    this.elevationDegrees,
    this.size = 220,
  });

  final double azimuthDegrees;
  final double distanceMeters;

  /// `null` when the device can't resolve elevation (iPhone 11–13 without
  /// camera assist, or before the U2 link converges).
  final double? elevationDegrees;
  final double size;

  @override
  State<PrecisionArrow> createState() => _PrecisionArrowState();
}

class _PrecisionArrowState extends State<PrecisionArrow>
    with TickerProviderStateMixin {
  late final AnimationController _rotationCtrl;
  late final AnimationController _tiltCtrl;
  late final AnimationController _glowCtrl;
  late Animation<double> _rotation;
  late Animation<double> _tilt;

  double _previousAzRad = 0.0;
  double _previousElRad = 0.0;

  // Smoothed (low-pass-filtered) targets the tween chases. Azimuth is filtered
  // as a unit vector to handle the ±π wrap; elevation as a scalar.
  double _smoothedAzCos = 1.0;
  double _smoothedAzSin = 0.0;
  double _smoothedElRad = 0.0;
  bool _smoothInit = false;

  /// EMA factor — higher = more responsive, lower = smoother. 0.18 gives a
  /// noticeable glide without feeling laggy at the typical 10 Hz NI rate.
  static const double _smoothing = 0.18;

  static const _tweenDuration = Duration(milliseconds: 450);
  static const _curve = Curves.easeOutCubic;

  static double _degToRad(double deg) => deg * math.pi / 180.0;

  @override
  void initState() {
    super.initState();
    final initAz = _degToRad(widget.azimuthDegrees);
    _previousAzRad = initAz;
    _previousElRad = _degToRad(_clampedElevation());
    _smoothedAzCos = math.cos(initAz);
    _smoothedAzSin = math.sin(initAz);
    _smoothedElRad = _previousElRad;
    _smoothInit = true;
    _rotationCtrl = AnimationController(vsync: this, duration: _tweenDuration);
    _tiltCtrl = AnimationController(vsync: this, duration: _tweenDuration);
    _rotation = AlwaysStoppedAnimation<double>(_previousAzRad);
    _tilt = AlwaysStoppedAnimation<double>(_previousElRad);
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  double _clampedElevation() {
    final el = widget.elevationDegrees;
    if (el == null) return 0.0;
    return el.clamp(-60.0, 60.0).toDouble();
  }

  @override
  void didUpdateWidget(covariant PrecisionArrow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final rawAz = _degToRad(widget.azimuthDegrees);
    final rawEl = _degToRad(_clampedElevation());

    if (!_smoothInit) {
      _smoothedAzCos = math.cos(rawAz);
      _smoothedAzSin = math.sin(rawAz);
      _smoothedElRad = rawEl;
      _smoothInit = true;
    } else {
      _smoothedAzCos =
          _smoothedAzCos + _smoothing * (math.cos(rawAz) - _smoothedAzCos);
      _smoothedAzSin =
          _smoothedAzSin + _smoothing * (math.sin(rawAz) - _smoothedAzSin);
      _smoothedElRad = _smoothedElRad + _smoothing * (rawEl - _smoothedElRad);
    }

    if (widget.azimuthDegrees != oldWidget.azimuthDegrees) {
      final target = math.atan2(_smoothedAzSin, _smoothedAzCos);
      var delta = target - _previousAzRad;
      while (delta > math.pi) {
        delta -= 2 * math.pi;
      }
      while (delta < -math.pi) {
        delta += 2 * math.pi;
      }
      final end = _previousAzRad + delta;
      _rotation = Tween<double>(
        begin: _previousAzRad,
        end: end,
      ).animate(CurvedAnimation(parent: _rotationCtrl, curve: _curve));
      _previousAzRad = end;
      _rotationCtrl
        ..value = 0
        ..forward();
    }
    if (widget.elevationDegrees != oldWidget.elevationDegrees) {
      _tilt = Tween<double>(
        begin: _previousElRad,
        end: _smoothedElRad,
      ).animate(CurvedAnimation(parent: _tiltCtrl, curve: _curve));
      _previousElRad = _smoothedElRad;
      _tiltCtrl
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _rotationCtrl.dispose();
    _tiltCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = proximityColor(widget.distanceMeters);
    final urgency = 1.0 - (widget.distanceMeters / 6.0).clamp(0.0, 1.0);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_rotationCtrl, _tiltCtrl, _glowCtrl]),
        builder: (context, _) {
          final pulse = 0.5 + 0.5 * math.sin(_glowCtrl.value * 2 * math.pi);
          final glow = 0.18 + urgency * 0.45 * pulse;
          final transform = Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateX(-_tilt.value);
          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: CustomPaint(
              painter: _ArrowPainter(
                angle: _rotation.value,
                color: color,
                glowStrength: glow,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({
    required this.angle,
    required this.color,
    required this.glowStrength,
  });

  final double angle;
  final Color color;
  final double glowStrength;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;

    // Soft outer glow.
    final outerGlow = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: glowStrength.clamp(0.0, 1.0)),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, outerGlow);

    // Faint base ring as a positional anchor.
    final ring = Paint()
      ..color = Brand.muted.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(center, radius * 0.92, ring);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    // Rounded chevron — softer than the original sharp triangle.
    final h = radius * 0.74;
    final w = radius * 0.46;
    final notch = h * 0.38;
    final path = Path()
      ..moveTo(0, -h)
      ..quadraticBezierTo(w * 0.55, -h * 0.55, w, h * 0.42)
      ..quadraticBezierTo(w * 0.55, h * 0.18, 0, notch)
      ..quadraticBezierTo(-w * 0.55, h * 0.18, -w, h * 0.42)
      ..quadraticBezierTo(-w * 0.55, -h * 0.55, 0, -h)
      ..close();

    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color, Color.lerp(color, Brand.background, 0.35)!],
      ).createShader(Rect.fromLTRB(-w, -h, w, h))
      ..isAntiAlias = true;
    canvas.drawPath(path, fill);

    final stroke = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawPath(path, stroke);

    // Subtle highlight along the leading edge.
    final highlight = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final highlightPath = Path()
      ..moveTo(0, -h * 0.88)
      ..quadraticBezierTo(w * 0.35, -h * 0.45, w * 0.6, h * 0.05);
    canvas.drawPath(highlightPath, highlight);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) =>
      old.angle != angle ||
      old.color != color ||
      old.glowStrength != glowStrength;
}
