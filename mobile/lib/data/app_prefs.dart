import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/privacy_diagnostics.dart';

/// Device appearance and account-scoped daily goals stored on the phone.
class AppPrefs extends ChangeNotifier {
  AppPrefs._();
  static final AppPrefs instance = AppPrefs._();

  static const _kTheme = 'appearance.theme';
  static const _kReduceTransparency = 'appearance.reduceTransparency';
  static String _waterGoalKey(String owner) => 'goals.$owner.waterMl';
  static String _sleepGoalKey(String owner) => 'goals.$owner.sleepHours';

  SharedPreferences? _prefs;
  String? _owner;

  ThemeMode themeMode = ThemeMode.system;
  bool reduceTransparency = false;
  int waterGoalMl = 2500;
  double sleepGoalHours = 7;

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

  void selectAccount(String? owner) {
    if (owner == _owner) return;
    _owner = owner;
    // Old device-wide goals have no owner, so never assign them to an account.
    waterGoalMl =
        (owner == null ? null : _prefs?.getInt(_waterGoalKey(owner))) ?? 2500;
    sleepGoalHours =
        (owner == null ? null : _prefs?.getDouble(_sleepGoalKey(owner))) ?? 7;
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
    final owner = _owner;
    if (owner == null) return;
    waterGoalMl = ml;
    notifyListeners();
    await _prefs?.setInt(_waterGoalKey(owner), ml);
  }

  Future<void> setSleepGoalHours(double hours) async {
    final owner = _owner;
    if (owner == null) return;
    sleepGoalHours = hours;
    notifyListeners();
    await _prefs?.setDouble(_sleepGoalKey(owner), hours);
  }
}
