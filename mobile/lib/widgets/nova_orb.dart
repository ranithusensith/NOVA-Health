import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/nova_theme.dart';

/// Decorative 3D "health orb": three activity rings (water, sleep, NOVA teal)
/// spinning on different axes around a glowing core. Drag it to tilt it.
/// Respects the system "reduce motion" setting (stays still, no dragging).
class NovaOrb extends StatefulWidget {
  const NovaOrb({super.key, this.size = 220});

  final double size;

  @override
  State<NovaOrb> createState() => _NovaOrbState();
}

class _NovaOrbState extends State<NovaOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 16));

  Offset _tilt = Offset.zero;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) {
      _ctrl.stop();
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onPan(DragUpdateDetails d) {
    setState(() {
      _tilt = Offset(
        (_tilt.dx + d.delta.dx * 0.012).clamp(-0.8, 0.8).toDouble(),
        (_tilt.dy - d.delta.dy * 0.012).clamp(-0.8, 0.8).toDouble(),
      );
    });
  }

  void _resetTilt() => setState(() => _tilt = Offset.zero);

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final s = widget.size;

    return ExcludeSemantics(
      child: GestureDetector(
        onPanUpdate: _reduceMotion ? null : _onPan,
        onPanEnd: (_) => _resetTilt(),
        onPanCancel: _resetTilt,
        child: TweenAnimationBuilder<Offset>(
          tween: Tween<Offset>(begin: Offset.zero, end: _tilt),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          builder: (context, tilt, _) {
            return AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                final a = 2 * math.pi * _ctrl.value;
                final breathe = 1 + 0.035 * math.sin(a * 2);

                Matrix4 spin(double rx, double ry, double rz) => Matrix4.identity()
                  ..setEntry(3, 2, 0.0011) // perspective
                  ..rotateX(rx + tilt.dy)
                  ..rotateY(ry + tilt.dx)
                  ..rotateZ(rz);

                return SizedBox.square(
                  dimension: s,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      _ring(s, spin(1.1, a, 0.15), c.water, 0.8, s * 0.045),
                      _ring(s * 0.84, spin(a, 0.8, -0.3), c.sleep, 0.66, s * 0.04),
                      Transform.translate(
                        offset: Offset(tilt.dx, -tilt.dy) * 16,
                        child: Transform.scale(
                          scale: breathe,
                          child: _core(c, s * 0.42),
                        ),
                      ),
                      _ring(s * 0.68, spin(-0.7, -a, 0.4), c.primary, 0.9, s * 0.035),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _ring(double diameter, Matrix4 m, Color color, double sweep, double stroke) {
    return Transform(
      alignment: Alignment.center,
      transform: m,
      child: CustomPaint(
        size: Size.square(diameter),
        painter: _RingPainter(color: color, sweep: sweep, stroke: stroke),
      ),
    );
  }

  Widget _core(NovaColors c, double d) {
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 0.95,
          colors: [
            Color.lerp(c.primary, Colors.white, 0.55)!,
            c.primary,
            Color.lerp(c.primary, Colors.black, 0.45)!,
          ],
          stops: const [0, 0.55, 1],
        ),
        boxShadow: [
          BoxShadow(color: c.primary.withValues(alpha: 0.45), blurRadius: 40, spreadRadius: 2),
        ],
      ),
      child: Icon(
        Icons.favorite_rounded,
        color: Colors.white.withValues(alpha: 0.92),
        size: d * 0.38,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.sweep, required this.stroke});

  final Color color;
  final double sweep; // 0..1 of a full circle
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.14);
    canvas.drawOval(rect, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi * sweep,
        colors: [color.withValues(alpha: 0.25), color],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * sweep, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.sweep != sweep || old.stroke != stroke;
}
