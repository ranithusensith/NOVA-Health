import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/care_models.dart';
import 'package:nova_health/data/reminder_plan.dart';

Map<String, dynamic> med(String name, List<String> times,
        {String? dose, String? start, String? end}) =>
    {
      'name': name,
      'dosage': dose,
      'times': times,
      'start_date': start,
      'end_date': end
    };

void main() {
  // Saturday 25 Oct 2026, 09:00
  final now = DateTime(2026, 10, 25, 9, 0);

  test('an ongoing medicine gets dated upcoming reminders in time order', () {
    final plans = buildReminderPlan([
      med('Synthetic', ['08:00', '20:00'], dose: '500 mg')
    ], now, maxItems: 2);
    expect(plans.length, 2);
    expect(plans[0].at,
        DateTime(2026, 10, 25, 20, 0)); // 08:00 already passed, so tomorrow
    expect(plans[1].at, DateTime(2026, 10, 26, 8, 0));
    expect(plans[0].names, ['Synthetic 500 mg']);
  });

  test('a course with an end date gets one notification per day and then stops',
      () {
    final plans = buildReminderPlan([
      med('Amoxicillin', ['08:00', '20:00'],
          start: '2026-10-25', end: '2026-10-27')
    ], now);
    expect(plans.map((p) => p.at).toList(), [
      DateTime(2026, 10, 25, 20, 0),
      DateTime(2026, 10, 26, 8, 0),
      DateTime(2026, 10, 26, 20, 0),
      DateTime(2026, 10, 27, 8, 0),
      DateTime(2026, 10, 27, 20, 0),
    ]);
  });

  test('a finished course gives no reminders', () {
    expect(
        buildReminderPlan([
          med('Old', ['08:00'], end: '2026-10-24')
        ], now),
        isEmpty);
  });

  test('a course that starts in the future waits for its start date', () {
    final plans = buildReminderPlan([
      med('Later', ['08:00'], start: '2026-10-30', end: '2026-11-01')
    ], now);
    expect(plans.first.at, DateTime(2026, 10, 30, 8, 0));
    final daily = buildReminderPlan([
      med('Later daily', ['08:00'], start: '2026-10-30')
    ], now, maxDays: 1);
    expect(daily.single.at, DateTime(2026, 10, 30, 8, 0));
    expect(daily.single.at.isBefore(DateTime(2026, 10, 30)), isFalse);
  });

  test('medicines due at the same moment share one notification', () {
    final plans = buildReminderPlan([
      med('Cetirizine', ['21:00'], dose: '10 mg'),
      med('Paracetamol', ['21:00'], dose: '500 mg'),
    ], now, maxDays: 1);
    expect(plans.length, 1);
    expect(plans.single.names, ['Cetirizine 10 mg', 'Paracetamol 500 mg']);
    expect(plans.single.body(showNames: true),
        'Time to take Cetirizine 10 mg, Paracetamol 500 mg');
  });

  test('names can be hidden from the lock screen', () {
    final plan = buildReminderPlan([
      med('Synthetic private', ['21:00'], dose: '250 mg')
    ], now, maxDays: 1)
        .single;
    expect(plan.body(), 'Open NOVA Health to view your reminder.');
    expect(plan.body(showNames: true), contains('Synthetic private 250 mg'));
  });

  test('more than three names are summarised', () {
    final plan = ReminderPlan(at: now, names: ['A', 'B', 'C', 'D', 'E']);
    expect(plan.body(showNames: true), 'Time to take A, B, C and 2 more');
  });

  test('bad data is ignored', () {
    final plans = buildReminderPlan([
      med('', ['08:00']),
      med('NoTimes', []),
      med('BadTimes', ['25:00', 'abc', '8']),
      {'name': 'Missing fields'},
    ], now);
    expect(plans, isEmpty);
  });

  test('caps pending alerts and prioritizes the earliest instants', () {
    final meds = [
      med('Daily', ['07:00']),
      for (var i = 0; i < 10; i++)
        med('Course $i',
            ['0${i % 10}:30', '12:${10 + i}', '18:${10 + i}', '22:${10 + i}'],
            end: '2026-11-20'),
    ];
    final plans = buildReminderPlan(meds, now);
    expect(plans.length, 60);
    for (var i = 1; i < plans.length; i++) {
      expect(plans[i].at.isAfter(plans[i - 1].at), isTrue);
    }
  });

  test('inclusive course dates count calendar days across a month boundary',
      () {
    final leapDay = DateTime(2028, 2, 29);
    expect(inclusiveCourseEnd(leapDay, 1), leapDay);
    expect(inclusiveCourseEnd(leapDay, 3), DateTime(2028, 3, 2));
  });

  test(
      'notification preference leaves reviewed and legacy dose timelines intact',
      () {
    for (final plan in [
      null,
      {'kind': 'daily'}
    ]) {
      final row = {
        ...med('Daily', ['08:10'], start: '2026-10-25', end: '2026-10-25'),
        'prescription_plan': plan,
        'reminders_enabled': false,
      };
      final medicine = MedicationRecord.fromJson(row);
      expect(buildSchedule([medicine], {}, now, accountId: 'owner').single.at,
          DateTime(2026, 10, 25, 8, 10));
      expect(medicine.dosesOn(DateTime(2026, 10, 26)), isEmpty);
      expect(buildReminderPlan([row], now), isEmpty);
    }
  });

  test(
      'PRN and no-fixed-schedule rows do not generate doses even with leftover clock times',
      () {
    for (final kind in ['as_needed', 'unscheduled']) {
      final row = {
        ...med('Unscheduled', ['20:00']),
        'prescription_plan': {'kind': kind},
      };
      expect(MedicationRecord.fromJson(row).dosesOn(now), isEmpty);
      expect(buildReminderPlan([row], now), isEmpty);
    }
  });

  test(
      'non-divisor intervals continue across midnight and stop after the inclusive last day',
      () {
    final first = DateTime(2026, 10, 25, 22);
    final row = {
      ...med('Interval', [], start: '2026-10-25', end: '2026-10-26'),
      'prescription_plan': {
        'kind': 'interval',
        'first_dose_at': first.toUtc().toIso8601String(),
        'interval_minutes': 420,
      },
    };
    final notices = buildReminderPlan([row], now);
    final expected = [
      for (var i = 0; i < 4; i++) first.add(Duration(hours: 7 * i))
    ];
    expect(notices.map((plan) => plan.at), expected);
    final medicine = MedicationRecord.fromJson(row);
    expect(medicine.dosesOn(DateTime(2026, 10, 26)), expected.skip(1));
    expect(medicine.dosesOn(DateTime(2026, 10, 27)), isEmpty);
  });

  test(
      'a future scanned daily schedule uses dated notifications so it cannot fire early',
      () {
    final row = {
      ...med('Future scan', ['19:00'], start: '2026-10-27'),
      'prescription_plan': {'kind': 'daily'},
    };
    final notices = buildReminderPlan([row], now, maxDays: 2);
    expect(notices.map((plan) => plan.at),
        [DateTime(2026, 10, 27, 19), DateTime(2026, 10, 28, 19)]);
  });

  test('replanning after a restart does not replay missed or finished doses',
      () {
    final row = med('Synthetic', ['00:05', '23:59'],
        start: '2026-10-25', end: '2026-10-26');
    final restart = DateTime(2026, 10, 26, 0, 10);
    expect(buildReminderPlan([row], restart).map((p) => p.at),
        [DateTime(2026, 10, 26, 23, 59)]);
    expect(buildReminderPlan([row], DateTime(2026, 10, 27)), isEmpty);
  });

  test(
      'daily reminders keep civil time through spring DST in a DST-observing run',
      () {
    final before = DateTime(2026, 3, 7, 8);
    final plans = buildReminderPlan([
      med('Synthetic', ['09:00'], end: '2026-03-09')
    ], before);
    expect(plans.map((p) => p.at.hour), [9, 9, 9]);
    if (Platform.environment['TZ'] == 'America/New_York') {
      expect(plans[0].at.toUtc(), DateTime.utc(2026, 3, 7, 14));
      expect(plans[1].at.toUtc(), DateTime.utc(2026, 3, 8, 13));
      expect(plans[1].at.difference(plans[0].at), const Duration(hours: 23));
    }
  });

  test(
      'fall DST interval occurrences remain distinct and share the timeline instants',
      () {
    final before = DateTime(2026, 11, 1);
    final first = before.toUtc().add(const Duration(minutes: 90));
    final row = {
      ...med('Synthetic', [], start: '2026-11-01', end: '2026-11-01'),
      'prescription_plan': {
        'kind': 'interval',
        'first_dose_at': first.toIso8601String(),
        'interval_minutes': 60
      },
    };
    final planned = buildReminderPlan([row], before, maxItems: 2);
    final scheduled = buildSchedule(
        [MedicationRecord.fromJson(row)], {}, before,
        accountId: 'owner');
    expect(planned.map((p) => p.at.toUtc()),
        scheduled.take(2).map((s) => s.occurrence.scheduledAt));
    expect(planned[1].at.difference(planned[0].at), const Duration(hours: 1));
    if (Platform.environment['TZ'] == 'America/New_York') {
      expect(planned.map((p) => p.at.hour), [1, 1]);
      expect(planned[0].at.timeZoneOffset, isNot(planned[1].at.timeZoneOffset));
    }
  });
}
