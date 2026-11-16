import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/care_models.dart';

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

    test('marks taken, missed, due and upcoming doses', () {
      final slots = buildSchedule(
        [
          med('a', ['08:00', '21:00']), // 08:00 taken via log, 21:00 upcoming
          med('b', ['12:00']), // 2 h late, not taken -> missed
          med('c', ['14:20']), // within 30 min -> due
        ],
        {'a': 1},
        now,
      );
      expect([for (final s in slots) '${s.medication.id}@${s.at.hour}:${s.state.name}'],
          ['a@8:taken', 'b@12:missed', 'c@14:due', 'a@21:upcoming']);
    });

    test('groups doses into Morning, Afternoon and Evening', () {
      final slots = buildSchedule([med('a', ['07:00', '13:00', '19:00'])], const {}, now);
      expect(slots.map((s) => s.period), ['Morning', 'Afternoon', 'Evening']);
    });

    test('skips medicines that are not active today', () {
      final slots = buildSchedule([med('a', ['08:00'], status: 'ended')], const {}, now);
      expect(slots, isEmpty);
    });

    test('nextDose prefers due, then upcoming, then the latest missed', () {
      final slots = buildSchedule([med('a', ['09:00', '14:15', '20:00'])], const {}, now);
      expect(nextDose(slots)!.at.hour, 14);

      final noneDue = buildSchedule([med('a', ['09:00', '20:00'])], const {}, now);
      expect(nextDose(noneDue)!.at.hour, 20);

      final allMissed = buildSchedule([med('a', ['08:00', '11:00'])], const {}, now);
      expect(nextDose(allMissed)!.at.hour, 11);

      final allTaken = buildSchedule([med('a', ['08:00'])], {'a': 1}, now);
      expect(nextDose(allTaken), isNull);
    });
  });

  test('ymd pads dates', () {
    expect(ymd(DateTime(2026, 3, 7)), '2026-03-07');
  });
}
