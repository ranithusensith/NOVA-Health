import 'package:flutter/widgets.dart';

/// App-level accessibility settings. `reduceTransparency` turns every Liquid
/// Glass surface into a solid, opaque one with the same layout. The system
/// "Increase contrast" setting does the same automatically.
class NovaSettings extends InheritedWidget {
  const NovaSettings({super.key, required this.reduceTransparency, required super.child});

  final bool reduceTransparency;

  static bool reduceTransparencyOf(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<NovaSettings>();
    return (s?.reduceTransparency ?? false) || MediaQuery.highContrastOf(context);
  }

  @override
  bool updateShouldNotify(NovaSettings oldWidget) => oldWidget.reduceTransparency != reduceTransparency;
}
