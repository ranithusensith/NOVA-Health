/// Sample data only — fictional persona Maya Perera, 28. No real personal data.
class Medication {
  const Medication({required this.name, required this.dose, required this.time, this.id, this.overdue = false});
  final String name;
  final String dose;
  final String time;

  /// medications.id, so "Mark as taken" can write a medication_logs row.
  final String? id;

  /// True when this dose's time has passed and it was not taken yet.
  final bool overdue;
}

class HealthSnapshot {
  const HealthSnapshot({
    required this.firstName,
    required this.isEmpty,
    this.waterL = 0,
    this.waterGoalL = 2.5,
    this.sleepMinutes = 0,
    this.sleepGoalMinutes = 420,
    this.steps = 0,
    this.stepsGoal = 8000,
    this.temperatureC = 31,
    this.weatherLabel = 'humid',
    this.weatherTip = 'Hydrate a little more today and keep walks before 10 AM.',
    this.nextMedication,
    this.medsTakenToday = 0,
    this.medsToday = 0,
  });

  final String firstName;
  final bool isEmpty;
  final double waterL;
  final double waterGoalL;
  final int sleepMinutes;
  final int sleepGoalMinutes;
  final int steps;
  final int stepsGoal;
  final int temperatureC;
  final String weatherLabel;
  final String weatherTip;
  final Medication? nextMedication;
  final int medsTakenToday;
  final int medsToday;

  HealthSnapshot copyWith({
    bool? isEmpty,
    double? waterGoalL,
    int? sleepGoalMinutes,
    Medication? nextMedication,
    bool clearNextMedication = false,
    int? medsTakenToday,
    int? medsToday,
  }) =>
      HealthSnapshot(
        firstName: firstName,
        isEmpty: isEmpty ?? this.isEmpty,
        waterL: waterL,
        waterGoalL: waterGoalL ?? this.waterGoalL,
        sleepMinutes: sleepMinutes,
        sleepGoalMinutes: sleepGoalMinutes ?? this.sleepGoalMinutes,
        steps: steps,
        stepsGoal: stepsGoal,
        temperatureC: temperatureC,
        weatherLabel: weatherLabel,
        weatherTip: weatherTip,
        nextMedication: clearNextMedication ? null : (nextMedication ?? this.nextMedication),
        medsTakenToday: medsTakenToday ?? this.medsTakenToday,
        medsToday: medsToday ?? this.medsToday,
      );

  double get waterProgress => waterL / waterGoalL;
  double get sleepProgress => sleepMinutes / sleepGoalMinutes;
  double get stepsProgress => steps / stepsGoal;

  static const todayInsight =
      'Shorter sleep and today\'s humidity may leave you low on energy this afternoon. '
      'A glass of water now and a lighter walk should help.';

  static const maya = HealthSnapshot(
    firstName: 'Maya',
    isEmpty: false,
    waterL: 1.4,
    sleepMinutes: 380,
    steps: 5840,
    nextMedication: Medication(name: 'Cetirizine', dose: '10 mg', time: '9:00 PM'),
    medsTakenToday: 1,
    medsToday: 2,
  );

  static const firstDay = HealthSnapshot(firstName: 'Maya', isEmpty: true);
}

/// Last 7 nights of sleep in hours, Sat → Fri.
const sleepWeek = [6.5, 5.8, 6.3, 5.6, 6.0, 6.9, 6.3];
const sleepWeekDays = ['Sat', 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri'];

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
