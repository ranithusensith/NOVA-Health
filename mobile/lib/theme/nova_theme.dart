import 'package:flutter/material.dart';

/// NOVA Health design tokens — exactly the values from the design system sheet.
@immutable
class NovaColors extends ThemeExtension<NovaColors> {
  const NovaColors({
    required this.background,
    required this.surface,
    required this.elevated,
    required this.fill,
    required this.separator,
    required this.textPrimary,
    required this.textSecondary,
    required this.primary,
    required this.primaryTint,
    required this.onPrimary,
    required this.success,
    required this.warning,
    required this.warningSurface,
    required this.warningContent,
    required this.warningIconSurface,
    required this.alert,
    required this.alertSurface,
    required this.sos,
    required this.water,
    required this.sleep,
    required this.steps,
    required this.glassFill,
    required this.glassHighlight,
    required this.glassEdge,
    required this.bubbleAi,
    required this.cardShadow,
  });

  final Color background;
  final Color surface;
  final Color elevated;

  /// Neutral fill for chips / mood faces sitting on a card.
  final Color fill;
  final Color separator;
  final Color textPrimary;
  final Color textSecondary;
  final Color primary;
  final Color primaryTint;
  final Color onPrimary;
  final Color success;
  final Color warning;
  final Color warningSurface;
  final Color warningContent;
  final Color warningIconSurface;
  final Color alert;
  final Color alertSurface;
  final Color sos;
  final Color water;
  final Color sleep;
  final Color steps;
  final Color glassFill;
  final Color glassHighlight;
  final Color glassEdge;
  final Color bubbleAi;
  final Color cardShadow;

  static const light = NovaColors(
    background: Color(0xFFF2F2F7),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    fill: Color(0xFFF2F2F7),
    separator: Color(0xFFE5E5EA),
    textPrimary: Color(0xFF1C1C1E),
    textSecondary: Color(0xFF6E6E73),
    primary: Color(0xFF0E8FA3),
    primaryTint: Color(0xFFE3F4F7),
    onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF30B66A),
    warning: Color(0xFFF5A524),
    warningSurface: Color(0xFFFFF4E0),
    warningContent: Color(0xFF8A5A0D),
    warningIconSurface: Color(0xFFFFE6B8),
    alert: Color(0xFFFF6B5E),
    alertSurface: Color(0xFFFFE9E6),
    sos: Color(0xFFE5352B),
    water: Color(0xFF32ADE6),
    sleep: Color(0xFF7D7AFF),
    steps: Color(0xFF30B66A),
    glassFill: Color(0x94FFFFFF), // white @ 58%
    glassHighlight: Color(0xE6FFFFFF),
    glassEdge: Color(0xBFFFFFFF),
    bubbleAi: Color(0xFFE9E9EC),
    cardShadow: Color(0x0A000000),
  );

  static const dark = NovaColors(
    background: Color(0xFF000000),
    surface: Color(0xFF1C1C1E),
    elevated: Color(0xFF2C2C2E),
    fill: Color(0xFF2C2C2E),
    separator: Color(0xFF38383A),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA1A1A6),
    primary: Color(0xFF3FC1D3),
    primaryTint: Color(0xFF0F2D32),
    onPrimary: Color(0xFF03262B),
    success: Color(0xFF3DDC84),
    warning: Color(0xFFFFB84D),
    warningSurface: Color(0xFF2E2410),
    warningContent: Color(0xFFFFB84D),
    warningIconSurface: Color(0xFF4A3A14),
    alert: Color(0xFFFF8478),
    alertSurface: Color(0xFF3A1F1B),
    sos: Color(0xFFFF453A),
    water: Color(0xFF32ADE6),
    sleep: Color(0xFF7D7AFF),
    steps: Color(0xFF30B66A),
    glassFill: Color(0x992C2C2E), // #2C2C2E @ 60%
    glassHighlight: Color(0x29FFFFFF),
    glassEdge: Color(0x33FFFFFF),
    bubbleAi: Color(0xFF2C2C2E),
    cardShadow: Color(0x00000000),
  );

  @override
  NovaColors copyWith() => this;

  @override
  NovaColors lerp(covariant ThemeExtension<NovaColors>? other, double t) =>
      (other is NovaColors && t >= 0.5) ? other : this;
}

/// SF Pro type scale. On iOS Flutter renders the system font (SF Pro) by default.
abstract final class NovaType {
  static const largeTitle = TextStyle(fontSize: 34, fontWeight: FontWeight.w700, height: 41 / 34, letterSpacing: -0.4);
  static const title2 = TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 28 / 22);
  static const headline = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 22 / 17);
  static const body = TextStyle(fontSize: 17, fontWeight: FontWeight.w400, height: 22 / 17);
  static const subhead = TextStyle(fontSize: 15, fontWeight: FontWeight.w400, height: 20 / 15);
  static const footnote = TextStyle(fontSize: 13, fontWeight: FontWeight.w400, height: 18 / 13);
  static const caption = TextStyle(fontSize: 12, fontWeight: FontWeight.w400, height: 16 / 12);

  /// Large numbers (SF Pro Rounded in the design). Tabular figures keep values steady.
  static TextStyle number(double size) => TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

abstract final class NovaSpace {
  static const double margin = 20;
  static const double cardPadding = 16;
  static const double gap = 16;
  static const double section = 32;
}

abstract final class NovaRadius {
  static const double card = 26;
  static const double sheet = 34;
  static const double capsule = 999;
}

abstract final class NovaTheme {
  static ThemeData light() => _build(NovaColors.light, Brightness.light);
  static ThemeData dark() => _build(NovaColors.dark, Brightness.dark);

  static ThemeData _build(NovaColors c, Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: c.primary, brightness: b).copyWith(
      primary: c.primary,
      onPrimary: c.onPrimary,
      surface: c.surface,
      onSurface: c.textPrimary,
      error: c.alert,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      platform: TargetPlatform.iOS,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.background,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: TextTheme(bodyMedium: NovaType.body.copyWith(color: c.textPrimary)),
      textSelectionTheme: TextSelectionThemeData(cursorColor: c.primary),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.elevated,
        contentTextStyle: NovaType.subhead.copyWith(color: c.textPrimary),
        shape: const StadiumBorder(),
        elevation: 2,
      ),
      extensions: [c],
    );
  }
}

extension NovaContext on BuildContext {
  NovaColors get nova => Theme.of(this).extension<NovaColors>()!;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}
