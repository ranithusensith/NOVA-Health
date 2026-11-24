import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/care_models.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

MedicationRecord med(String id, List<String> times, {DateTime? start, DateTime? end, String status = 'confirmed'}) =>
    MedicationRecord(id: id, name: 'Med $id', dosage: '10 mg', times: times, startDate: start, endDate: end, status: status);

void main() {
  group('parseClock', () {
    test('reads HH:MM and Postgres HH:MM:SS', () {
      expect(parseClock('08:30'), (hour: 8, minute: 30));
      expect(parseClock('21:05:00'), (hour: 21, minute: 5));
    });
    test('rejects bad values', () {
      expect(parseClock('25:00'), isNull);
      expect(parseClock('nope'), isNull);
      expect(parseClock('8'), isNull);
    });
  });

  test('MedicationRecord.fromJson normalises and sorts times', () {
    final m = MedicationRecord.fromJson({
      'id': 7,
      'name': 'Cetirizine',
      'dosage': '10 mg',
      'times': ['21:00:00', '08:00', 'bad'],
      'start_date': '2026-11-01',
      'end_date': null,
      'status': 'confirmed',
    });
    expect(m.id, '7');
    expect(m.times, ['08:00', '21:00']);
    expect(m.label, 'Cetirizine 10 mg');
    expect(m.startDate, DateTime(2026, 11, 1));
  });

  group('activeOn', () {
    final day = DateTime(2026, 11, 5, 12);
    test('respects start, end and ended status', () {
      expect(med('a', ['08:00'], start: DateTime(2026, 11, 1)).activeOn(day), isTrue);
      expect(med('b', ['08:00'], start: DateTime(2026, 11, 6)).activeOn(day), isFalse);
      expect(med('c', ['08:00'], end: DateTime(2026, 11, 4)).activeOn(day), isFalse);
      expect(med('d', ['08:00'], end: DateTime(2026, 11, 5)).activeOn(day), isTrue);
      expect(med('e', ['08:00'], status: 'ended').activeOn(day), isFalse);
    });
  });

  group('buildSchedule', () {
    final now = DateTime(2026, 11, 5, 14, 0);
    DoseKey keyAt(String id, int hour) => DoseOccurrence(
      accountId: 'owner', medicationId: id, at: DateTime(2026, 11, 5, hour), followsLocalClock: true,
    ).key;

    test('marks taken, missed, due and upcoming doses', () {
      final slots = buildSchedule(
        [
          med('a', ['08:00', '21:00']), // Only the selected evening dose is taken.
          med('b', ['12:00']), // 2 h late, not taken -> missed
          med('c', ['14:20']), // within 30 min -> due
        ],
        {keyAt('a', 21): 'evening-log'},
        now,
        accountId: 'owner',
      );
      expect([for (final s in slots) '${s.medication.id}@${s.at.hour}:${s.state.name}'],
          ['a@8:missed', 'b@12:missed', 'c@14:due', 'a@21:taken']);
      expect(slots.first.logId, isNull);
      expect(slots.last.logId, 'evening-log');
    });

    test('legacy logs leave matching medication slots unverified', () {
      final slots = buildSchedule(
        [med('a', ['08:00', '21:00', '21:00:00'])], {keyAt('a', 21): 'exact-log'}, now,
        accountId: 'owner', unassignedMedicationIds: {'a'},
      );
      expect(slots.map((slot) => slot.state), [DoseState.unverified, DoseState.taken]);
      expect(nextDose(slots), isNull);
    });

    test('groups doses into Morning, Afternoon and Evening', () {
      final slots = buildSchedule([med('a', ['07:00', '13:00', '19:00'])], const {}, now, accountId: 'owner');
      expect(slots.map((s) => s.period), ['Morning', 'Afternoon', 'Evening']);
    });

    test('skips medicines that are not active today', () {
      final slots = buildSchedule([med('a', ['08:00'], status: 'ended')], const {}, now, accountId: 'owner');
      expect(slots, isEmpty);
    });

    test('nextDose prefers due, then upcoming, then the latest missed', () {
      final slots = buildSchedule([med('a', ['09:00', '14:15', '20:00'])], const {}, now, accountId: 'owner');
      expect(nextDose(slots)!.at.hour, 14);

      final noneDue = buildSchedule([med('a', ['09:00', '20:00'])], const {}, now, accountId: 'owner');
      expect(nextDose(noneDue)!.at.hour, 20);

      final allMissed = buildSchedule([med('a', ['08:00', '11:00'])], const {}, now, accountId: 'owner');
      expect(nextDose(allMissed)!.at.hour, 11);

      final allTaken = buildSchedule([med('a', ['08:00'])], {keyAt('a', 8): 'log'}, now, accountId: 'owner');
      expect(nextDose(allTaken), isNull);
    });
  });

  test('daily identity follows wall time and interval identity follows the instant', () {
    tz_data.initializeTimeZones();
    final colombo = tz.getLocation('Asia/Colombo');
    final newYork = tz.getLocation('America/New_York');
    DoseOccurrence occurrence(DateTime at, {required bool daily}) => DoseOccurrence(
      accountId: 'owner', medicationId: 'a', at: at, followsLocalClock: daily,
    );
    final dailyAt = tz.TZDateTime(colombo, 2026, 11, 5, 8);
    final travelled = occurrence(tz.TZDateTime(newYork, 2026, 11, 5, 8), daily: true);
    expect(occurrence(dailyAt, daily: true).key, travelled.key);
    expect(occurrence(dailyAt, daily: true).scheduledAt, isNot(travelled.scheduledAt));
    expect(occurrence(tz.TZDateTime(colombo, 2026, 11, 6, 8), daily: true).key, isNot(travelled.key));
    expect(occurrence(dailyAt, daily: false).key,
        occurrence(tz.TZDateTime.from(dailyAt, newYork), daily: false).key);

    final repeated = [DateTime.utc(2026, 11, 1, 5, 30), DateTime.utc(2026, 11, 1, 6, 30)]
        .map((utc) => tz.TZDateTime.from(utc, newYork)).toList();
    expect(repeated.map((time) => time.hour), [1, 1]);
    expect(repeated.map((time) => occurrence(time, daily: false).key).toSet(), hasLength(2));
  });

  test('interval slot at midnight belongs to the next calendar day and PRN has no slot', () {
    final midnight = DateTime(2026, 11, 6);
    final interval = MedicationRecord(
      id: 'interval', name: 'Synthetic interval',
      prescriptionPlan: PrescriptionPlan(timing: PrescriptionTiming.interval,
        intervalMinutes: 60, firstDoseAt: midnight.subtract(const Duration(hours: 1))),
    );
    const prn = MedicationRecord(
      id: 'prn', name: 'Synthetic PRN', times: ['00:00'],
      prescriptionPlan: PrescriptionPlan(timing: PrescriptionTiming.asNeeded),
    );
    final yesterday = buildSchedule([interval, prn], {}, calendarDay(midnight, -1), accountId: 'owner');
    final today = buildSchedule([interval, prn], {}, midnight, accountId: 'owner');
    expect(yesterday.single.at.hour, 23);
    expect(today.first.at, midnight);
    expect(today.first.occurrence.key, isNot(yesterday.single.occurrence.key));
    expect(today.every((slot) => slot.medication.id == 'interval'), isTrue);
  });

  test('ymd pads dates', () {
    expect(ymd(DateTime(2026, 3, 7)), '2026-03-07');
  });
}
