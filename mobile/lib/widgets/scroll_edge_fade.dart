import 'package:flutter/widgets.dart';

import '../theme/nova_theme.dart';

/// Content scrolls edge to edge under the glass controls; a soft fade at the
/// top and bottom replaces solid bar backgrounds.
class ScrollEdgeFade extends StatelessWidget {
  const ScrollEdgeFade({super.key, required this.child, this.bottomHeight = 130, this.color});

  final Widget child;
  final double bottomHeight;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? context.nova.background;
    final top = MediaQuery.paddingOf(context).top + 12;
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: top,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bg, bg.withValues(alpha: 0)],
                  stops: const [0.55, 1],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: bottomHeight,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [bg, bg.withValues(alpha: 0)],
                  stops: const [0.25, 1],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
