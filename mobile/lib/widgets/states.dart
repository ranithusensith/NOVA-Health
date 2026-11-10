import 'package:flutter/material.dart';

import '../theme/nova_theme.dart';
import 'content.dart';

/// Skeleton card shown while data loads (pulses unless animations are reduced).
class SkeletonCard extends StatefulWidget {
  const SkeletonCard({super.key, this.lines = 3, this.height});

  final int lines;
  final double? height;

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Semantics(
      label: 'Loading',
      child: NovaCard(
        child: SizedBox(
          height: widget.height,
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) {
              final color = Color.lerp(c.fill, c.separator, _c.value)!;
              Widget bar(double f, [double h = 12]) => FractionallySizedBox(
                    widthFactor: f,
                    alignment: Alignment.centerLeft,
                    child: Container(
                      height: h,
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(NovaRadius.capsule)),
                    ),
                  );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(0.45, 16),
                  for (var i = 0; i < widget.lines; i++) ...[
                    const SizedBox(height: 12),
                    bar(i.isEven ? 0.9 : 0.7),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Friendly error with a Retry button.
class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      tone: NovaCardTone.alert,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_off_rounded, color: c.alert),
              const SizedBox(width: 8),
              Expanded(
                child: Text("Couldn't load this", style: NovaType.headline.copyWith(color: c.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(message, style: NovaType.subhead.copyWith(color: c.textSecondary)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            NovaButton(label: 'Try again', kind: NovaButtonKind.secondary, icon: Icons.refresh_rounded, onPressed: onRetry),
          ],
        ],
      ),
    );
  }
}

/// Empty state: icon, title, short body and an optional action.
class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      tone: NovaCardTone.tinted,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        children: [
          IconBadge(icon: icon, size: 64, background: c.surface),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: NovaType.headline.copyWith(fontSize: 19, color: c.textPrimary)),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: NovaType.subhead.copyWith(color: c.textSecondary)),
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            NovaButton(label: actionLabel!, onPressed: onAction),
          ],
          if (secondaryLabel != null) ...[
            const SizedBox(height: 8),
            NovaButton(label: secondaryLabel!, kind: NovaButtonKind.plain, height: 44, onPressed: onSecondary),
          ],
        ],
      ),
    );
  }
}

/// Section label above a group of cards.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(text, style: NovaType.title2.copyWith(fontSize: 20, color: c.textPrimary)),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Filled capsule text field matching the Track screen inputs.
InputDecoration novaFieldDecoration(NovaColors c, String label, {IconData? icon, String? hint}) {
  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: icon == null ? null : Icon(icon, color: c.textSecondary, size: 20),
    filled: true,
    fillColor: c.fill,
    labelStyle: NovaType.subhead.copyWith(color: c.textSecondary),
    hintStyle: NovaType.subhead.copyWith(color: c.textSecondary),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: border(Colors.transparent),
    enabledBorder: border(Colors.transparent),
    focusedBorder: border(c.primary, 2),
  );
}

/// Short, consistent snackbar.
void showNovaToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}

/// Friendly text for an error thrown by Supabase or the API.
String friendlyError(Object e) {
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException')) {
    return 'No internet connection. Check your connection and try again.';
  }
  if (s.contains('Cannot reach the server')) return 'The NOVA server is not reachable right now.';
  return 'Something went wrong. Please try again.';
}
