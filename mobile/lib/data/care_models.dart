/// Plain models for medications, doses, history and emergency contacts.
/// Pure Dart (no Flutter, no Supabase) so the logic is easy to unit test.
library;

String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// Parses "HH:MM" or Postgres "HH:MM:SS" into hour and minute.
({int hour, int minute})? parseClock(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return (hour: h, minute: m);
}

String clockString(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

/// One row of the `medications` table.
class MedicationRecord {
  const MedicationRecord({
    required this.id,
    required this.name,
    this.dosage,
    this.times = const [],
    this.startDate,
    this.endDate,
    this.status = 'confirmed',
    this.source,
  });

  final String id;
  final String name;
  final String? dosage;

  /// Reminder times as "HH:MM", sorted.
  final List<String> times;
  final DateTime? startDate;
  final DateTime? endDate;

  /// 'confirmed' while active, 'ended' once the user stops it.
  final String status;
  final String? source;

  bool get isEnded => status == 'ended';

  /// True when the medicine is active and scheduled on [day].
  bool activeOn(DateTime day) {
    if (isEnded) return false;
    final d = dayOf(day);
    if (startDate != null && dayOf(startDate!).isAfter(d)) return false;
    if (endDate != null && dayOf(endDate!).isBefore(d)) return false;
    return true;
  }

  String get label => (dosage == null || dosage!.isEmpty) ? name : '$name $dosage';

  factory MedicationRecord.fromJson(Map<String, dynamic> j) {
    final times = <String>[];
    for (final t in (j['times'] as List? ?? const [])) {
      final c = parseClock(t.toString());
      if (c != null) times.add(clockString(c.hour, c.minute));
    }
    times.sort();
    return MedicationRecord(
      id: j['id'].toString(),
      name: (j['name'] as String?) ?? 'Medicine',
      dosage: j['dosage'] as String?,
      times: times,
      startDate: DateTime.tryParse((j['start_date'] as String?) ?? ''),
      endDate: DateTime.tryParse((j['end_date'] as String?) ?? ''),
      status: (j['status'] as String?) ?? 'confirmed',
      source: j['source'] as String?,
    );
  }
}

enum DoseState { taken, due, upcoming, missed }

/// One scheduled dose today.
class DoseSlot {
  const DoseSlot({required this.medication, required this.at, required this.state});

  final MedicationRecord medication;
  final DateTime at;
  final DoseState state;

  /// Morning / Afternoon / Evening group for the timeline.
  String get period => at.hour < 12 ? 'Morning' : (at.hour < 17 ? 'Afternoon' : 'Evening');
}

/// A dose counts as "due" from 30 minutes before until 60 minutes after its
/// time, and as "missed" after that if it was not taken.
const doseEarlyWindow = Duration(minutes: 30);
const doseLateWindow = Duration(minutes: 60);

/// Builds today's dose timeline. [takenCounts] is how many doses of each
/// medication were logged today: the earliest slots are treated as taken.
List<DoseSlot> buildSchedule(
  List<MedicationRecord> meds,
  Map<String, int> takenCounts,
  DateTime now,
) {
  final slots = <DoseSlot>[];
  for (final m in meds) {
    if (!m.activeOn(now)) continue;
    var taken = takenCounts[m.id] ?? 0;
    for (final t in m.times) {
      final c = parseClock(t);
      if (c == null) continue;
      final at = DateTime(now.year, now.month, now.day, c.hour, c.minute);
      final DoseState state;
      if (taken > 0) {
        state = DoseState.taken;
        taken--;
      } else if (now.isAfter(at.add(doseLateWindow))) {
        state = DoseState.missed;
      } else if (now.isAfter(at.subtract(doseEarlyWindow))) {
        state = DoseState.due;
      } else {
        state = DoseState.upcoming;
      }
      slots.add(DoseSlot(medication: m, at: at, state: state));
    }
  }
  slots.sort((a, b) => a.at.compareTo(b.at));
  return slots;
}

/// The dose to show on Home: the first one that is due, else the next
/// upcoming one, else the latest missed one.
DoseSlot? nextDose(List<DoseSlot> slots) {
  for (final s in slots) {
    if (s.state == DoseState.due) return s;
  }
  for (final s in slots) {
    if (s.state == DoseState.upcoming) return s;
  }
  final missed = slots.where((s) => s.state == DoseState.missed);
  return missed.isEmpty ? null : missed.last;
}

/// One day of tracked data for charts and the daily report.
class DayStats {
  const DayStats({
    required this.day,
    this.waterMl = 0,
    this.sleepHours,
    this.moodLevel,
    this.dosesTaken = 0,
    this.dosesScheduled = 0,
    this.calories = 0,
  });

  final DateTime day;
  final int waterMl;
  final double? sleepHours;

  /// 0 (awful) … 4 (great), or null when no mood was logged.
  final int? moodLevel;
  final int dosesTaken;
  final int dosesScheduled;
  final int calories;
}

/// Short weekday label (Mon, Tue …).
String weekdayShort(DateTime d) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];

/// One row of the `emergency_contacts` table.
class EmergencyContact {
  const EmergencyContact({required this.id, required this.name, required this.phone, this.relationship});

  final String id;
  final String name;
  final String phone;
  final String? relationship;

  factory EmergencyContact.fromJson(Map<String, dynamic> j) => EmergencyContact(
        id: j['id'].toString(),
        name: (j['name'] as String?) ?? '',
        phone: (j['phone'] as String?) ?? '',
        relationship: j['relationship'] as String?,
      );
}
