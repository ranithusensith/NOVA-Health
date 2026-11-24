import 'care_models.dart';

/// The next scheduled dose shown on the home screen.
class Medication {
  const Medication({required this.name, required this.dose, required this.time, this.occurrence, this.overdue = false});
  final String name;
  final String dose;
  final String time;

  final DoseOccurrence? occurrence;

  /// True when this dose's time has passed and it was not taken yet.
  final bool overdue;
}

class HealthSnapshot {
  const HealthSnapshot({
    required this.firstName,
    required this.isEmpty,
    this.waterL,
    this.waterGoalL,
    this.sleepMinutes,
    this.sleepGoalMinutes,
    this.steps,
    this.stepsGoal,
    this.nextMedication,
    this.medsTakenToday = 0,
    this.medsToday = 0,
  });

  final String firstName;
  final bool isEmpty;
  final double? waterL;
  final double? waterGoalL;
  final int? sleepMinutes;
  final int? sleepGoalMinutes;
  final int? steps;
  final int? stepsGoal;
  final Medication? nextMedication;
  final int medsTakenToday;
  final int medsToday;

  HealthSnapshot copyWith({
    bool? isEmpty,
    Medication? nextMedication,
    bool clearNextMedication = false,
    int? medsTakenToday,
    int? medsToday,
  }) =>
      HealthSnapshot(
        firstName: firstName,
        isEmpty: isEmpty ?? this.isEmpty,
        waterL: waterL,
        waterGoalL: waterGoalL,
        sleepMinutes: sleepMinutes,
        sleepGoalMinutes: sleepGoalMinutes,
        steps: steps,
        stepsGoal: stepsGoal,
        nextMedication: clearNextMedication ? null : (nextMedication ?? this.nextMedication),
        medsTakenToday: medsTakenToday ?? this.medsTakenToday,
        medsToday: medsToday ?? this.medsToday,
      );

  double? get waterProgress => waterL == null || waterGoalL == null ? null : waterL! / waterGoalL!;
  double? get sleepProgress => sleepMinutes == null || sleepGoalMinutes == null ? null : sleepMinutes! / sleepGoalMinutes!;
  double? get stepsProgress => steps == null || stepsGoal == null ? null : steps! / stepsGoal!;

}

String formatToday(DateTime d) {
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
}

String greetingFor(DateTime d) => d.hour < 12 ? 'Good morning' : (d.hour < 17 ? 'Good afternoon' : 'Good evening');

String formatThousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

String formatMinutes(int m) => m % 60 == 0 ? '${m ~/ 60}h' : '${m ~/ 60}h ${m % 60}m';

String formatClock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

String formatDoseClock(DoseSlot slot) {
  final clock = formatClock(slot.at);
  if (slot.occurrence.scheduledLocalAt != null) return clock;
  final offset = slot.at.timeZoneOffset.inMinutes;
  final minutes = offset.abs();
  return '$clock UTC${offset < 0 ? '-' : '+'}${clockString(minutes ~/ 60, minutes % 60)}';
}
