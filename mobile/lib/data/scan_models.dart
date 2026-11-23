/// Results returned by the backend scan endpoints (drafts until the user confirms).
class ScanMedication {
  const ScanMedication({
    required this.name,
    this.dosage,
    this.frequency,
    this.durationDays,
    this.durationText,
    this.instructions,
  });

  final String name;
  final String? dosage;
  final String? frequency;
  final int? durationDays;
  final String? durationText;
  final String? instructions;

  factory ScanMedication.fromJson(Map<String, dynamic> j) => ScanMedication(
        name: (j['name'] as String?) ?? '',
        dosage: j['dosage'] as String?,
        frequency: j['frequency'] as String?,
        durationDays: (j['duration_days'] as num?)?.toInt(),
        durationText: j['duration_text'] as String?,
        instructions: j['instructions'] as String?,
      );

  /// A date suggestion is available only for a single, explicit number of days.
  int? get suggestedCourseDays {
    final match = RegExp(r'^(?:for\s+)?([0-9]{1,3})\s+days?\.?$', caseSensitive: false)
        .firstMatch(durationText?.trim() ?? '');
    final days = int.tryParse(match?.group(1) ?? '');
    return days != null && days >= 1 && days <= 365 ? days : null;
  }

  bool get mentionsAsNeeded => RegExp(r'\b(?:p\s*\.?\s*r\s*\.?\s*n|as needed|when needed|as required)\b', caseSensitive: false)
      .hasMatch('${frequency ?? ''} ${instructions ?? ''}');
}

/// A safety note from the backend's fixed medicine rules (allergy conflicts and so on).
class ScanWarning {
  const ScanWarning({required this.severity, required this.message});

  final String severity; // 'high' | 'caution'
  final String message;

  bool get isHigh => severity == 'high';

  factory ScanWarning.fromJson(Map<String, dynamic> j) => ScanWarning(
        severity: (j['severity'] as String?) ?? 'caution',
        message: (j['message'] as String?) ?? '',
      );
}

class PrescriptionSafetyCheck {
  const PrescriptionSafetyCheck({this.completed = false, this.warnings = const []});

  final bool completed;
  final List<ScanWarning> warnings;

  factory PrescriptionSafetyCheck.fromJson(Map<String, dynamic> json) {
    final warnings = json['warnings'];
    if (warnings is! List) return const PrescriptionSafetyCheck();
    return PrescriptionSafetyCheck(
      completed: json['safety_check_status'] == 'completed',
      warnings: [
        for (final warning in warnings)
          ScanWarning.fromJson((warning as Map).cast<String, dynamic>()),
      ],
    );
  }
}

class PrescriptionScan {
  const PrescriptionScan({
    required this.medications,
    required this.confidence,
    this.scanId,
    this.notes,
    this.safetyCheck = const PrescriptionSafetyCheck(),
  });

  final List<ScanMedication> medications;
  final double confidence;
  final String? scanId;
  final String? notes;
  final PrescriptionSafetyCheck safetyCheck;

  factory PrescriptionScan.fromJson(Map<String, dynamic> j) => PrescriptionScan(
        medications: [
          for (final m in (j['medications'] as List? ?? const []))
            ScanMedication.fromJson((m as Map).cast<String, dynamic>()),
        ],
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        scanId: j['scan_id'] as String?,
        notes: j['notes'] as String?,
        safetyCheck: PrescriptionSafetyCheck.fromJson(j),
      );
}

class PrescriptionConfirmation {
  const PrescriptionConfirmation({
    required this.safetyCheck,
    required this.activated,
    this.reviewToken,
  });

  final PrescriptionSafetyCheck safetyCheck;
  final bool activated;
  final String? reviewToken;

  factory PrescriptionConfirmation.fromJson(Map<String, dynamic> json) {
    final safetyCheck = PrescriptionSafetyCheck.fromJson(json);
    return PrescriptionConfirmation(
      safetyCheck: safetyCheck,
      activated: safetyCheck.completed && json['activated'] == true,
      reviewToken: safetyCheck.completed ? json['review_token'] as String? : null,
    );
  }
}

class FoodScan {
  const FoodScan({
    required this.description,
    required this.calories,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.confidence,
  });

  final String description;
  final int calories;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final double confidence;

  factory FoodScan.fromJson(Map<String, dynamic> j) {
    final n = ((j['nutrients'] as Map?) ?? const {}).cast<String, dynamic>();
    return FoodScan(
      description: (j['description'] as String?) ?? '',
      calories: (j['calories'] as num?)?.toInt() ?? 0,
      proteinG: (n['protein_g'] as num?)?.toDouble() ?? 0,
      carbsG: (n['carbs_g'] as num?)?.toDouble() ?? 0,
      fatG: (n['fat_g'] as num?)?.toDouble() ?? 0,
      confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// One test row read from a lab report (a draft until the user confirms it).
class LabResultDraft {
  LabResultDraft({
    required this.test,
    this.value,
    this.valueText,
    this.unit,
    this.refLow,
    this.refHigh,
    required this.flag,
  });

  final String test;
  final double? value;
  final String? valueText;
  final String? unit;
  final double? refLow;
  final double? refHigh;
  final String flag; // low | normal | high | unknown

  /// Set by the confirm screen when the user unticks a row.
  bool include = true;

  factory LabResultDraft.fromJson(Map<String, dynamic> j) => LabResultDraft(
        test: (j['test'] as String?) ?? '',
        value: (j['value'] as num?)?.toDouble(),
        valueText: j['value_text'] as String?,
        unit: j['unit'] as String?,
        refLow: (j['ref_low'] as num?)?.toDouble(),
        refHigh: (j['ref_high'] as num?)?.toDouble(),
        flag: (j['flag'] as String?) ?? 'unknown',
      );
}

class ReportScan {
  const ReportScan({
    required this.results,
    required this.confidence,
    this.reportType,
    this.reportDate,
    this.notes,
  });

  final List<LabResultDraft> results;
  final double confidence;
  final String? reportType;
  final DateTime? reportDate;
  final String? notes;

  factory ReportScan.fromJson(Map<String, dynamic> j) => ReportScan(
        results: [
          for (final r in (j['results'] as List? ?? const []))
            LabResultDraft.fromJson((r as Map).cast<String, dynamic>()),
        ],
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        reportType: j['report_type'] as String?,
        reportDate: DateTime.tryParse((j['report_date'] as String?) ?? ''),
        notes: j['notes'] as String?,
      );
}
