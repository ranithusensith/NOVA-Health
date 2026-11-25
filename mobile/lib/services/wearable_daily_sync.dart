import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

import '../data/care_models.dart';
import '../data/health_repository.dart';
import '../data/wearable_daily.dart';
import 'health_sync.dart' show HealthSyncException;

enum WearableImportStatus {
  unavailable,
  denied,
  accessUnconfirmed,
  empty,
  imported
}

class WearableImportResult {
  const WearableImportResult(this.status, {this.found = 0, this.saved = 0});
  final WearableImportStatus status;
  final int found;
  final int saved;
}

abstract interface class WearableDailyReader {
  bool get apple;
  String get source;
  Future<bool> available();
  Future<bool> authorize(WearableMetric metric);
  Future<int?> steps(DateTime start, DateTime end);
  Future<List<AsleepInterval>> asleep(DateTime start, DateTime end);
}

class PlatformWearableDailyReader implements WearableDailyReader {
  PlatformWearableDailyReader({Health? health, TargetPlatform? platform})
      : _health = health ?? Health(),
        _platform = platform ?? defaultTargetPlatform;

  final Health _health;
  final TargetPlatform _platform;
  static const _healthKit = MethodChannel('nova_health/healthkit');
  static const _healthConnect = MethodChannel('nova_health/health_connect');
  bool _configured = false;

  @override
  bool get apple => _platform == TargetPlatform.iOS;
  @override
  String get source => apple ? 'apple_health' : 'health_connect';

  MethodChannel get _channel => apple ? _healthKit : _healthConnect;

  @override
  Future<bool> available() async {
    if (kIsWeb || (!apple && _platform != TargetPlatform.android)) return false;
    return apple
        ? await _healthKit.invokeMethod<bool>('isHealthDataAvailable') == true
        : _health.isHealthConnectAvailable();
  }

  @override
  Future<bool> authorize(WearableMetric metric) async {
    if (!_configured) {
      await _health.configure();
      _configured = true;
    }
    final types = [
      switch (metric) {
        WearableMetric.steps => HealthDataType.STEPS,
        WearableMetric.sleep =>
          apple ? HealthDataType.SLEEP_ASLEEP : HealthDataType.SLEEP_SESSION,
      }
    ];
    const read = [HealthDataAccess.READ];
    if (!apple &&
        await _health.hasPermissions(types, permissions: read) == true) {
      return true;
    }
    return _health.requestAuthorization(types, permissions: read);
  }

  Map<String, int> _bounds(DateTime start, DateTime end) => {
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch
      };

  @override
  Future<int?> steps(DateTime start, DateTime end) => _channel
      .invokeMethod<int>('readSteps', _bounds(start, end))
      .timeout(const Duration(seconds: 15));

  @override
  Future<List<AsleepInterval>> asleep(DateTime start, DateTime end) async {
    final rows = await _channel
        .invokeListMethod<Map>('readAsleep', _bounds(start, end))
        .timeout(const Duration(seconds: 15));
    if (rows == null) throw const FormatException('Could not read sleep.');
    return [
      for (final row in rows)
        AsleepInterval(
          DateTime.fromMillisecondsSinceEpoch(row['start'] as int, isUtc: true),
          DateTime.fromMillisecondsSinceEpoch(row['end'] as int, isUtc: true),
        )
    ];
  }
}

/// Foreground import of one requested metric. Read access never implies consent
/// to send data to the Assistant, and an empty read never overwrites saved data.
class WearableDailySync {
  WearableDailySync(
      {WearableDailyReader? reader,
      WearableImportStore? store,
      DateTime Function()? now})
      : _reader = reader ?? PlatformWearableDailyReader(),
        _store = store ?? WearableDailyRepository.instance,
        _now = now ?? DateTime.now;

  static final instance = WearableDailySync();
  final WearableDailyReader _reader;
  final WearableImportStore _store;
  final DateTime Function() _now;

  Future<WearableImportResult> import(WearableMetric metric) async {
    final owner = _store.accountId;
    if (owner == null) {
      throw HealthSyncException('Sign in to NOVA before importing data.');
    }
    var changed = false;
    final subscription = _store.accountChanges.listen((account) {
      if (account != owner) changed = true;
    });
    void checkAccount() {
      if (changed || _store.accountId != owner) {
        throw HealthSyncException(
            'Your NOVA account changed. Start a new import from the account that should receive the data.');
      }
    }

    try {
      final results = <WearableTotal>[];
      try {
        final available = await _reader.available();
        checkAccount();
        if (!available) {
          return const WearableImportResult(WearableImportStatus.unavailable);
        }
        final allowed = await _reader.authorize(metric);
        checkAccount();
        if (!allowed) {
          return WearableImportResult(_reader.apple
              ? WearableImportStatus.accessUnconfirmed
              : WearableImportStatus.denied);
        }

        final capturedAt = _now().toLocal();
        final first = calendarDay(capturedAt, -6);
        final windows = [
          for (var i = 0; i < 7; i++) WearableDay(calendarDay(first, i))
        ];
        final sleep = metric == WearableMetric.sleep
            ? sleepSecondsByWakeDay(
                await _reader.asleep(calendarDay(first, -2), capturedAt),
                first,
                capturedAt)
            : const <String, int>{};

        for (final day in windows) {
          checkAccount();
          final end = day.end.isBefore(capturedAt) ? day.end : capturedAt;
          if (!day.start.isBefore(end) ||
              day.end.difference(day.start).inHours < 21 ||
              day.end.difference(day.start) > const Duration(hours: 27)) {
            continue;
          }
          final value = metric == WearableMetric.steps
              ? await _reader.steps(day.start, end)
              : sleep[day.date];
          checkAccount();
          if (value != null && value >= 0 && value <= 1000000) {
            results.add(
                WearableTotal(day, metric, value, capturedAt, _reader.source));
          }
        }
      } on HealthSyncException {
        rethrow;
      } on PlatformException catch (error) {
        checkAccount();
        return WearableImportResult(
            !_reader.apple && error.code == 'HEALTH_READ_DENIED'
                ? WearableImportStatus.denied
                : WearableImportStatus.unavailable);
      } catch (_) {
        checkAccount();
        return const WearableImportResult(WearableImportStatus.unavailable);
      }

      checkAccount();
      if (results.isEmpty) {
        return const WearableImportResult(WearableImportStatus.empty);
      }
      final int saved;
      try {
        saved = await _store.save(results, owner);
      } catch (_) {
        checkAccount();
        throw HealthSyncException(
            'Could not verify the import. Check your NOVA history before trying again.');
      }
      checkAccount();
      if (saved > 0) HealthRepository.notifyChanged();
      return WearableImportResult(WearableImportStatus.imported,
          found: results.length, saved: saved);
    } finally {
      await subscription.cancel();
    }
  }
}
