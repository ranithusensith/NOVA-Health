import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');
const _alice = 'synthetic-alice';
const _bob = 'synthetic-bob';

List<Map<String, dynamic>> _medicine(String name, String time) => [
      {
        'name': name,
        'dosage': '250 mg',
        'times': [time],
        'start_date': '2030-11-01',
        'end_date': '2030-11-01',
      },
    ];

class _NotificationHost {
  final calls = <MethodCall>[];
  final pending = <int, Map<Object?, Object?>>{};
  final delivered = <String>[];
  bool permission = true;
  bool exact = true;
  bool exactRevoked = false;
  Future<bool> Function()? requestPermission;
  Future<void> Function()? afterSchedule;

  Future<Object?> invoke(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'initialize':
        return true;
      case 'areNotificationsEnabled':
        return permission;
      case 'checkPermissions':
        return {'isEnabled': permission};
      case 'requestNotificationsPermission':
      case 'requestPermissions':
        return requestPermission == null
            ? permission
            : await requestPermission!();
      case 'canScheduleExactNotifications':
        return exact;
      case 'cancelAll':
        pending.clear();
        delivered.clear();
        return null;
      case 'cancelAllPendingNotifications':
        pending.clear();
        return null;
      case 'zonedSchedule':
        final arguments = Map<Object?, Object?>.from(call.arguments as Map);
        if (exactRevoked &&
            (arguments['platformSpecifics'] as Map)['scheduleMode'] ==
                'exactAllowWhileIdle') {
          throw PlatformException(code: 'exact_alarms_not_permitted');
        }
        pending[arguments['id'] as int] = arguments;
        await afterSchedule?.call();
        return null;
      case 'pendingNotificationRequests':
        return pending.values.toList();
      default:
        throw MissingPluginException(call.method);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime(2030, 11, 1, 12);
  late _NotificationHost host;
  late String? account;
  late ReminderService service;

  void platform(TargetPlatform value) {
    debugDefaultTargetPlatformOverride = value;
    if (value == TargetPlatform.android) {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
    } else {
      IOSFlutterLocalNotificationsPlugin.registerWith();
    }
  }

  ReminderService reminders({
    Future<List<Map<String, dynamic>>> Function(String)? load,
    DateTime Function()? clock,
  }) =>
      ReminderService(
        accountId: () => account,
        loadMedicines: load ??
            ((id) async => _medicine(id, id == _alice ? '21:00' : '22:00')),
        clock: clock ?? () => now,
      );

  setUp(() {
    platform(TargetPlatform.android);
    SharedPreferences.setMockInitialValues({
      'reminders.v2.$_alice.enabled': true,
      'reminders.v2.$_bob.enabled': true,
    });
    account = _alice;
    host = _NotificationHost();
    messenger.setMockMethodCallHandler(_channel, host.invoke);
    service = reminders();
  });

  tearDown(() {
    service.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
        '$target schedules dated generic requests and opt-in is limited to the account',
        () async {
      platform(target);
      SharedPreferences.setMockInitialValues({
        'reminders.enabled': true,
        'reminders.showNames': true,
      });
      host.delivered.add('legacy medicine detail');
      await service.init();
      await service.sync();

      expect(host.delivered, isEmpty);
      expect(service.showNames, isFalse);
      final notice = host.pending.values.single;
      expect(notice['title'], 'NOVA Health reminder');
      expect(notice['body'], 'Open NOVA Health to view your reminder.');
      expect(notice['payload'], isNot(contains(_alice)));
      expect(notice['timeZoneName'], 'UTC');
      expect(notice.containsKey('matchDateTimeComponents'), isFalse);
      final specifics = notice['platformSpecifics'] as Map;
      if (target == TargetPlatform.android) {
        expect(specifics['visibility'], NotificationVisibility.private.index);
        expect(specifics['scheduleMode'], 'exactAllowWhileIdle');
      } else {
        final init = host.calls.first.arguments as Map;
        expect(init['requestAlertPermission'], isFalse);
        expect(specifics['presentBanner'], isTrue);
      }

      await service.setShowNames(true);
      expect(host.pending.values.single['body'], contains('$_alice 250 mg'));
      host.delivered.add('$_alice 250 mg');
      await service.setShowNames(false);
      expect(host.delivered, isEmpty);
      expect(host.pending.values.single['body'],
          'Open NOVA Health to view your reminder.');
      await service.setShowNames(true);
      account = _bob;
      await service.sync();
      expect(service.enabled, isFalse);
      expect(service.showNames, isFalse);
      expect(host.pending, isEmpty);
    });

    test('$target permission denial clears alerts and leaves enable off',
        () async {
      await service.init();
      await service.sync();
      expect(host.pending, isNotEmpty);
      platform(target);
      host.permission = false;
      await service.sync();
      expect(host.pending, isEmpty);
      expect(await service.setEnabled(true), isFalse);
      expect(service.enabled, isFalse);
      expect(host.pending, isEmpty);
    });
  }

  test('Android schedules inexact one-shots when exact alarms are unavailable',
      () async {
    host.exact = false;
    await service.init();
    await service.sync();
    final specifics = host.pending.values.single['platformSpecifics'] as Map;
    expect(specifics['scheduleMode'], 'inexactAllowWhileIdle');
  });

  test('Android falls back if exact alarm access is revoked during scheduling',
      () async {
    host.exactRevoked = true;
    await service.init();
    await service.sync();
    final specifics = host.pending.values.single['platformSpecifics'] as Map;
    expect(specifics['scheduleMode'], 'inexactAllowWhileIdle');
    expect(host.calls.where((call) => call.method == 'zonedSchedule'),
        hasLength(2));
  });

  test(
      'sign-out clears delivered and pending alerts without waiting for a stale fetch',
      () async {
    final fetching = Completer<void>();
    final result = Completer<List<Map<String, dynamic>>>();
    service.dispose();
    service = reminders(load: (_) {
      fetching.complete();
      return result.future;
    });
    await service.init();
    final refresh = service.sync();
    await fetching.future;
    host.delivered.add('synthetic old preview');
    await service.signOut(() async {
      expect(host.pending, isEmpty);
      expect(host.delivered, isEmpty);
      account = null;
    });
    result.complete(_medicine(_alice, '21:00'));
    await refresh;
    await service.sync();
    expect(host.pending, isEmpty);
    expect(host.calls.where((call) => call.method == 'zonedSchedule'), isEmpty);
  });

  test(
      'a superseded account fetch cannot cancel or replace the new account batch',
      () async {
    final fetching = Completer<void>();
    final oldResult = Completer<List<Map<String, dynamic>>>();
    service.dispose();
    service = reminders(load: (id) async {
      if (id == _bob) return _medicine(_bob, '22:00');
      fetching.complete();
      return oldResult.future;
    });
    await service.init();
    final old = service.sync();
    await fetching.future;
    account = _bob;
    await service.sync();
    final newBatch = host.pending.values.single;
    oldResult.complete(_medicine(_alice, '21:00'));
    await old;
    expect(host.pending.values.single, newBatch);
  });

  test(
      'disabling during an in-flight platform call removes its completed alert',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    host.afterSchedule = () {
      started.complete();
      return release.future;
    };
    await service.init();
    final refresh = service.sync();
    await started.future;
    final disable = service.setEnabled(false);
    expect(service.enabled, isFalse);
    release.complete();
    await refresh;
    expect(await disable, isFalse);
    expect(host.pending, isEmpty);
  });

  test('an account switch waits for cleanup of an in-flight native schedule',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    host.afterSchedule = () {
      host.afterSchedule = null;
      started.complete();
      return release.future;
    };
    await service.init();
    final old = service.sync();
    await started.future;
    final oldBatch = host.pending.values.single['payload'];
    account = _bob;
    final fresh = service.sync();
    release.complete();
    await Future.wait([old, fresh]);
    expect(host.pending.values.single['payload'], isNot(oldBatch));
    expect(host.calls.where((call) => call.method == 'zonedSchedule'),
        hasLength(2));
  });

  test('a permission prompt cannot enable reminders after switching accounts',
      () async {
    SharedPreferences.setMockInitialValues({});
    host.permission = false;
    final prompt = Completer<void>();
    final choice = Completer<bool>();
    host.requestPermission = () {
      prompt.complete();
      return choice.future;
    };
    await service.init();
    final enabled = service.setEnabled(true);
    await prompt.future;
    account = _bob;
    await service.sync();
    choice.complete(true);
    expect(await enabled, isFalse);
    expect(service.enabled, isFalse);
    expect(host.pending, isEmpty);
  });

  test(
      'restart preserves a same-account batch offline and clears it after a timezone change',
      () async {
    tzdata.initializeTimeZones();
    var clock = tz.TZDateTime(tz.getLocation('UTC'), 2030, 11, 1, 12);
    var offline = false;
    service.dispose();
    service = reminders(
      load: (_) async {
        if (offline) throw StateError('synthetic offline');
        return _medicine(_alice, '21:00');
      },
      clock: () => clock,
    );
    await service.init();
    await service.sync();
    final batch = host.pending.values.single;
    service.dispose();
    offline = true;
    service = reminders(
        load: (_) async => throw StateError('synthetic offline'),
        clock: () => clock);
    await service.init();
    await service.sync();
    expect(host.pending.values.single, batch);
    clock = tz.TZDateTime(tz.getLocation('Asia/Colombo'), 2030, 11, 1, 12);
    await service.sync();
    expect(host.pending, isEmpty);
  });
}
