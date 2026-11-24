import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/privacy_diagnostics.dart';

/// Device appearance preferences.
class AppPrefs extends ChangeNotifier {
  AppPrefs._();
  static final AppPrefs instance = AppPrefs._();

  static const _kTheme = 'appearance.theme';
  static const _kReduceTransparency = 'appearance.reduceTransparency';
  SharedPreferences? _prefs;

  ThemeMode themeMode = ThemeMode.system;
  bool reduceTransparency = false;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _prefs = p;
      themeMode = ThemeMode.values[(p.getInt(_kTheme) ?? 0)
          .clamp(0, ThemeMode.values.length - 1)
          .toInt()];
      reduceTransparency = p.getBool(_kReduceTransparency) ?? false;
    } catch (_) {
      logAppEvent('Could not load preferences.');
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _prefs?.setInt(_kTheme, mode.index);
  }

  Future<void> setReduceTransparency(bool value) async {
    reduceTransparency = value;
    notifyListeners();
    await _prefs?.setBool(_kReduceTransparency, value);
  }
}
