import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../brand.dart';

/// Find-My-style rotating chevron with a proximity-tinted radial glow.
///
/// The arrow follows the reported direction with a critically damped spring
/// integrated every frame, so motion carries continuous position *and*
/// velocity across incoming samples instead of restarting a tween on each
/// update. Targets are taken along the shortest arc across the ±180° wrap,
/// and a lone azimuth sample that disagrees wildly with the current heading
/// is held for one update before being believed, which suppresses UWB
/// multipath spikes without hiding a genuine fast turn. Rotation is the spin
/// around the screen normal; elevation tilts the chevron forward/back via a
/// 3D perspective `Transform`.
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
  late final Ticker _ticker;
  late final AnimationController _glowCtrl;
  Duration _lastElapsed = Duration.zero;

  double _displayAz = 0.0;
  double _azVelocity = 0.0;
  double _targetAz = 0.0;
  double _displayEl = 0.0;
  double _elVelocity = 0.0;
  double _targetEl = 0.0;

  /// A wild sample being held for confirmation; accepted only if the next
  /// sample lands near it, otherwise discarded as a spike.
  double? _pendingAzRad;

  /// Natural frequency of the critically damped follow spring, in rad/s.
  /// Settles in roughly `4 / _stiffness` seconds — higher is snappier.
  static const double _stiffness = 12.0;

  /// A single sample further than this from the current heading is treated
  /// as a suspected spike (~115°).
  static const double _outlierRad = 2.0;

  /// How close a follow-up sample must land to a held spike to confirm the
  /// move was real (~50°).
  static const double _confirmRad = 0.9;

  static double _degToRad(double deg) => deg * math.pi / 180.0;

  /// Signed shortest-arc difference `a - b`, in (-π, π].
  static double _angleDelta(double a, double b) {
    var d = (a - b) % (2 * math.pi);
    if (d > math.pi) d -= 2 * math.pi;
    if (d <= -math.pi) d += 2 * math.pi;
    return d;
  }

  @override
  void initState() {
    super.initState();
    _displayAz = _targetAz = _degToRad(widget.azimuthDegrees);
    _displayEl = _targetEl = _degToRad(_clampedElevation());
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _ticker = createTicker(_onTick)..start();
  }

  double _clampedElevation() {
    final el = widget.elevationDegrees;
    if (el == null) return 0.0;
    return el.clamp(-60.0, 60.0).toDouble();
  }

  @override
  void didUpdateWidget(covariant PrecisionArrow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _retargetAzimuth(_degToRad(widget.azimuthDegrees));
    _targetEl = _degToRad(_clampedElevation());
  }

  void _retargetAzimuth(double rawRad) {
    final jump = _angleDelta(rawRad, _displayAz);
    if (jump.abs() > _outlierRad) {
      final pending = _pendingAzRad;
      if (pending != null && _angleDelta(rawRad, pending).abs() < _confirmRad) {
        _pendingAzRad = null;
        _targetAz = _displayAz + jump;
      } else {
        _pendingAzRad = rawRad;
      }
      return;
    }
    _pendingAzRad = null;
    _targetAz = _displayAz + jump;
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _lastElapsed).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    setState(() {
      final (az, azVelocity) = _springStep(
        _displayAz,
        _azVelocity,
        _targetAz,
        dt,
      );
      _displayAz = az;
      _azVelocity = azVelocity;
      final (el, elVelocity) = _springStep(
        _displayEl,
        _elVelocity,
        _targetEl,
        dt,
      );
      _displayEl = el;
      _elVelocity = elVelocity;
    });
  }

  /// One semi-implicit Euler step of a critically damped spring toward
  /// [target]. Returns the new (position, velocity).
  static (double, double) _springStep(
    double position,
    double velocity,
    double target,
    double dt,
  ) {
    final acceleration =
        _stiffness * _stiffness * (target - position) -
        2 * _stiffness * velocity;
    final newVelocity = velocity + acceleration * dt;
    return (position + newVelocity * dt, newVelocity);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = proximityColor(widget.distanceMeters);
    final urgency = 1.0 - (widget.distanceMeters / 6.0).clamp(0.0, 1.0);
    final pulse = 0.5 + 0.5 * math.sin(_glowCtrl.value * 2 * math.pi);
    final glow = 0.18 + urgency * 0.45 * pulse;
    final transform = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..rotateX(-_displayEl);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Transform(
        alignment: Alignment.center,
        transform: transform,
        child: CustomPaint(
          painter: _ArrowPainter(
            angle: _displayAz,
            color: color,
            glowStrength: glow,
          ),
        ),
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
