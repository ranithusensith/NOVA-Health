/// Plain models for medications, doses, history and emergency contacts.
/// Pure Dart (no Flutter, no Supabase) so the logic is easy to unit test.
library;

String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// A course of one day starts and ends on the same calendar date.
DateTime inclusiveCourseEnd(DateTime start, int days) =>
    DateTime(start.year, start.month, start.day + days - 1);

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

enum PrescriptionTiming {
  daily('daily', 'Daily times'),
  interval('interval', 'Exact interval'),
  asNeeded('as_needed', 'As needed'),
  unscheduled('unscheduled', 'No fixed schedule');

  const PrescriptionTiming(this.value, this.label);
  final String value;
  final String label;

  bool get isScheduled => this == daily || this == interval;
}

class PrescriptionPlan {
  const PrescriptionPlan({
    required this.timing,
    this.dosageText,
    this.frequency,
    this.instructions,
    this.durationText,
    this.intervalMinutes,
    this.firstDoseAt,
  });

  final PrescriptionTiming timing;
  final String? dosageText;
  final String? frequency;
  final String? instructions;
  final String? durationText;
  final int? intervalMinutes;
  final DateTime? firstDoseAt;

  String get intervalLabel {
    final minutes = intervalMinutes;
    if (minutes == null || minutes <= 0) return timing.label;
    final parts = [if (minutes >= 60) '${minutes ~/ 60} h', if (minutes % 60 != 0) '${minutes % 60} min'];
    return 'Every ${parts.join(' ')}';
  }

  factory PrescriptionPlan.fromJson(Map<String, dynamic> json) => PrescriptionPlan(
        timing: PrescriptionTiming.values.firstWhere(
          (timing) => timing.value == json['kind'],
          orElse: () => PrescriptionTiming.unscheduled,
        ),
        dosageText: json['dosage_text'] as String?,
        frequency: json['frequency'] as String?,
        instructions: json['instructions'] as String?,
        durationText: json['duration_text'] as String?,
        intervalMinutes: (json['interval_minutes'] as num?)?.toInt(),
        firstDoseAt: DateTime.tryParse(json['first_dose_at'] as String? ?? ''),
      );

  Map<String, dynamic> toJson() => {
        'kind': timing.value,
        'dosage_text': dosageText,
        'frequency': frequency,
        'instructions': instructions,
        'duration_text': durationText,
        if (timing == PrescriptionTiming.interval) ...{
          'interval_minutes': intervalMinutes,
          'first_dose_at': _localIsoWithOffset(firstDoseAt!),
        },
      };

  /// Keep the local date and the UTC offset for validating the course start.
  static String _localIsoWithOffset(DateTime value) {
    final date = value.toLocal();
    final offset = date.timeZoneOffset.inMinutes;
    final absolute = offset.abs();
    return '${date.toIso8601String()}${offset < 0 ? '-' : '+'}'
        '${clockString(absolute ~/ 60, absolute % 60)}';
  }
}

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
    this.prescriptionPlan,
    this.remindersEnabled = true,
  });

  final String id;
  final String name;
  final String? dosage;

  /// Prescribed daily dose times as "HH:MM", sorted.
  final List<String> times;
  final DateTime? startDate;
  final DateTime? endDate;

  /// 'confirmed' while active, 'ended' once the user stops it.
  final String status;
  final String? source;
  final PrescriptionPlan? prescriptionPlan;
  final bool remindersEnabled;

  bool get isEnded => status == 'ended';

  /// True when the medicine is active and scheduled on [day].
  bool activeOn(DateTime day) {
    if (isEnded) return false;
    return _withinCourse(day);
  }

  bool _withinCourse(DateTime day) {
    final d = dayOf(day);
    if (startDate != null && dayOf(startDate!).isAfter(d)) return false;
    if (endDate != null && dayOf(endDate!).isBefore(d)) return false;
    return true;
  }

  Iterable<DateTime> dosesOn(DateTime day, {bool includeEnded = false}) sync* {
    if ((!includeEnded && isEnded) || !_withinCourse(day)) return;
    final start = dayOf(day);
    final plan = prescriptionPlan;
    if (plan != null && !plan.timing.isScheduled) return;
    if (plan?.timing != PrescriptionTiming.interval) {
      for (final time in times) {
        final clock = parseClock(time);
        if (clock != null) {
          final at = DateTime(start.year, start.month, start.day, clock.hour, clock.minute);
          if (at.hour == clock.hour && at.minute == clock.minute) yield at;
        }
      }
      return;
    }

    final first = plan!.firstDoseAt?.toUtc();
    final minutes = plan.intervalMinutes;
    if (first == null || minutes == null || minutes <= 0) return;
    final step = Duration(minutes: minutes);
    final stepMicros = step.inMicroseconds;
    final elapsed = start.toUtc().difference(first).inMicroseconds;
    final skipped = elapsed <= 0 ? 0 : (elapsed + stepMicros - 1) ~/ stepMicros;
    final end = DateTime(start.year, start.month, start.day + 1).toUtc();
    for (var at = first.add(step * skipped); at.isBefore(end); at = at.add(step)) {
      yield at.toLocal();
    }
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
      prescriptionPlan: j['prescription_plan'] is Map<String, dynamic>
          ? PrescriptionPlan.fromJson(j['prescription_plan'] as Map<String, dynamic>)
          : null,
      remindersEnabled: j['reminders_enabled'] != false,
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
    var taken = takenCounts[m.id] ?? 0;
    for (final at in m.dosesOn(now)) {
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
