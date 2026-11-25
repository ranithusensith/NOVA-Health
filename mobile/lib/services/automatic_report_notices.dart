import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';
import 'privacy_diagnostics.dart';
import 'reminder_service.dart';

/// Fence in-flight work at session and preference boundaries. The server owns
/// the durable claim, so a restart or second device cannot deliver it twice.
class ReportNoticeCoordinator {
  ReportNoticeCoordinator({
    required this.owner,
    required this.eligible,
    required this.permission,
    required this.claim,
    required this.deliver,
  });

  final String? Function() owner;
  final bool Function(String) eligible;
  final Future<bool> Function() permission;
  final Future<bool> Function(String) claim;
  final Future<void> Function(String, bool Function()) deliver;
  int _generation = 0;
  int? _running;

  void invalidate() => _generation++;

  Future<void> refresh() async {
    final account = owner();
    final generation = _generation;
    if (account == null || !eligible(account) || _running == generation) return;
    bool current() =>
        owner() == account && _generation == generation && eligible(account);
    _running = generation;
    try {
      if (await permission() &&
          current() &&
          await claim(account) &&
          current()) {
        await deliver(account, current);
      }
    } finally {
      if (_running == generation) _running = null;
    }
  }
}

class AutomaticReportNotices with WidgetsBindingObserver {
  AutomaticReportNotices._();

  static final instance = AutomaticReportNotices._();
  static const calendar = MethodChannel('nova_health/report_calendar');

  static Future<String?> deviceTimeZone() =>
      calendar.invokeMethod<String>('timeZone');

  SharedPreferences? _prefs;
  String? _owner;
  bool _foreground = false;
  bool _signingOut = false;
  bool _attached = false;
  int _sessionVersion = 0;
  static String _preference(String owner) => 'dailyReports.notice.$owner';
  static final _reminders = ReminderService.instance;
  static final _api = ApiClient.instance;

  late final _coordinator = ReportNoticeCoordinator(
    owner: () => _api.aiAccountId,
    eligible: (owner) => _foreground && !_signingOut && enabled(owner),
    permission: _reminders.permissionGranted,
    claim: _api.claimAutomaticReportNotice,
    deliver: (owner, current) => _reminders.showReportNotice(owner, current),
  );

  bool enabled(String owner) => _prefs?.getBool(_preference(owner)) ?? false;

  Future<void> attach() async {
    if (_attached) return;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      logAppEvent('Could not load report notice preferences.');
      return;
    }
    _attached = true;
    _owner = _api.aiAccountId;
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    // These listeners live for the same lifetime as the app's notification plugin.
    Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      final owner = event.session?.user.id;
      if (_owner == owner) return;
      _owner = owner;
      _sessionVersion++;
      _coordinator.invalidate();
      unawaited(_afterAccountChange());
    }, onError: (Object _) {});
    Timer.periodic(const Duration(minutes: 5), (_) => unawaited(_refresh()));
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(_refresh());
  }

  Future<bool> setEnabled(String owner, bool value) async {
    final version = _sessionVersion;
    bool current() =>
        _sessionVersion == version && _api.aiAccountId == owner && !_signingOut;
    if (_prefs == null || !current()) return false;
    if (value) {
      final granted = await _reminders.permissionGranted();
      if (!current()) return false;
      if (!granted && !await _reminders.requestPermission()) return false;
    }
    if (!current()) return false;
    _coordinator.invalidate();
    if (!await _prefs!.setBool(_preference(owner), value)) return false;
    if (value) {
      unawaited(_refresh());
    } else {
      await _clear();
    }
    return value;
  }

  Future<void> signOut(Future<void> Function() endSession) async {
    if (_signingOut) return;
    _signingOut = true;
    _sessionVersion++;
    _coordinator.invalidate();
    try {
      await _clear();
      await endSession();
    } finally {
      _signingOut = false;
      unawaited(_refresh());
    }
  }

  Future<void> _afterAccountChange() async {
    await _clear();
    await _refresh();
  }

  Future<void> _clear() async {
    try {
      await _reminders.clearReportNotice();
    } catch (_) {
      logAppEvent('Could not clear the generic report notice.');
    }
  }

  Future<void> _refresh() async {
    try {
      await _coordinator.refresh();
    } catch (_) {
      logAppEvent('Could not check for a daily report notice.');
    }
  }
}
