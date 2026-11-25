import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/timezone.dart' as tz;

import '../config.dart';
import '../data/care_models.dart';
import '../data/care_repository.dart';
import '../data/reminder_plan.dart';
import '../screens/medications_screen.dart';
import 'privacy_diagnostics.dart';

/// One account's dated notification batch. Network reads never hold the native queue.
class ReminderService extends ChangeNotifier with WidgetsBindingObserver {
  ReminderService({
    required String? Function() accountId,
    required Future<List<Map<String, dynamic>>> Function(String) loadMedicines,
    DateTime Function()? clock,
  })  : _accountId = accountId,
        _loadMedicines = loadMedicines,
        _clock = clock ?? DateTime.now;

  static final ReminderService instance = ReminderService(
    accountId: () => AppConfig.current.canConnect
        ? Supabase.instance.client.auth.currentUser?.id
        : null,
    loadMedicines: (account) async => await Supabase.instance.client
        .from('medications')
        .select(
            'id,name,dosage,times,start_date,end_date,prescription_plan,reminders_enabled')
        .eq('user_id', account)
        .eq('status', 'confirmed'),
  );

  // The Android reboot receiver recognizes the prefix for dated batches.
  static const _payloadPrefix = 'nova-reminder-v2:';
  static const _scheduleScopeKey = 'reminders.v2.scheduleScope';
  static const _notificationOwnerKey = 'notifications.v1.owner';
  static const _testId = 900001;
  static const _reportNoticeId = 900002;
  static const _outdoorNoticeId = 900003;
  static String _enabledKey(String account) => 'reminders.v2.$account.enabled';
  static String _detailsKey(String account) => 'reminders.v2.$account.details';

  final String? Function() _accountId;
  final Future<List<Map<String, dynamic>>> Function(String) _loadMedicines;
  final DateTime Function() _clock;
  final _plugin = FlutterLocalNotificationsPlugin();
  GlobalKey<NavigatorState>? navigatorKey;
  SharedPreferences? _prefs;
  Future<void> _nativeTail = Future.value();
  StreamSubscription<AuthState>? _authEvents;
  Timer? _calendarTimer;
  String? _account;
  String? _notificationOwner;
  bool _medicationsCleared = false;
  String? _appliedScope;
  String? _batchPayload;
  String? _calendarStamp;
  bool _ready = false;
  bool _signingOut = false;
  bool _enabled = false;
  bool _showNames = false;
  int _generation = 0;
  int _permissionRequest = 0;

  bool get enabled => _enabled;
  bool get showNames => _showNames;

  static const _notificationDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'medicine_reminders_private',
      'Medicine reminders',
      channelDescription: 'Local NOVA Health reminders',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.private,
    ),
    iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: true),
  );

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      final restoredAccount = _accountId();
      // Preserve the old switch only for a restored account. The old name
      // preference had an unsafe implicit default and is never inherited.
      final legacyEnabled = prefs.getBool('reminders.enabled');
      if (restoredAccount != null &&
          legacyEnabled != null &&
          !prefs.containsKey(_enabledKey(restoredAccount))) {
        await prefs.setBool(_enabledKey(restoredAccount), legacyEnabled);
      }
      await prefs.remove('reminders.enabled');
      await prefs.remove('reminders.showNames');
      _appliedScope = prefs.getString(_scheduleScopeKey);
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onTap,
      );
      _ready = true;
      // A notification can belong to the restored account even when medication
      // reminders are disabled or their schedule is out of date.
      final account = _readAccount();
      if (account == null || prefs.getString(_notificationOwnerKey) != account) {
        await _invalidateNotifications(all: true, owner: account);
      } else {
        _notificationOwner = account;
      }
    } catch (_) {
      logAppEvent('Reminders could not start or clear the previous schedule.');
    }
  }

  void attach() {
    if (_authEvents != null) return;
    WidgetsBinding.instance.addObserver(this);
    CareRepository.medicationChanges.addListener(_medicinesChanged);
    _authEvents =
        Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut ||
          state.event == AuthChangeEvent.signedIn ||
          state.event == AuthChangeEvent.initialSession ||
          _accountId() != _account) {
        unawaited(sync(
          clearAll: state.event == AuthChangeEvent.signedOut ||
              state.session?.user.id != _notificationOwner,
        ));
      }
    }, onError: (Object _) {});
    _calendarTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_enabled && _calendarStamp != _stamp(_clock())) unawaited(sync());
    });
    unawaited(sync());
  }

  void _medicinesChanged() => unawaited(sync(clearFirst: true));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CareRepository.medicationChanges.removeListener(_medicinesChanged);
    unawaited(_authEvents?.cancel());
    _calendarTimer?.cancel();
    super.dispose();
  }

  void _onTap(NotificationResponse response) {
    final context = navigatorKey?.currentContext;
    if (context != null &&
        _enabled &&
        !_signingOut &&
        _account != null &&
        _account == _accountId() &&
        _batchPayload != null &&
        response.payload == _batchPayload) {
      openMedications(context);
    }
  }

  Future<bool> permissionGranted() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await _android?.areNotificationsEnabled() ?? false;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return (await _ios?.checkPermissions())?.isEnabled ?? false;
      }
    } catch (_) {
      logAppEvent('Could not check notification permission.');
    }
    return false;
  }

  Future<bool> requestPermission() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await _android?.requestNotificationsPermission() ?? false;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return await _ios?.requestPermissions(alert: true, sound: true) ??
            false;
      }
    } catch (_) {
      logAppEvent('Could not request notification permission.');
    }
    return false;
  }

  Future<bool> canScheduleExact() async {
    try {
      return await _android?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestExactAlarms() async {
    try {
      await _android?.requestExactAlarmsPermission();
    } catch (_) {
      logAppEvent('Could not request exact alarm permission.');
    }
  }

  String? _readAccount() {
    final account = _accountId();
    if (account != _account) {
      _account = account;
      _permissionRequest++;
      _enabled =
          account != null && (_prefs?.getBool(_enabledKey(account)) ?? false);
      _showNames =
          account != null && (_prefs?.getBool(_detailsKey(account)) ?? false);
      notifyListeners();
    }
    return account;
  }

  Future<bool> setEnabled(bool value) async {
    final account = _readAccount();
    if (!_ready || account == null || _signingOut) return false;
    final request = ++_permissionRequest;
    var granted = !value || await permissionGranted();
    if (request != _permissionRequest ||
        _accountId() != account ||
        _signingOut) {
      return false;
    }
    if (!granted) granted = await requestPermission();
    if (request != _permissionRequest ||
        _accountId() != account ||
        _signingOut) {
      return false;
    }
    _enabled = value && granted;
    final save = _prefs?.setBool(_enabledKey(account), _enabled);
    final refresh = sync(clearFirst: !_enabled);
    notifyListeners();
    await save;
    await refresh;
    return _accountId() == account && _enabled;
  }

  Future<void> setShowNames(bool value) async {
    final account = _readAccount();
    if (!_ready || account == null || _signingOut || value == _showNames) {
      return;
    }
    _showNames = value;
    final save = _prefs?.setBool(_detailsKey(account), value);
    final refresh = sync(clearFirst: true);
    notifyListeners();
    await save;
    await refresh;
  }

  /// Fence scheduling before signing out, even if Supabase has not emitted its event yet.
  Future<void> signOut(Future<void> Function() endSession) async {
    if (_signingOut) return;
    _signingOut = true;
    _permissionRequest++;
    try {
      await sync(clearAll: true);
      await endSession();
    } finally {
      _signingOut = false;
      unawaited(sync());
    }
  }

  static String _stamp(DateTime now) =>
      '${ymd(now)}|${now.timeZoneName}|${now.timeZoneOffset.inMinutes}';
  String _scope(String account) {
    final now = _clock();
    return jsonEncode(
        [account, now.timeZoneName, now.timeZoneOffset.inMinutes, _showNames]);
  }

  bool _current(int generation, String account) =>
      generation == _generation && _accountId() == account && !_signingOut;

  Future<T> _onNativeQueue<T>(Future<T> Function() operation) {
    final run = _nativeTail.then((_) => operation());
    _nativeTail =
        run.then<void>((_) {}, onError: (Object error, StackTrace trace) {});
    return run;
  }

  Future<void> _invalidateNotifications(
      {required bool all, required String? owner}) {
    _appliedScope = null;
    _batchPayload = null;
    return _onNativeQueue(() async {
      try {
        await _prefs?.remove(_scheduleScopeKey);
      } finally {
        if (all) {
          _notificationOwner = null;
          await _prefs?.remove(_notificationOwnerKey);
          await _plugin.cancelAll();
          if (owner != null) {
            await _prefs?.setString(_notificationOwnerKey, owner);
          }
          _notificationOwner = owner;
        } else if (!_medicationsCleared) {
          // IDs 1–60 are reserved for medication doses. Cancel both pending and
          // delivered previews, without touching report or outdoor notices.
          for (var id = 1; id <= 60; id++) {
            await _plugin.cancel(id: id);
          }
          await _plugin.cancel(id: _testId);
        }
        _medicationsCleared = true;
      }
    });
  }

  Future<void> sync({bool clearFirst = false, bool clearAll = false}) async {
    if (!_ready) return;
    final account = _readAccount();
    final generation = ++_generation;
    _calendarStamp = _stamp(_clock());
    final active = account != null && _enabled && !_signingOut;
    final scope = active ? _scope(account) : null;
    final accountBoundary =
        clearAll || _signingOut || _notificationOwner != account;

    try {
      if (accountBoundary || clearFirst || !active || _appliedScope != scope) {
        await _invalidateNotifications(
          all: accountBoundary,
          owner: _signingOut ? null : account,
        );
      }
      if (!active || !_current(generation, account)) return;
      final granted = await permissionGranted();
      if (!_current(generation, account)) return;
      if (!granted) {
        await _invalidateNotifications(all: false, owner: account);
        return;
      }

      final medicines = await _loadMedicines(account);
      if (!_current(generation, account)) return;
      var exact = await canScheduleExact();
      if (!_current(generation, account)) return;

      await _onNativeQueue(() async {
        if (!_current(generation, account) || _scope(account) != scope) return;
        final plans = buildReminderPlan(medicines, _clock());
        // Report and outdoor notices are immediate and never pending.
        await _plugin.cancelAllPendingNotifications();
        if (!_current(generation, account)) return;
        await _prefs?.setString(_scheduleScopeKey, scope!);
        if (!_current(generation, account)) return;
        _appliedScope = scope;
        _medicationsCleared = false;
        final random = Random.secure();
        final payload = _payloadPrefix +
            base64UrlEncode(List.generate(12, (_) => random.nextInt(256)));
        _batchPayload = payload;
        for (var i = 0;
            i < plans.length &&
                _current(generation, account) &&
                _scope(account) == scope;
            i++) {
          final plan = plans[i];
          if (!plan.at.isAfter(_clock())) continue;
          final body = plan.body(showNames: _showNames);
          try {
            await _schedule(i + 1, plan.title, body, plan.at,
                exact: exact, payload: payload);
          } on PlatformException catch (error) {
            if (!exact || error.code != 'exact_alarms_not_permitted') rethrow;
            exact = false;
            if (!_current(generation, account) || _scope(account) != scope) {
              return;
            }
            if (plan.at.isAfter(_clock())) {
              await _schedule(i + 1, plan.title, body, plan.at,
                  exact: false, payload: payload);
            }
          }
        }
      });
    } catch (_) {
      // A failed refresh for the same account can keep its previous bounded schedule.
      logAppEvent('Could not refresh local reminders.');
    }
  }

  Future<void> _schedule(int id, String title, String body, DateTime at,
          {required bool exact, String? payload}) =>
      _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(at, tz.UTC),
        notificationDetails: _notificationDetails,
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );

  Future<void> showReportNotice(String owner, bool Function() current) =>
      _showPrivateUpdate(_reportNoticeId, owner, current);

  Future<void> showOutdoorNotice(String owner, bool Function() current) =>
      _showPrivateUpdate(_outdoorNoticeId, owner, current);

  Future<void> _showPrivateUpdate(
          int id, String owner, bool Function() current) =>
      _onNativeQueue(() async {
        if (!_ready ||
            _signingOut ||
            _accountId() != owner ||
            _notificationOwner != owner ||
            !current()) {
          return;
        }
        await _plugin.show(
          id: id,
          title: 'NOVA Health',
          body: 'Open NOVA Health to view an update.',
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'nova_private_updates',
              'Private NOVA updates',
              visibility: NotificationVisibility.private,
            ),
            iOS: DarwinNotificationDetails(
                presentAlert: true, presentBanner: true, presentList: true),
          ),
        );
      });

  Future<void> clearReportNotice() => _clearPrivateUpdate(_reportNoticeId);

  Future<void> clearOutdoorNotice() => _clearPrivateUpdate(_outdoorNoticeId);

  Future<void> _clearPrivateUpdate(int id) => _onNativeQueue(() async {
        if (_ready) await _plugin.cancel(id: id);
      });

  Future<bool> sendTest() async {
    final account = _readAccount();
    if (!_ready || account == null || _signingOut) return false;
    final generation = _generation;
    final granted = await permissionGranted();
    if (!_current(generation, account)) return false;
    if (!granted && !await requestPermission()) return false;
    try {
      return await _onNativeQueue(() async {
        if (!_current(generation, account)) return false;
        _medicationsCleared = false;
        await _schedule(
            _testId,
            'NOVA Health test',
            'Reminders are working on this phone.',
            _clock().add(const Duration(seconds: 5)),
            exact: false);
        return _current(generation, account);
      });
    } catch (_) {
      return false;
    }
  }

  Future<int> pendingCount() async {
    final account = _accountId();
    if (!_enabled || account == null || _appliedScope != _scope(account)) {
      return 0;
    }
    final generation = _generation;
    try {
      final pending = await _plugin.pendingNotificationRequests();
      if (!_current(generation, account)) return 0;
      return pending
          .where((n) => n.payload?.startsWith(_payloadPrefix) ?? false)
          .length;
    } catch (_) {
      return 0;
    }
  }
}
