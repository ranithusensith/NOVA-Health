import 'package:supabase_flutter/supabase_flutter.dart';

import 'care_models.dart';

enum WearableMetric {
  steps('Steps'),
  sleep('Sleep');

  const WearableMetric(this.label);
  final String label;
}

class WearableDay {
  WearableDay(DateTime date)
      : start = dayOf(date),
        end = calendarDay(date, 1);
  final DateTime start;
  final DateTime end;

  String get date => ymd(start);
}

class AsleepInterval {
  const AsleepInterval(this.start, this.end);
  final DateTime start;
  final DateTime end;
}

/// Overlapping asleep intervals contribute once. Gaps of up to 90 minutes
/// join the wake date of a sleep episode without counting the gap as sleep.
Map<String, int> sleepSecondsByWakeDay(
  List<AsleepInterval> samples,
  DateTime firstDay,
  DateTime capturedAt, {
  DateTime Function(DateTime)? localize,
}) {
  final toLocal = localize ?? (instant) => instant.toLocal();
  final first = ymd(firstDay);
  final last = ymd(toLocal(capturedAt));
  final ordered = samples
      .where((interval) =>
          interval.start.isBefore(interval.end) &&
          !interval.end.isAfter(capturedAt))
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  final totals = <String, int>{};
  DateTime? episodeEnd;
  var duration = Duration.zero;
  void finish() {
    if (episodeEnd == null) return;
    final wakeDay = ymd(toLocal(episodeEnd));
    if (wakeDay.compareTo(first) >= 0 &&
        wakeDay.compareTo(last) <= 0 &&
        duration.inSeconds > 0) {
      totals.update(wakeDay, (value) => value + duration.inSeconds,
          ifAbsent: () => duration.inSeconds);
    }
  }

  for (final interval in ordered) {
    final previous = episodeEnd;
    if (previous == null ||
        interval.start.difference(previous) > const Duration(minutes: 90)) {
      finish();
      duration = interval.end.difference(interval.start);
      episodeEnd = interval.end;
    } else if (interval.end.isAfter(previous)) {
      final start =
          interval.start.isBefore(previous) ? previous : interval.start;
      duration += interval.end.difference(start);
      episodeEnd = interval.end;
    }
  }
  finish();
  totals.removeWhere((_, seconds) => seconds > 86400);
  return totals;
}

class WearableTotal {
  const WearableTotal(
      this.day, this.metric, this.value, this.capturedAt, this.source);
  final WearableDay day;
  final WearableMetric metric;
  final int value;
  final DateTime capturedAt;
  final String source;

  Map<String, Object> toJson() => {
        'metric': metric.name,
        'local_date': day.date,
        'window_start': day.start.toUtc().toIso8601String(),
        'window_end': day.end.toUtc().toIso8601String(),
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'value': value,
        'source': source,
      };
}

class WearableObservation {
  const WearableObservation(this.value, this.source);
  final int value;
  final String source;

  String get sourceLabel =>
      source == 'apple_health' ? 'Apple Health' : 'Health Connect';
}

class WearableDailyReadings {
  const WearableDailyReadings({this.steps, this.sleep});
  final WearableObservation? steps;
  final WearableObservation? sleep;

  double? get sleepHours => sleep == null ? null : sleep!.value / 3600;
}

Map<String, WearableDailyReadings> wearableReadingsForDays(
  List<Map<String, dynamic>> rows,
  List<WearableDay> days,
) {
  final windows = {for (final day in days) day.date: day};
  final values = <String, Map<String, WearableObservation>>{};
  for (final row in rows) {
    final date = row['local_date'];
    final day = windows[date];
    final metric = row['metric'];
    final value = row['value'];
    final source = row['source'];
    if (date is! String ||
        day == null ||
        metric is! String ||
        value is! int ||
        (source != 'apple_health' && source != 'health_connect')) {
      continue;
    }
    if (metric == 'steps'
        ? value < 0 || value > 1000000
        : metric != 'sleep' || value < 1 || value > 86400) {
      continue;
    }
    DateTime? instant(String key) {
      final input = row[key];
      final parsed = input is String ? DateTime.tryParse(input) : null;
      return parsed?.isUtc == true ? parsed : null;
    }

    if (instant('window_start')?.isAtSameMomentAs(day.start) != true ||
        instant('window_end')?.isAtSameMomentAs(day.end) != true) {
      continue;
    }
    (values[date] ??= {})[metric] =
        WearableObservation(value, source as String);
  }
  return {
    for (final entry in values.entries)
      entry.key: WearableDailyReadings(
          steps: entry.value['steps'], sleep: entry.value['sleep'])
  };
}

abstract interface class WearableImportStore {
  String? get accountId;
  Stream<String?> get accountChanges;
  Future<int> save(List<WearableTotal> totals, String expectedAccount);
}

class WearableDailyRepository implements WearableImportStore {
  WearableDailyRepository({SupabaseClient? client}) : _client = client;
  static final instance = WearableDailyRepository();

  final SupabaseClient? _client;
  SupabaseClient get _db => _client ?? Supabase.instance.client;

  @override
  String? get accountId => _db.auth.currentUser?.id;

  @override
  Stream<String?> get accountChanges =>
      _db.auth.onAuthStateChange.map((event) => event.session?.user.id);

  @override
  Future<int> save(List<WearableTotal> totals, String expectedAccount) async {
    if (accountId != expectedAccount) {
      throw StateError('Wearable import account changed.');
    }
    final result = await _db.rpc('save_wearable_daily_totals', params: {
      'expected_account': expectedAccount,
      'totals': [for (final day in totals) day.toJson()],
    });
    if (accountId != expectedAccount) {
      throw StateError('Wearable import account changed.');
    }
    if (result is! int || result < 0 || result > totals.length) {
      throw StateError('Wearable import could not be verified.');
    }
    return result;
  }

  Future<Map<String, WearableDailyReadings>> read(
      List<WearableDay> days, String owner) async {
    if (days.isEmpty || owner != accountId) return const {};
    try {
      final rows = await _db
          .from('wearable_daily_totals')
          .select('metric,local_date,window_start,window_end,source,value')
          .eq('user_id', owner)
          .gte('local_date', days.first.date)
          .lte('local_date', days.last.date)
          .limit(500);
      if (owner != accountId || rows.length >= 500) return const {};
      return wearableReadingsForDays(rows, days);
    } catch (_) {
      return const {};
    }
  }
}
