import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/nova_settings.dart';
import '../theme/nova_theme.dart';
import 'pressable.dart';

/// Liquid Glass surface — CONTROL LAYER ONLY (tab bar, nav buttons, toolbars,
/// sheets, chat input, camera controls, floating actions). Never use it for
/// content cards, charts, list rows or body text.
///
/// Translucent fill + background blur + soft specular highlight on the top edge.
/// With Reduce Transparency it becomes a solid surface with the same layout.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = NovaRadius.capsule,
    this.tinted = false,
    this.padding,
    this.width,
    this.height,
    this.fillOpacity,
    this.blur = 24,
  });

  final Widget child;
  final double radius;

  /// Primary-tinted glass — use for the single most important action on a screen.
  final bool tinted;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  /// Override the neutral glass opacity (e.g. 0.34 "clear", 0.86 "tinted" variants).
  final double? fillOpacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final solid = NovaSettings.reduceTransparencyOf(context);
    final br = BorderRadius.circular(radius);

    final Color fill;
    if (tinted) {
      fill = solid ? c.primary : c.primary.withValues(alpha: 0.82);
    } else if (solid) {
      fill = c.surface;
    } else {
      fill = fillOpacity == null ? c.glassFill : c.glassFill.withValues(alpha: fillOpacity!);
    }
    final fg = tinted ? c.onPrimary : c.textPrimary;

    final body = Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: br,
              border: Border.all(
                color: tinted ? Colors.white.withValues(alpha: 0.25) : (solid ? c.separator : c.glassEdge),
                width: 0.5,
              ),
            ),
          ),
        ),
        if (!solid)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: br,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      (tinted ? Colors.white : c.glassHighlight).withValues(alpha: tinted ? 0.28 : c.glassHighlight.a * 0.5),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.45],
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: padding ?? EdgeInsets.zero,
          child: IconTheme.merge(
            data: IconThemeData(color: fg),
            child: DefaultTextStyle.merge(style: TextStyle(color: fg), child: child),
          ),
        ),
      ],
    );

    final surface = solid
        ? body
        : ClipRRect(
            borderRadius: br,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: blur / 2, sigmaY: blur / 2),
              child: body,
            ),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDark ? 0.4 : 0.07),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: SizedBox(width: width, height: height, child: surface),
    );
  }
}

/// Circular glass icon button (44 pt by default).
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.size = 44,
    this.iconSize = 20,
    this.tinted = false,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool tinted;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Glass(
        width: size,
        height: size,
        tinted: tinted,
        child: Icon(icon, size: iconSize, color: iconColor),
      ),
    );
  }
}

/// Floating glass back capsule — no solid navigation bars in NOVA.
class GlassBackButton extends StatelessWidget {
  const GlassBackButton({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Pressable(
      onTap: onTap ?? () => Navigator.of(context).maybePop(),
      semanticLabel: 'Back to $label',
      child: Glass(
        height: 44,
        padding: const EdgeInsets.fromLTRB(10, 0, 16, 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.chevron_left, size: 22, color: c.primary),
            const SizedBox(width: 2),
            Text(label, style: NovaType.body.copyWith(fontWeight: FontWeight.w500, color: c.primary)),
          ],
        ),
      ),
    );
  }
}
