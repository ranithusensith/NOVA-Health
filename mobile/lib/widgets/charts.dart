import 'package:flutter/widgets.dart';

import '../theme/nova_theme.dart';

/// 7-bar chart with a dashed goal line. Always pair with a text summary line.
class SleepBarChart extends StatelessWidget {
  const SleepBarChart({
    super.key,
    required this.values,
    required this.labels,
    required this.goal,
    required this.color,
    this.height = 64,
    this.semanticTitle = 'Sleep per night',
    this.unit = 'hours',
  });

  final List<double> values;
  final List<String> labels;
  final double goal;
  final Color color;
  final double height;

  /// Read by screen readers, e.g. "Water per day".
  final String semanticTitle;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final desc = [for (var i = 0; i < values.length; i++) '${labels[i]} ${values[i]} $unit'].join(', ');
    return Semantics(
      label: '$semanticTitle: $desc. Goal $goal $unit.',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(painter: _BarsPainter(values, goal, color)),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final l in labels)
                  SizedBox(
                    width: 26,
                    child: Text(l, textAlign: TextAlign.center, style: NovaType.caption.copyWith(color: c.textSecondary)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, this.goal, this.color);

  final List<double> values;
  final double goal;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 22.0;
    const inset = 6.0;
    final n = values.length;
    final peak = values.fold<double>(goal, (m, v) => v > m ? v : m);
    final maxV = (peak <= 0 ? 1 : peak) * 1.08;
    final spacing = n > 1 ? (size.width - inset * 2 - n * barW) / (n - 1) : 0.0;

    for (var i = 0; i < n; i++) {
      final h = (values[i] / maxV) * size.height;
      final x = inset + i * (barW + spacing);
      final rect = RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - h, barW, h), const Radius.circular(6));
      canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: i == n - 1 ? 1 : 0.55));
    }

    final y = size.height - (goal / maxV) * size.height;
    final dash = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1.5;
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, y), Offset(x + 3.5, y), dash);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.values != values || old.color != color;
}
