import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-level preferences: appearance and daily goals.
/// Stored on the phone (not in Supabase), so they work before sign-in too.
class AppPrefs extends ChangeNotifier {
  AppPrefs._();
  static final AppPrefs instance = AppPrefs._();

  static const _kTheme = 'appearance.theme';
  static const _kReduceTransparency = 'appearance.reduceTransparency';
  static const _kWaterGoal = 'goals.waterMl';
  static const _kSleepGoal = 'goals.sleepHours';

  SharedPreferences? _prefs;

  ThemeMode themeMode = ThemeMode.system;
  bool reduceTransparency = false;
  int waterGoalMl = 2500;
  double sleepGoalHours = 7;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _prefs = p;
      themeMode = ThemeMode.values[(p.getInt(_kTheme) ?? 0).clamp(0, ThemeMode.values.length - 1).toInt()];
      reduceTransparency = p.getBool(_kReduceTransparency) ?? false;
      waterGoalMl = p.getInt(_kWaterGoal) ?? 2500;
      sleepGoalHours = p.getDouble(_kSleepGoal) ?? 7;
    } catch (e) {
      debugPrint('Could not load preferences: $e');
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

  Future<void> setWaterGoalMl(int ml) async {
    waterGoalMl = ml;
    notifyListeners();
    await _prefs?.setInt(_kWaterGoal, ml);
  }

  Future<void> setSleepGoalHours(double hours) async {
    sleepGoalHours = hours;
    notifyListeners();
    await _prefs?.setDouble(_kSleepGoal, hours);
  }
}
