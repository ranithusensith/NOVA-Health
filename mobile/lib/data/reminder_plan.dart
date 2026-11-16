/// One notification to schedule. Pure data, so it can be unit tested without a phone.
class ReminderPlan {
  const ReminderPlan({required this.at, required this.daily, required this.names});

  /// Local clock time of the first (or only) notification.
  final DateTime at;

  /// Repeats every day at this time (medicines with no end date).
  final bool daily;

  /// Medicines due at this time, e.g. "Amoxicillin 500 mg".
  final List<String> names;

  String get title => 'Medicine reminder';

  String body({required bool showNames}) {
    if (!showNames) return "It's time for your medicine. Open NOVA Health for details.";
    if (names.length <= 3) return 'Time to take ${names.join(', ')}';
    return 'Time to take ${names.take(3).join(', ')} and ${names.length - 3} more';
  }
}

(int, int)? _parseHm(Object? value) {
  if (value is! String) return null;
  final parts = value.trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return (h, m);
}

DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final d = DateTime.tryParse(value);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// Works out which notifications to schedule from the user's confirmed medicines.
///
/// - No end date: one notification that repeats daily at each time.
/// - With an end date: one notification per day until the end date (at most [maxDays] days ahead),
///   so reminders stop on their own when the course finishes.
/// - Medicines due at the same moment share one notification.
/// - Capped at [maxItems] (iOS keeps at most 64 pending notifications).
List<ReminderPlan> buildReminderPlan(
  List<Map<String, dynamic>> meds,
  DateTime now, {
  int maxItems = 60,
  int maxDays = 30,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final groups = <String, List<String>>{};
  final times = <String, DateTime>{};
  final repeats = <String, bool>{};

  void add(DateTime at, bool daily, String label) {
    final key = '${daily ? 'd' : 'o'}|${at.toIso8601String()}';
    final list = groups.putIfAbsent(key, () => []);
    if (!list.contains(label)) list.add(label);
    times[key] = at;
    repeats[key] = daily;
  }

  for (final m in meds) {
    final name = ((m['name'] as String?) ?? '').trim();
    if (name.isEmpty) continue;
    final dose = ((m['dosage'] as String?) ?? '').trim();
    final label = dose.isEmpty ? name : '$name $dose';
    final start = _date(m['start_date']);
    final end = _date(m['end_date']);
    if (end != null && end.isBefore(today)) continue;

    for (final t in (m['times'] as List? ?? const [])) {
      final hm = _parseHm(t);
      if (hm == null) continue;

      if (end == null) {
        var first = DateTime(today.year, today.month, today.day, hm.$1, hm.$2);
        if (start != null && start.isAfter(today)) {
          first = DateTime(start.year, start.month, start.day, hm.$1, hm.$2);
        }
        if (!first.isAfter(now)) {
          first = DateTime(first.year, first.month, first.day + 1, hm.$1, hm.$2);
        }
        add(first, true, label);
      } else {
        var day = (start != null && start.isAfter(today)) ? start : today;
        for (var i = 0; i < maxDays && !day.isAfter(end); i++) {
          final at = DateTime(day.year, day.month, day.day, hm.$1, hm.$2);
          if (at.isAfter(now)) add(at, false, label);
          day = DateTime(day.year, day.month, day.day + 1);
        }
      }
    }
  }

  final plans = [
    for (final k in groups.keys) ReminderPlan(at: times[k]!, daily: repeats[k]!, names: groups[k]!),
  ];
  plans.sort((a, b) {
    if (a.daily != b.daily) return a.daily ? -1 : 1;
    return a.at.compareTo(b.at);
  });
  return plans.take(maxItems).toList();
}
