import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class RingValue {
  const RingValue(this.progress, this.color);
  final double progress;
  final Color color;
}

/// Concentric activity rings, outer → inner. Animates in on first build.
class ActivityRings extends StatelessWidget {
  const ActivityRings({
    super.key,
    required this.rings,
    required this.semanticLabel,
    this.size = 150,
    this.stroke = 13,
    this.gap = 3,
  });

  final List<RingValue> rings;
  final String semanticLabel;
  final double size;
  final double stroke;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: semanticLabel,
      image: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: animate ? 0 : 1, end: 1),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (_, t, __) => CustomPaint(
          size: Size.square(size),
          painter: _RingsPainter(rings, stroke, gap, t),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.rings, this.stroke, this.gap, this.t);

  final List<RingValue> rings;
  final double stroke;
  final double gap;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < rings.length; i++) {
      final ring = rings[i];
      final r = size.width / 2 - stroke / 2 - i * (stroke + gap);
      final track = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = ring.color.withValues(alpha: 0.18);
      canvas.drawCircle(center, r, track);

      final sweep = 2 * math.pi * ring.progress.clamp(0.0, 1.0) * t;
      if (sweep <= 0) continue;
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = ring.color;
      canvas.drawArc(Rect.fromCircle(center: center, radius: r), -math.pi / 2, sweep, false, arc);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.t != t || old.rings != rings;
}
