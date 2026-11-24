import 'care_models.dart';

/// One notification to schedule. Pure data, so it can be unit tested without a phone.
class ReminderPlan {
  const ReminderPlan({required this.at, required this.names});

  /// The instant of this notification, with the device zone used for planning.
  final DateTime at;

  /// Medicines due at this time, e.g. "Amoxicillin 500 mg".
  final List<String> names;

  String get title => 'NOVA Health reminder';

  String body({bool showNames = false}) {
    if (!showNames) return 'Open NOVA Health to view your reminder.';
    if (names.length <= 3) return 'Time to take ${names.join(', ')}';
    return 'Time to take ${names.take(3).join(', ')} and ${names.length - 3} more';
  }
}

/// Works out which notifications to schedule from the user's confirmed medicines.
///
/// - Every reminder is dated. Native time-only repetition can ignore the start date.
/// - Dose calculations, including exact intervals, are shared with the timeline.
/// - Medicines due at the same moment share one notification.
/// - Capped at [maxItems] (iOS keeps at most 64 pending notifications).
List<ReminderPlan> buildReminderPlan(
  List<Map<String, dynamic>> meds,
  DateTime now, {
  int maxItems = 60,
  int maxDays = 30,
}) {
  final today = dayOf(now);
  final groups = <DateTime, Set<String>>{};

  for (final m in meds) {
    if ((m['name'] as String? ?? '').trim().isEmpty) continue;
    final medicine = MedicationRecord.fromJson(m);
    if (!medicine.remindersEnabled) continue;
    final start = medicine.startDate;
    final end = medicine.endDate;
    final futureStart = start != null && start.isAfter(today);
    final firstDay = futureStart ? start : today;
    var count = 0;
    for (var i = 0; i < maxDays && count < maxItems; i++) {
      final day = calendarDay(firstDay, i);
      if (end != null && day.isAfter(end)) break;
      for (final at in medicine.dosesOn(day)) {
        if (!at.isAfter(now)) continue;
        groups.putIfAbsent(at.toUtc(), () => {}).add(medicine.label);
        count++;
        if (count == maxItems) break;
      }
    }
  }

  final times = groups.keys.toList()..sort();
  return [
    for (final at in times.take(maxItems))
      ReminderPlan(at: at.toLocal(), names: groups[at]!.toList()),
  ];
}
