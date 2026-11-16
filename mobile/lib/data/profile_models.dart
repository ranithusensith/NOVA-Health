import 'dart:math' as math;

/// Options shown in the health profile form.
const sexOptions = <String, String>{
  'female': 'Female',
  'male': 'Male',
  'other': 'Other',
  'prefer_not_to_say': 'Prefer not to say',
};

/// Stored as the same text, except "Not sure" which is stored as `unknown`.
const bloodTypeOptions = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-', 'Not sure'];

const commonConditions = [
  'Diabetes',
  'High blood pressure',
  'Asthma',
  'Heart disease',
  'High cholesterol',
  'Thyroid condition',
  'Kidney disease',
  'Anaemia',
  'Migraine',
  'Epilepsy',
];

const commonAllergies = [
  'Penicillin',
  'Sulfa drugs',
  'Ibuprofen / NSAIDs',
  'Aspirin',
  'Peanuts',
  'Shellfish',
  'Eggs',
  'Milk',
  'Latex',
  'Dust / pollen',
];

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "25 Oct 2026"
String formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Everything the user enters at sign-up and can edit later in Profile.
class HealthProfile {
  const HealthProfile({
    this.fullName = '',
    this.birthDate,
    this.sex,
    this.bloodType,
    this.heightCm,
    this.weightKg,
    this.conditions = const [],
    this.medicalNotes = '',
    this.onboardingDone = false,
  });

  final String fullName;
  final DateTime? birthDate;
  final String? sex; // female | male | other | prefer_not_to_say
  final String? bloodType; // A+ ... O-, or 'unknown'
  final double? heightCm;
  final double? weightKg;
  final List<String> conditions;
  final String medicalNotes;
  final bool onboardingDone;

  factory HealthProfile.fromRow(Map<String, dynamic> r) => HealthProfile(
        fullName: ((r['full_name'] as String?) ?? '').trim(),
        birthDate: DateTime.tryParse((r['birth_date'] as String?) ?? ''),
        sex: r['sex'] as String?,
        bloodType: r['blood_type'] as String?,
        heightCm: (r['height_cm'] as num?)?.toDouble(),
        weightKg: (r['weight_kg'] as num?)?.toDouble(),
        conditions: [for (final c in (r['conditions'] as List? ?? const [])) c.toString()],
        medicalNotes: ((r['medical_notes'] as String?) ?? '').trim(),
        onboardingDone: r['onboarding_done'] == true,
      );

  Map<String, dynamic> toRow() => {
        'full_name': fullName.trim().isEmpty ? null : fullName.trim(),
        'birth_date': birthDate == null ? null : _ymd(birthDate!),
        'sex': sex,
        'blood_type': bloodType,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'conditions': conditions,
        'medical_notes': medicalNotes.trim().isEmpty ? null : medicalNotes.trim(),
        'onboarding_done': onboardingDone,
      };

  int? ageOn(DateTime today) {
    final b = birthDate;
    if (b == null) return null;
    var years = today.year - b.year;
    final hadBirthday = today.month > b.month || (today.month == b.month && today.day >= b.day);
    if (!hadBirthday) years--;
    return years < 0 ? null : years;
  }

  int? get age => ageOn(DateTime.now());

  double? get bmi {
    final h = heightCm;
    final w = weightKg;
    if (h == null || w == null || h <= 0) return null;
    final m = h / 100;
    return w / math.pow(m, 2);
  }

  /// Neutral wording, adults only. BMI is only a rough guide.
  String? get bmiNote {
    final value = bmi;
    final years = age;
    if (value == null || years == null || years < 18) return null;
    if (value < 18.5) return 'below the typical range';
    if (value < 25) return 'in the typical range';
    if (value < 30) return 'above the typical range';
    return 'well above the typical range';
  }

  String get sexLabel => sexOptions[sex] ?? '';
  String get bloodTypeLabel => bloodType == null ? '' : (bloodType == 'unknown' ? 'Not sure' : bloodType!);

  /// The fields the assistant and safety checks need most.
  bool get isComplete =>
      fullName.trim().isNotEmpty && birthDate != null && sex != null && heightCm != null && weightKg != null;

  HealthProfile copyWith({
    String? fullName,
    DateTime? birthDate,
    String? sex,
    String? bloodType,
    double? heightCm,
    double? weightKg,
    List<String>? conditions,
    String? medicalNotes,
    bool? onboardingDone,
  }) =>
      HealthProfile(
        fullName: fullName ?? this.fullName,
        birthDate: birthDate ?? this.birthDate,
        sex: sex ?? this.sex,
        bloodType: bloodType ?? this.bloodType,
        heightCm: heightCm ?? this.heightCm,
        weightKg: weightKg ?? this.weightKg,
        conditions: conditions ?? this.conditions,
        medicalNotes: medicalNotes ?? this.medicalNotes,
        onboardingDone: onboardingDone ?? this.onboardingDone,
      );
}

class AllergyRecord {
  const AllergyRecord({required this.id, required this.name});
  final String id;
  final String name;
}

/// One heart rate reading (manual or imported).
class HeartReading {
  const HeartReading({
    required this.id,
    required this.bpm,
    required this.at,
    required this.context,
    required this.source,
  });

  final String id;
  final int bpm;
  final DateTime at;
  final String context; // resting | active | sleeping | unknown
  final String source; // manual | apple_health | health_connect

  String get sourceLabel => switch (source) {
        'apple_health' => 'Apple Health',
        'health_connect' => 'Health Connect',
        _ => 'Added by you',
      };

  String get contextLabel => switch (context) {
        'resting' => 'Resting',
        'active' => 'After activity',
        'sleeping' => 'Sleeping',
        _ => 'Reading',
      };
}

/// A reading coming from a watch or health app, before it is saved.
class HeartSample {
  const HeartSample({required this.bpm, required this.at});
  final int bpm;
  final DateTime at;
}

/// One logged period. `end` is null while it is still going on.
class PeriodRecord {
  const PeriodRecord({required this.id, required this.start, this.end, this.flow, this.note});
  final String id;
  final DateTime start;
  final DateTime? end;
  final String? flow; // light | medium | heavy
  final String? note;
}

/// Gentle, non-diagnostic comment on one reading (or null when there is nothing to say).
String? heartNote(int bpm, String context) {
  if (context != 'resting') return null;
  if (bpm >= 120) {
    return 'High for a resting reading. Rest and measure again. If it stays high, or you feel '
        'chest pain, dizziness or shortness of breath, get medical help.';
  }
  if (bpm <= 40) {
    return 'Low for a resting reading. This can be normal for very fit people. If you feel dizzy, '
        'faint or unwell, get medical help.';
  }
  if (bpm >= 60 && bpm <= 100) return 'Within the typical adult resting range (60 to 100 bpm).';
  return null;
}
