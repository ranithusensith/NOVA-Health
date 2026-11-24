import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/care_models.dart';
import 'package:nova_health/data/daily_metrics.dart';
import 'package:nova_health/data/scan_models.dart';

void main() {
  final day = DateTime(2026, 3, 8);

  test('the latest sleep total wins in either order and ties stay unknown', () {
    const older = {'hours': 8, 'logged_at': '2026-03-08T06:30:00Z'};
    const latest = {'hours': 6.5, 'logged_at': '2026-03-08T07:00:00Z'};
    expect(dailySleep([older, latest]), 6.5);
    expect(dailySleep([latest, older]), 6.5);
    expect(
        dailySleep([
          latest,
          {...latest, 'hours': 8}
        ]),
        isNull);
    expect(
        dailySleep([
          older,
          {...latest, 'hours': null}
        ]),
        isNull);
  });

  test('measurements at local midnight enter the new day', () {
    final window = dailyWindow(day);
    final start = window.start.toUtc();
    final rows = bucketDailyRows([
      {
        'amount_ml': 200,
        'logged_at':
            start.subtract(const Duration(microseconds: 1)).toIso8601String()
      },
      {'amount_ml': 400, 'logged_at': start.toIso8601String()},
      {'amount_ml': 300, 'logged_at': window.end.toUtc().toIso8601String()},
    ])!;
    expect(window.end, calendarDay(day, 1));
    if (Platform.environment['TZ'] == 'America/New_York') {
      expect(window.end.toUtc().difference(start), const Duration(hours: 23));
      expect(localBoundaryOffset(day), -300);
      expect(localBoundaryOffset(day, 1), -240);
    }
    expect(dailyTotal(rows[calendarDay(day, -1)], 'amount_ml'), 200);
    expect(dailyTotal(rows[day], 'amount_ml'), 400);
    expect(dailyTotal(rows[window.end], 'amount_ml'), 300);
    final offsets = deviceCalendar(day)['midnight_offsets'] as List<int>;
    expect(offsets.length, 31);
    expect(DateTime.utc(2026, 3, 8).subtract(Duration(minutes: offsets[29])),
        start);
  });

  test('missing, partial and explicitly zero values are distinct', () {
    expect(dailyTotal(null, 'calories'), isNull);
    expect(dailyTotal([], 'calories'), isNull);
    expect(
        dailyTotal([
          {'calories': 250},
          {'calories': null}
        ], 'calories'),
        isNull);
    expect(
        dailyTotal([
          {'calories': 0}
        ], 'calories'),
        0);
    expect(
        FoodScan.fromJson({'description': 'Synthetic meal'}).calories, isNull);
    expect(FoodScan.fromJson({'calories': 0}).calories, 0);
  });

  test(
      'goals are optional and score ignores restricted or conflicting water targets',
      () {
    const empty = DailyGoals();
    final restricted =
        DailyGoals.fromJson({'water_goal_ml': 750, 'sleep_goal_hours': 8});
    expect(empty.waterMl, isNull);
    expect(restricted.waterMl, 750);
    expect(trackingScore(DayStats(day: day, waterMl: 800, waterGoalMl: 750)),
        isNull);
    final belowLimit = trackingScore(DayStats(
        day: day,
        waterMl: 700,
        waterGoalMl: 750,
        sleepHours: 6,
        sleepGoalHours: 8));
    final aboveLimit = trackingScore(DayStats(
        day: day,
        waterMl: 900,
        waterGoalMl: 750,
        sleepHours: 6,
        sleepGoalHours: 8));
    expect(belowLimit, 75);
    expect(aboveLimit, belowLimit);
    expect(trackingScore(DayStats(day: day, sleepHours: 6, sleepGoalHours: 6)),
        100);
    expect(
        trackingScore(
            DayStats(day: day, dosesScheduled: 2, unassignedDoseLogs: 1)),
        isNull);
    expect(trackingScore(DayStats(day: day, dosesScheduled: 2, dosesTaken: 1)),
        50);
  });
}
