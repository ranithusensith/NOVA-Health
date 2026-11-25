import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:nova_health/data/care_models.dart';
import 'package:nova_health/data/wearable_daily.dart';
import 'package:nova_health/services/health_sync.dart';
import 'package:nova_health/services/wearable_daily_sync.dart';

final _now = DateTime(2026, 11, 25, 12);

class _Store implements WearableImportStore {
  @override
  String? accountId = 'synthetic-owner';

  final events = StreamController<String?>.broadcast(sync: true);
  final batches = <List<WearableTotal>>[];
  final owners = <String>[];
  int? savedCount;

  @override
  Stream<String?> get accountChanges => events.stream;

  void change(String? account) {
    accountId = account;
    events.add(account);
  }

  @override
  Future<int> save(List<WearableTotal> totals, String expectedAccount) async {
    batches.add(totals);
    owners.add(expectedAccount);
    return savedCount ?? totals.length;
  }
}

class _Reader implements WearableDailyReader {
  @override
  bool apple = false;
  @override
  String get source => apple ? 'apple_health' : 'health_connect';

  bool present = true;
  bool permission = true;
  bool revoked = false;
  final authorizations = <WearableMetric>[];
  final stepRanges = <(DateTime, DateTime)>[];
  int sleepReads = 0;
  int? stepCount;
  List<AsleepInterval> intervals = const [];
  Completer<bool>? permissionResult;

  @override
  Future<bool> available() async => present;
  @override
  Future<bool> authorize(WearableMetric metric) async {
    authorizations.add(metric);
    return permissionResult == null ? permission : permissionResult!.future;
  }

  @override
  Future<int?> steps(DateTime start, DateTime end) async {
    stepRanges.add((start, end));
    if (revoked) throw PlatformException(code: 'HEALTH_READ_DENIED');
    return stepCount;
  }

  @override
  Future<List<AsleepInterval>> asleep(DateTime start, DateTime end) async {
    sleepReads++;
    return intervals;
  }
}

class _Permissions implements Health {
  final requests = <(List<HealthDataType>, List<HealthDataAccess>?)>[];
  final checks = <List<HealthDataType>>[];

  @override
  Future<void> configure() async {}
  @override
  Future<bool> isHealthConnectAvailable() async => true;
  @override
  Future<bool?> hasPermissions(List<HealthDataType> types,
      {List<HealthDataAccess>? permissions}) async {
    checks.add(types);
    return false;
  }

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types,
      {List<HealthDataAccess>? permissions}) async {
    requests.add((types, permissions));
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('platform permissions request only the chosen read type', () async {
    final health = _Permissions();
    final android = PlatformWearableDailyReader(
        health: health, platform: TargetPlatform.android);
    final apple = PlatformWearableDailyReader(
        health: health, platform: TargetPlatform.iOS);
    await android.authorize(WearableMetric.steps);
    await android.authorize(WearableMetric.sleep);
    await apple.authorize(WearableMetric.steps);
    await apple.authorize(WearableMetric.sleep);
    expect(health.checks, [
      [HealthDataType.STEPS],
      [HealthDataType.SLEEP_SESSION]
    ]);
    expect(health.requests.map((request) => request.$1), [
      [HealthDataType.STEPS],
      [HealthDataType.SLEEP_SESSION],
      [HealthDataType.STEPS],
      [HealthDataType.SLEEP_ASLEEP],
    ]);
    for (final request in health.requests) {
      expect(request.$2, [HealthDataAccess.READ]);
    }
  });

  test(
      'step import uses local days, captures only elapsed time, and keeps legitimate zero',
      () async {
    final store = _Store();
    addTearDown(store.events.close);
    final reader = _Reader()..stepCount = 0;
    final sync =
        WearableDailySync(store: store, reader: reader, now: () => _now);
    final result = await sync.import(WearableMetric.steps);
    expect(result.status, WearableImportStatus.imported);
    expect(result.found, 7);
    expect(result.saved, 7);
    expect(store.owners, ['synthetic-owner']);
    expect(reader.authorizations, [WearableMetric.steps]);
    expect(reader.sleepReads, 0);
    expect(reader.stepRanges.last, (dayOf(_now), _now));
    expect(reader.stepRanges.first,
        (calendarDay(_now, -6), calendarDay(_now, -5)));
    expect(
        store.batches.single.every(
            (row) => row.value == 0 && row.metric == WearableMetric.steps),
        isTrue);
    store.savedCount = 0;
    expect((await sync.import(WearableMetric.steps)).saved, 0);
  });

  test(
      'overnight sleep assigns confirmed asleep time to wake day and de-duplicates overlap',
      () async {
    final store = _Store();
    addTearDown(store.events.close);
    final reader = _Reader()..apple = true;
    final first = DateTime(2026, 11, 24, 23);
    final midnight = DateTime(2026, 11, 25);
    final four = DateTime(2026, 11, 25, 4);
    final wake = DateTime(2026, 11, 25, 7);
    reader.intervals = [
      AsleepInterval(first, four),
      AsleepInterval(first, four),
      AsleepInterval(midnight, four),
      AsleepInterval(four.add(const Duration(minutes: 30)), wake),
      AsleepInterval(wake, wake),
      AsleepInterval(_now, _now.add(const Duration(hours: 1))),
    ];
    final sync =
        WearableDailySync(store: store, reader: reader, now: () => _now);
    final result = await sync.import(WearableMetric.sleep);
    expect(result.saved, 1);
    expect(reader.stepRanges, isEmpty);
    expect(store.batches.single.single.day.date, '2026-11-25');
    expect(store.batches.single.single.value, 27000);
    expect(store.batches.single.single.source, 'apple_health');
    expect(
        store.batches.single.single.toJson().keys,
        unorderedEquals([
          'metric',
          'local_date',
          'window_start',
          'window_end',
          'captured_at',
          'value',
          'source'
        ]));
  });

  test('DST duration comes from instants, not wall-clock subtraction', () {
    final totals = sleepSecondsByWakeDay([
      AsleepInterval(DateTime.parse('2026-03-07T23:00:00-05:00'),
          DateTime.parse('2026-03-08T07:00:00-04:00')),
    ], DateTime(2026, 3, 7), DateTime.parse('2026-03-08T12:00:00-04:00'),
        localize: (instant) =>
            instant.toUtc().subtract(const Duration(hours: 4)));
    expect(totals, {'2026-03-08': 25200});
  });

  test(
      'device unavailable, Android denial and iOS unreadable data never write zeros',
      () async {
    final store = _Store();
    addTearDown(store.events.close);
    final reader = _Reader()..present = false;
    final sync =
        WearableDailySync(store: store, reader: reader, now: () => _now);
    expect((await sync.import(WearableMetric.steps)).status,
        WearableImportStatus.unavailable);
    expect(reader.authorizations, isEmpty);
    reader.present = true;
    reader.permission = false;
    expect((await sync.import(WearableMetric.steps)).status,
        WearableImportStatus.denied);
    reader.apple = true;
    expect((await sync.import(WearableMetric.sleep)).status,
        WearableImportStatus.accessUnconfirmed);
    reader.permission = true;
    expect((await sync.import(WearableMetric.sleep)).status,
        WearableImportStatus.empty);
    reader.apple = false;
    reader.revoked = true;
    expect((await sync.import(WearableMetric.steps)).status,
        WearableImportStatus.denied);
    expect(store.batches, isEmpty);
  });

  test('switching away and back during authorization cancels the import',
      () async {
    final store = _Store();
    addTearDown(store.events.close);
    final pending = Completer<bool>();
    final reader = _Reader()..permissionResult = pending;
    final sync =
        WearableDailySync(store: store, reader: reader, now: () => _now);
    final result = sync.import(WearableMetric.steps);
    await Future<void>.delayed(Duration.zero);
    store.change('other-synthetic-owner');
    store.change('synthetic-owner');
    pending.complete(true);
    await expectLater(result, throwsA(isA<HealthSyncException>()));
    expect(reader.stepRanges, isEmpty);
    expect(store.batches, isEmpty);
  });

  test('same date in a different calendar window does not contribute', () {
    final day = WearableDay(dayOf(_now));
    final total =
        WearableTotal(day, WearableMetric.steps, 0, _now, 'health_connect')
            .toJson();
    final mismatched = {
      ...total,
      'value': 1234,
      'window_start':
          day.start.toUtc().add(const Duration(hours: 1)).toIso8601String()
    };
    final rows = wearableReadingsForDays([total, mismatched], [day]);
    expect(rows[day.date]?.steps?.value, 0);
    expect(rows[day.date]?.sleep, isNull);
  });
}
