import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/health_repository.dart';
import '../data/reminder_plan.dart';
import '../screens/medications_screen.dart';

/// Lets the notification tap handler open screens.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Medicine reminders as local notifications on this phone. Nothing is sent to a server.
///
/// The schedule is rebuilt from the user's confirmed medicines when the app starts, when it
/// returns to the foreground, after signing in, and whenever medicines change.
class ReminderService extends ChangeNotifier with WidgetsBindingObserver {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  static const _kEnabled = 'reminders.enabled';
  static const _kShowNames = 'reminders.showNames';
  static const _testId = 900001;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  SharedPreferences? _prefs;
  bool _ready = false;
  bool _attached = false;
  bool _syncing = false;
  bool _again = false;

  bool enabled = false;
  bool showNames = true;

  /// How many notifications are scheduled right now (set after each sync).
  int scheduledCount = 0;

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'medicine_reminders',
      'Medicine reminders',
      channelDescription: 'Reminds you to take your medicines',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: DarwinNotificationDetails(presentAlert: true, presentBanner: true, presentList: true, presentSound: true),
  );

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

  /// Call once at start-up, after Supabase.initialize. Never throws.
  Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      _prefs = await SharedPreferences.getInstance();
      enabled = _prefs?.getBool(_kEnabled) ?? false;
      showNames = _prefs?.getBool(_kShowNames) ?? true;

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
    } catch (e) {
      debugPrint('Reminders could not start: $e');
    }
  }

  /// Starts listening for sign-in, sign-out, medicine changes and app resume.
  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    HealthRepository.changes.addListener(() {
      sync();
    });
    try {
      Supabase.instance.client.auth.onAuthStateChange.listen((state) {
        if (state.event == AuthChangeEvent.signedOut) {
          cancelAll();
        } else if (state.event == AuthChangeEvent.signedIn || state.event == AuthChangeEvent.initialSession) {
          sync();
        }
      });
    } catch (e) {
      debugPrint('Reminders could not watch sign-in: $e');
    }
    sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync();
  }

  void _onTap(NotificationResponse response) {
    final context = appNavigatorKey.currentContext;
    if (context != null && response.payload == 'medications') openMedications(context);
  }

  // ------------------------------------------------------------------ permission
  Future<bool> permissionGranted() async {
    try {
      if (Platform.isAndroid) return await _android?.areNotificationsEnabled() ?? false;
      if (Platform.isIOS) return (await _ios?.checkPermissions())?.isEnabled ?? false;
    } catch (e) {
      debugPrint('Could not check notification permission: $e');
    }
    return false;
  }

  Future<bool> requestPermission() async {
    try {
      if (Platform.isAndroid) return await _android?.requestNotificationsPermission() ?? false;
      if (Platform.isIOS) return await _ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    } catch (e) {
      debugPrint('Could not request notification permission: $e');
    }
    return false;
  }

  /// Android only: exact alarms need a separate permission the user grants in Settings.
  Future<bool> canScheduleExact() async {
    try {
      if (Platform.isAndroid) return await _android?.canScheduleExactNotifications() ?? false;
    } catch (_) {}
    return false;
  }

  Future<void> requestExactAlarms() async {
    try {
      await _android?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('Could not request exact alarms: $e');
    }
  }

  // ------------------------------------------------------------------ settings
  /// Turns reminders on (asking for permission first) or off. Returns the new state.
  Future<bool> setEnabled(bool value) async {
    if (value) {
      final granted = await permissionGranted() || await requestPermission();
      if (!granted) {
        enabled = false;
        await _prefs?.setBool(_kEnabled, false);
        notifyListeners();
        return false;
      }
    }
    enabled = value;
    await _prefs?.setBool(_kEnabled, value);
    notifyListeners();
    if (value) {
      await sync();
    } else {
      await cancelAll();
    }
    return enabled;
  }

  Future<void> setShowNames(bool value) async {
    showNames = value;
    await _prefs?.setBool(_kShowNames, value);
    notifyListeners();
    await sync();
  }

  // ------------------------------------------------------------------ scheduling
  Future<void> cancelAll() async {
    try {
      if (_ready) await _plugin.cancelAllPendingNotifications();
    } catch (e) {
      debugPrint('Could not cancel reminders: $e');
    }
    scheduledCount = 0;
    notifyListeners();
  }

  /// Rebuilds every scheduled reminder from the user's medicines. Safe to call often.
  Future<void> sync() async {
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    if (!_ready) return;
    try {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (!enabled || user == null || !await permissionGranted()) {
        await cancelAll();
        return;
      }

      final meds = await client
          .from('medications')
          .select('name,dosage,times,start_date,end_date')
          .eq('user_id', user.id)
          .eq('status', 'confirmed');

      final plans = buildReminderPlan(meds, DateTime.now());
      await _plugin.cancelAllPendingNotifications();

      final exact = await canScheduleExact();
      var id = 1;
      for (final plan in plans) {
        await _plugin.zonedSchedule(
          id: id++,
          title: plan.title,
          body: plan.body(showNames: showNames),
          // The instant is stored in UTC. A daily repeat then fires at the same clock time
          // every day (it is refreshed whenever the app opens, which also covers daylight saving).
          scheduledDate: tz.TZDateTime.from(plan.at, tz.UTC),
          notificationDetails: _details,
          androidScheduleMode:
              exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
          payload: 'medications',
          matchDateTimeComponents: plan.daily ? DateTimeComponents.time : null,
        );
      }
      scheduledCount = plans.length;
      notifyListeners();
    } catch (e) {
      debugPrint('Could not schedule reminders: $e');
    }
  }

  /// Shows a test notification in 5 seconds.
  Future<bool> sendTest() async {
    if (!_ready) return false;
    try {
      if (!await permissionGranted() && !await requestPermission()) return false;
      await _plugin.zonedSchedule(
        id: _testId,
        title: 'NOVA Health test',
        body: 'Reminders are working on this phone.',
        scheduledDate: tz.TZDateTime.from(DateTime.now().add(const Duration(seconds: 5)), tz.UTC),
        notificationDetails: _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'medications',
      );
      return true;
    } catch (e) {
      debugPrint('Could not send test reminder: $e');
      return false;
    }
  }

  Future<int> pendingCount() async {
    try {
      final pending = await _plugin.pendingNotificationRequests();
      return pending.where((n) => n.id != _testId).length;
    } catch (_) {
      return 0;
    }
  }
}
