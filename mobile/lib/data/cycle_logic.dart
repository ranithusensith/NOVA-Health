import 'profile_models.dart';

/// What the cycle screen shows. All dates are estimates.
class CycleSummary {
  const CycleSummary({
    required this.avgLength,
    required this.isEstimate,
    required this.onPeriod,
    this.lastStart,
    this.nextStart,
    this.cycleDay,
    this.daysUntilNext,
    this.irregular = false,
  });

  /// Average days between period starts (28 until two periods are logged).
  final int avgLength;

  /// True while [avgLength] is the 28-day default, not the user's own average.
  final bool isEstimate;

  final bool onPeriod;
  final DateTime? lastStart;
  final DateTime? nextStart;
  final int? cycleDay;

  /// Negative when the expected date has passed.
  final int? daysUntilNext;

  /// Cycle lengths vary a lot, so predictions are less reliable.
  final bool irregular;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Pure function (easy to test). [periods] may be in any order.
CycleSummary summarizeCycle(List<PeriodRecord> periods, DateTime today) {
  final t = _day(today);
  if (periods.isEmpty) {
    return const CycleSummary(avgLength: 28, isEstimate: true, onPeriod: false);
  }

  final sorted = [...periods]..sort((a, b) => a.start.compareTo(b.start));
  final starts = [for (final p in sorted) _day(p.start)];

  // Gaps between consecutive starts; ignore impossible values (missed logs, typos).
  final gaps = <int>[];
  for (var i = 1; i < starts.length; i++) {
    final g = starts[i].difference(starts[i - 1]).inDays;
    if (g >= 15 && g <= 60) gaps.add(g);
  }
  final recent = gaps.length > 6 ? gaps.sublist(gaps.length - 6) : gaps;
  final isEstimate = recent.isEmpty;
  final avg = isEstimate ? 28 : (recent.reduce((a, b) => a + b) / recent.length).round();

  var irregular = false;
  if (recent.length >= 2) {
    final lo = recent.reduce((a, b) => a < b ? a : b);
    final hi = recent.reduce((a, b) => a > b ? a : b);
    irregular = hi - lo > 9;
  }

  final latest = sorted.last;
  final last = starts.last;
  final sinceStart = t.difference(last).inDays;
  final onPeriod = latest.end == null && sinceStart >= 0 && sinceStart < 10;
  final next = DateTime(last.year, last.month, last.day + avg);

  return CycleSummary(
    avgLength: avg,
    isEstimate: isEstimate,
    onPeriod: onPeriod,
    lastStart: last,
    nextStart: next,
    cycleDay: sinceStart >= 0 ? sinceStart + 1 : null,
    daysUntilNext: next.difference(t).inDays,
    irregular: irregular,
  );
}
