import 'package:flutter/widgets.dart';

/// Emoji-free line faces, level 0 (awful) → 4 (great). Drawn on a 24 × 24 grid.
class MoodFace extends StatelessWidget {
  const MoodFace({super.key, required this.level, required this.color, this.size = 28});

  final int level;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MoodFacePainter(level, color));
}

class _MoodFacePainter extends CustomPainter {
  _MoodFacePainter(this.level, this.color);

  final int level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;

    canvas.drawCircle(const Offset(12, 12), 9, line);

    // Eyes
    if (level == 0) {
      canvas.drawLine(const Offset(8.3, 9.5), const Offset(9.9, 10.5), line);
      canvas.drawLine(const Offset(15.7, 9.5), const Offset(14.1, 10.5), line);
    } else if (level == 4) {
      canvas.drawPath(Path()..moveTo(8.3, 10)..quadraticBezierTo(9.3, 8.8, 10.3, 10), line);
      canvas.drawPath(Path()..moveTo(13.7, 10)..quadraticBezierTo(14.7, 8.8, 15.7, 10), line);
    } else {
      canvas.drawCircle(const Offset(9, 10), 0.9, fill);
      canvas.drawCircle(const Offset(15, 10), 0.9, fill);
    }

    // Mouth
    switch (level) {
      case 0:
        canvas.drawPath(Path()..moveTo(8.5, 16.5)..quadraticBezierTo(12, 13.3, 15.5, 16.5), line);
      case 1:
        canvas.drawPath(Path()..moveTo(9, 16)..quadraticBezierTo(12, 14.6, 15, 16), line);
      case 2:
        canvas.drawLine(const Offset(9, 15.5), const Offset(15, 15.5), line);
      case 3:
        canvas.drawPath(Path()..moveTo(9, 14.5)..quadraticBezierTo(12, 17.1, 15, 14.5), line);
      default:
        canvas.drawPath(Path()..moveTo(8, 13.5)..quadraticBezierTo(12, 19, 16, 13.5)..close(), fill);
    }
  }

  @override
  bool shouldRepaint(_MoodFacePainter old) => old.level != level || old.color != color;
}
