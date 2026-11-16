import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/cycle_logic.dart';
import 'package:nova_health/data/profile_models.dart';

PeriodRecord period(String start, [String? end]) => PeriodRecord(
      id: start,
      start: DateTime.parse(start),
      end: end == null ? null : DateTime.parse(end),
    );

void main() {
  test('no periods: typical 28 days, no dates', () {
    final s = summarizeCycle(const [], DateTime(2026, 10, 10));
    expect(s.avgLength, 28);
    expect(s.isEstimate, isTrue);
    expect(s.lastStart, isNull);
    expect(s.nextStart, isNull);
    expect(s.onPeriod, isFalse);
  });

  test('two periods 28 days apart give an own average and a next date', () {
    final s = summarizeCycle(
      [period('2026-09-01', '2026-09-05'), period('2026-09-29', '2026-10-03')],
      DateTime(2026, 10, 10),
    );
    expect(s.avgLength, 28);
    expect(s.isEstimate, isFalse);
    expect(s.nextStart, DateTime(2026, 10, 27));
    expect(s.daysUntilNext, 17);
    expect(s.cycleDay, 12);
    expect(s.onPeriod, isFalse);
    expect(s.irregular, isFalse);
  });

  test('a period with no end date that started recently is in progress', () {
    final s = summarizeCycle([period('2026-10-08')], DateTime(2026, 10, 10));
    expect(s.onPeriod, isTrue);
    expect(s.cycleDay, 3);
    expect(s.isEstimate, isTrue);
  });

  test('impossible gaps (missed logs) are ignored', () {
    final s = summarizeCycle(
      [
        period('2026-01-01', '2026-01-05'),
        period('2026-01-29', '2026-02-02'),
        period('2026-04-15', '2026-04-19'), // 76 days later: ignored
        period('2026-05-13', '2026-05-17'),
      ],
      DateTime(2026, 5, 20),
    );
    expect(s.avgLength, 28);
    expect(s.isEstimate, isFalse);
  });

  test('very different cycle lengths are flagged as irregular', () {
    final s = summarizeCycle(
      [
        period('2026-03-01', '2026-03-05'),
        period('2026-03-25', '2026-03-29'), // 24 days
        period('2026-04-30', '2026-05-04'), // 36 days
      ],
      DateTime(2026, 5, 10),
    );
    expect(s.avgLength, 30);
    expect(s.irregular, isTrue);
  });

  test('a late period gives a negative daysUntilNext', () {
    final s = summarizeCycle(
      [period('2026-09-01', '2026-09-05'), period('2026-09-29', '2026-10-03')],
      DateTime(2026, 10, 30),
    );
    expect(s.daysUntilNext, -3);
  });
}
