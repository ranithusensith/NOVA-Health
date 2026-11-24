import 'package:supabase_flutter/supabase_flutter.dart';

import 'care_models.dart';

const dailyMoods = ['bad', 'low', 'ok', 'good', 'great'];

class DailyGoals {
  const DailyGoals({this.waterMl, this.sleepHours});

  factory DailyGoals.fromJson(Map<String, dynamic>? row) => DailyGoals(
        waterMl: _integer(row?['water_goal_ml'], minimum: 1, maximum: 20000),
        sleepHours:
            _number(row?['sleep_goal_hours'], minimum: 0.1, maximum: 24),
      );

  final int? waterMl;
  final double? sleepHours;
}

double? _number(Object? value,
        {double minimum = 0, double maximum = double.infinity}) =>
    value is num && value.isFinite && value >= minimum && value <= maximum
        ? value.toDouble()
        : null;

int? _integer(Object? value, {int minimum = 0, int? maximum}) =>
    value is int && value >= minimum && (maximum == null || value <= maximum)
        ? value
        : null;

int? dailyTotal(List<Map<String, dynamic>>? rows, String key) {
  if (rows == null || rows.isEmpty) return null;
  var total = 0;
  for (final row in rows) {
    final value = _integer(row[key]);
    if (value == null) return null;
    total += value;
  }
  return total;
}

T? latestDailyValue<T>(
    List<Map<String, dynamic>>? rows, String key, T? Function(Object?) parse) {
  DateTime? latest;
  final values = <T?>{};
  for (final row in rows ?? const <Map<String, dynamic>>[]) {
    final timestamp = row['logged_at'];
    final instant = timestamp is String ? DateTime.tryParse(timestamp) : null;
    if (instant == null || !instant.isUtc) return null;
    if (latest == null || instant.isAfter(latest)) {
      latest = instant;
      values.clear();
    }
    if (instant.isAtSameMomentAs(latest)) values.add(parse(row[key]));
  }
  return values.length == 1 ? values.single : null;
}

double? dailySleep(List<Map<String, dynamic>>? rows) =>
    latestDailyValue(rows, 'hours', (value) => _number(value, maximum: 24));

int? dailyMood(List<Map<String, dynamic>>? rows) =>
    latestDailyValue(rows, 'mood', (value) {
      final index = dailyMoods.indexOf(value is String ? value : '');
      return index < 0 ? null : index;
    });

/// Today's date and the UTC offsets at local midnights for a maximum 30-day query.
Map<String, dynamic> deviceCalendar(DateTime now) {
  final today = dayOf(now.toLocal());
  return {
    'today': ymd(today),
    'midnight_offsets': [
      for (var day = -29; day <= 1; day++) localBoundaryOffset(today, day),
    ],
  };
}

/// Express the actual UTC boundary as a nominal local midnight offset.
int localBoundaryOffset(DateTime day, [int dayOffset = 0]) =>
    DateTime.utc(day.year, day.month, day.day + dayOffset)
        .difference(calendarDay(day, dayOffset).toUtc())
        .inMinutes;

/// Half-open local calendar windows, even on days with an offset change.
({DateTime start, DateTime end}) dailyWindow(DateTime day, {int days = 1}) =>
    (start: dayOf(day), end: calendarDay(day, days));

Future<List<Map<String, dynamic>>?> dailyRows(
  SupabaseClient db,
  String owner,
  String table,
  String column,
  DateTime from,
  DateTime to,
) async {
  try {
    var query = db
        .from(table)
        .select('$column,logged_at')
        .eq('user_id', owner)
        .gte('logged_at', from.toUtc().toIso8601String())
        .lt('logged_at', to.toUtc().toIso8601String());
    if (table == 'meal_logs') query = query.eq('status', 'confirmed');
    final rows = await query.order('logged_at').order('id').limit(500);
    return rows.length < 500 ? rows : null;
  } on PostgrestException {
    return null;
  } on Exception {
    return null;
  }
}

Map<DateTime, List<Map<String, dynamic>>>? bucketDailyRows(
    List<Map<String, dynamic>>? rows) {
  if (rows == null) return null;
  final days = <DateTime, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    final timestamp = row['logged_at'];
    final instant = timestamp is String ? DateTime.tryParse(timestamp) : null;
    if (instant == null || !instant.isUtc) return null;
    (days[dayOf(instant.toLocal())] ??= []).add(row);
  }
  return days;
}

/// Numeric input to a tracking comparison. A fluid target can be a cap, so
/// recorded water is never a component. Self-reported mood is shown separately.
int? trackingScore(DayStats day) {
  final sleep = day.sleepHours;
  final goal = day.sleepGoalHours;
  final parts = [
    if (sleep != null && goal != null && goal > 0)
      (sleep / goal).clamp(0.0, 1.0),
    if (day.dosesScheduled > 0 &&
        day.dosesTaken > 0 &&
        day.unassignedDoseLogs == 0)
      (day.dosesTaken / day.dosesScheduled).clamp(0.0, 1.0),
  ];
  return parts.isEmpty
      ? null
      : (parts.reduce((a, b) => a + b) / parts.length * 100).round();
}
