import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/outdoor_notice.dart';
import '../data/weather.dart';
import 'api_client.dart';
import 'privacy_diagnostics.dart';
import 'reminder_service.dart';

class OutdoorAlertCoordinator extends ChangeNotifier {
  OutdoorAlertCoordinator({
    required this.owner,
    required this.cityFor,
    required this.active,
    required this.permission,
    required this.fetch,
    required this.claim,
    required this.deliver,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final String? Function() owner;
  final WeatherCity? Function(String) cityFor;
  final bool Function() active;
  final Future<bool> Function() permission;
  final Future<OutdoorNotice> Function(String, int) fetch;
  final Future<bool> Function(String, String) claim;
  final Future<void> Function(String, bool Function()) deliver;
  final DateTime Function() clock;

  OutdoorNotice? notice;
  bool permissionDenied = false;
  int _generation = 0;
  int? _running;
  DateTime? _checkedAt;

  void invalidate() {
    _generation++;
    _checkedAt = null;
    notice = null;
    permissionDenied = false;
    notifyListeners();
  }

  Future<void> refresh() async {
    final account = owner();
    if (account == null || !active()) return;
    final city = cityFor(account);
    final generation = _generation;
    if (city == null || _running == generation) return;
    bool current() =>
        active() &&
        owner() == account &&
        generation == _generation &&
        cityFor(account)?.id == city.id;
    _running = generation;
    try {
      final granted = await permission();
      if (!current()) return;
      permissionDenied = !granted;
      if (!granted) {
        notice = null;
        notifyListeners();
        return;
      }
      final now = clock();
      final last = _checkedAt;
      if (last != null && now.difference(last) < const Duration(minutes: 30)) {
        notifyListeners(); // Re-render expired evidence without using it.
        return;
      }
      _checkedAt = now;
      final result = await fetch(account, city.id);
      if (!current()) return;
      notice = result;
      notifyListeners();
      bool canDeliver() =>
          current() && result.statusAt(clock()) == OutdoorNoticeStatus.eligible;
      if (result.date case final day? when canDeliver()) {
        if (await claim(account, day) && canDeliver()) {
          await deliver(account, canDeliver);
        }
      }
    } catch (_) {
      if (current()) {
        notice = const OutdoorNotice(OutdoorNoticeStatus.unavailable);
        notifyListeners();
      }
      logAppEvent('Outdoor planning notice could not be checked.');
    } finally {
      if (_running == generation) _running = null;
    }
  }
}

/// Device-local consent and deduplication. No health data or forecast is saved.
class OutdoorAlerts with WidgetsBindingObserver {
  OutdoorAlerts._();
  static final instance = OutdoorAlerts._();
  static final _api = ApiClient.instance;
  static final _reminders = ReminderService.instance;

  SharedPreferences? _prefs;
  String? _owner;
  bool _foreground = false;
  bool _signingOut = false;
  bool _changing = false;
  int _session = 0;

  static String _cityKey(String owner) => 'outdoorNotice.city.$owner';
  static String _dayKey(String owner) => 'outdoorNotice.lastDate.$owner';

  late final coordinator = OutdoorAlertCoordinator(
    owner: () => _api.aiAccountId,
    cityFor: cityFor,
    active: () => _foreground && !_signingOut && !_changing,
    permission: _reminders.permissionGranted,
    fetch: _api.outdoorNotice,
    claim: (owner, date) async {
      final prefs = _prefs;
      if (prefs == null) return false;
      final previous = prefs.getString(_dayKey(owner));
      if (previous != null && date.compareTo(previous) <= 0) return false;
      return prefs.setString(_dayKey(owner), date);
    },
    deliver: _reminders.showOutdoorNotice,
  );

  WeatherCity? cityFor(String owner) {
    try {
      final encoded = _prefs?.getString(_cityKey(owner));
      if (encoded == null) return null;
      return WeatherCity.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> attach() async {
    if (_prefs != null) return;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      logAppEvent('Could not load outdoor notice settings.');
      return;
    }
    _owner = _api.aiAccountId;
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      final owner = event.session?.user.id;
      if (owner == _owner) return;
      _owner = owner;
      _session++;
      coordinator.invalidate();
      unawaited(_reconcile());
    }, onError: (Object _) {});
    Timer.periodic(
        const Duration(minutes: 1), (_) => unawaited(coordinator.refresh()));
    unawaited(_reconcile());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(coordinator.refresh());
  }

  Future<bool> setCity(String owner, WeatherCity? city) async {
    final prefs = _prefs;
    final session = _session;
    bool current() =>
        session == _session && owner == _api.aiAccountId && !_signingOut;
    if (prefs == null || _changing || !current()) return false;
    _changing = true;
    coordinator.invalidate();
    try {
      await _clear();
      if (city != null) {
        final granted = await _reminders.permissionGranted();
        if (!current()) return false;
        if (!granted && !await _reminders.requestPermission()) return false;
      }
      if (!current()) return false;
      if (city == null) return await prefs.remove(_cityKey(owner));
      return await prefs.setString(
          _cityKey(owner),
          jsonEncode({
            'id': city.id,
            'name': city.name,
            'region': city.region,
            'country': city.country,
          }));
    } finally {
      _changing = false;
      coordinator.invalidate();
      unawaited(coordinator.refresh());
    }
  }

  Future<void> signOut(Future<void> Function() endSession) async {
    if (_signingOut) return;
    _signingOut = true;
    _session++;
    coordinator.invalidate();
    try {
      await _clear();
      await endSession();
    } finally {
      _signingOut = false;
      unawaited(coordinator.refresh());
    }
  }

  Future<void> _reconcile() async {
    await _clear();
    await coordinator.refresh();
  }

  Future<void> _clear() async {
    try {
      await _reminders.clearOutdoorNotice();
    } catch (_) {
      logAppEvent('Could not clear the generic outdoor notice.');
    }
  }
}
