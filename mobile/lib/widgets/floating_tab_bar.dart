import 'package:flutter/cupertino.dart';

import '../theme/nova_theme.dart';
import 'glass.dart';
import 'pressable.dart';

const double kNovaTabBarHeight = 64;

/// Distance from the screen bottom to the floating tab bar.
double novaTabBarBottom(BuildContext context) {
  final b = MediaQuery.paddingOf(context).bottom;
  return b > 0 ? b + 8 : 16;
}

class NovaTab {
  const NovaTab(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Floating capsule Liquid Glass tab bar. Minimises to the current tab on
/// scroll down and expands on scroll up (driven by the shell).
class FloatingTabBar extends StatelessWidget {
  const FloatingTabBar({
    super.key,
    required this.tabs,
    required this.index,
    required this.onSelect,
    this.minimised = false,
    this.onExpand,
  });

  final List<NovaTab> tabs;
  final int index;
  final ValueChanged<int> onSelect;
  final bool minimised;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final current = tabs[index];
    return Semantics(
      container: true,
      label: 'Tab bar',
      child: Glass(
        height: minimised ? 52 : kNovaTabBarHeight,
        padding: EdgeInsets.symmetric(horizontal: minimised ? 0 : 6),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: minimised
              ? Pressable(
                  onTap: onExpand,
                  semanticLabel: '${current.label}. Show all tabs',
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(current.selectedIcon, size: 24, color: c.primary),
                        const SizedBox(width: 8),
                        Text(current.label, style: NovaType.subhead.copyWith(fontWeight: FontWeight.w600, color: c.primary)),
                      ],
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      Pressable(
                        onTap: () => onSelect(i),
                        semanticLabel: tabs[i].label,
                        selected: i == index,
                        child: SizedBox(
                          width: 68,
                          height: 56,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(i == index ? tabs[i].selectedIcon : tabs[i].icon,
                                  size: 24, color: i == index ? c.primary : c.textSecondary),
                              const SizedBox(height: 2),
                              Text(
                                tabs[i].label,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: i == index ? c.primary : c.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Separate circular Scan button beside the tab bar — the only tinted glass.
class ScanButton extends StatelessWidget {
  const ScanButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: 'Scan a prescription or food',
      child: const Glass(
        width: 64,
        height: 64,
        tinted: true,
        child: Icon(CupertinoIcons.camera, size: 26),
      ),
    );
  }
}
