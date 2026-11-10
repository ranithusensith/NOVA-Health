import 'package:flutter/material.dart';

import '../theme/nova_theme.dart';
import 'pressable.dart';

enum NovaCardTone { normal, tinted, alert }

/// CONTENT LAYER card — flat and solid, 26 pt radius. Never glass.
class NovaCard extends StatelessWidget {
  const NovaCard({super.key, required this.child, this.tone = NovaCardTone.normal, this.padding = const EdgeInsets.all(NovaSpace.cardPadding)});

  final Widget child;
  final NovaCardTone tone;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final color = switch (tone) {
      NovaCardTone.normal => c.surface,
      NovaCardTone.tinted => c.primaryTint,
      NovaCardTone.alert => c.alertSurface,
    };
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(NovaRadius.card),
        boxShadow: context.isDark ? null : [BoxShadow(color: c.cardShadow, blurRadius: 2, offset: const Offset(0, 1))],
      ),
      child: child,
    );
  }
}

/// Round icon well used at the start of rows.
class IconBadge extends StatelessWidget {
  const IconBadge({super.key, required this.icon, this.size = 44, this.background, this.foreground});

  final IconData icon;
  final double size;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background ?? c.primaryTint, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.5, color: foreground ?? c.primary),
    );
  }
}

/// "Based on" source chip with a colour dot (colour never carries meaning alone).
class SourceChip extends StatelessWidget {
  const SourceChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(NovaRadius.capsule)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: NovaType.footnote.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary)),
        ],
      ),
    );
  }
}

/// Suggestion chip (content layer, solid).
class SuggestionChip extends StatelessWidget {
  const SuggestionChip({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(NovaRadius.capsule)),
        child: Text(label, style: NovaType.subhead.copyWith(fontWeight: FontWeight.w500, color: c.primary)),
      ),
    );
  }
}

/// Small status label: icon carries the status colour, text stays readable.
class StatusLabel extends StatelessWidget {
  const StatusLabel({super.key, required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: NovaType.caption.copyWith(color: context.nova.textSecondary)),
      ],
    );
  }
}

enum NovaButtonKind { primary, secondary, destructive, plain }

/// Capsule buttons. One primary per screen.
class NovaButton extends StatelessWidget {
  const NovaButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = NovaButtonKind.primary,
    this.icon,
    this.expand = true,
    this.height = 50,
  });

  final String label;
  final VoidCallback? onPressed;
  final NovaButtonKind kind;
  final IconData? icon;
  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final (Color bg, Color fg) = switch (kind) {
      NovaButtonKind.primary => (c.primary, c.onPrimary),
      NovaButtonKind.secondary => (c.primaryTint, c.primary),
      NovaButtonKind.destructive => (c.alertSurface, context.isDark ? c.alert : const Color(0xFFB5271B)),
      NovaButtonKind.plain => (Colors.transparent, c.primary),
    };
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        disabledBackgroundColor: kind == NovaButtonKind.plain ? Colors.transparent : bg.withValues(alpha: 0.4),
        disabledForegroundColor: fg.withValues(alpha: 0.6),
        minimumSize: Size(expand ? double.infinity : 0, height),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: const StadiumBorder(),
        elevation: 0,
        textStyle: NovaType.headline,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// "Guidance, not medical advice" — required on every AI surface.
class DisclaimerNote extends StatelessWidget {
  const DisclaimerNote({super.key, this.icon = false});

  final bool icon;

  @override
  Widget build(BuildContext context) {
    final style = NovaType.caption.copyWith(color: context.nova.textSecondary);
    if (!icon) return Text('Guidance, not medical advice', style: style, textAlign: TextAlign.right);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.info_outline_rounded, size: 14, color: context.nova.textSecondary),
        const SizedBox(width: 6),
        Text('Guidance, not medical advice', style: NovaType.footnote.copyWith(color: context.nova.textSecondary)),
      ],
    );
  }
}
