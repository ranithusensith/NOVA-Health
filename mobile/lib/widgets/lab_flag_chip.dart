import 'package:flutter/material.dart';

import '../theme/nova_theme.dart';

/// "Low" / "High" / "In range" tag. Shown as text too, never by colour alone.
class LabFlagChip extends StatelessWidget {
  const LabFlagChip({super.key, required this.flag});

  final String flag;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final (label, color) = switch (flag) {
      'high' => ('High', c.alert),
      'low' => ('Low', c.warningContent),
      'normal' => ('In range', c.success),
      _ => ('Not checked', c.textSecondary),
    };
    return Semantics(
      label: 'Result flag: $label',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(NovaRadius.capsule),
          ),
          child: Text(
            label,
            style: NovaType.caption.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}
