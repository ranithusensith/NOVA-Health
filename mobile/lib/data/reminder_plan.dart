import 'care_models.dart';

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

/// Works out which notifications to schedule from the user's confirmed medicines.
///
/// - Legacy ongoing medicines retain their repeating notifications.
/// - Reviewed schedules use dated notifications, including across offset changes.
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
    final key = '${daily ? 'd' : 'o'}|${at.toUtc().toIso8601String()}';
    final list = groups.putIfAbsent(key, () => []);
    if (!list.contains(label)) list.add(label);
    times[key] = at;
    repeats[key] = daily;
  }

  for (final m in meds) {
    if ((m['name'] as String? ?? '').trim().isEmpty) continue;
    final medicine = MedicationRecord.fromJson(m);
    if (!medicine.remindersEnabled) continue;
    final start = medicine.startDate;
    final end = medicine.endDate;
    final futureStart = start != null && start.isAfter(today);
    final firstDay = futureStart ? start : today;
    final repeatsDaily = end == null && medicine.prescriptionPlan == null;
    if (repeatsDaily) {
      for (final at in medicine.dosesOn(firstDay)) {
        final next = at.isAfter(now) ? at : DateTime(at.year, at.month, at.day + 1, at.hour, at.minute);
        add(next, true, medicine.label);
      }
      continue;
    }

    var count = 0;
    for (var i = 0; i < maxDays && count < maxItems; i++) {
      final day = DateTime(firstDay.year, firstDay.month, firstDay.day + i);
      if (end != null && day.isAfter(end)) break;
      for (final at in medicine.dosesOn(day)) {
        if (!at.isAfter(now)) continue;
        add(at, false, medicine.label);
        count++;
        if (count == maxItems) break;
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
