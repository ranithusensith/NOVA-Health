/// Results returned by the backend scan endpoints (drafts until the user confirms).
class ScanMedication {
  const ScanMedication({
    required this.name,
    this.dosage,
    this.frequency,
    this.durationDays,
    this.instructions,
  });

  final String name;
  final String? dosage;
  final String? frequency;
  final int? durationDays;
  final String? instructions;

  factory ScanMedication.fromJson(Map<String, dynamic> j) => ScanMedication(
        name: (j['name'] as String?) ?? '',
        dosage: j['dosage'] as String?,
        frequency: j['frequency'] as String?,
        durationDays: (j['duration_days'] as num?)?.toInt(),
        instructions: j['instructions'] as String?,
      );
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

class PrescriptionScan {
  const PrescriptionScan({
    required this.medications,
    required this.confidence,
    this.notes,
    this.warnings = const [],
  });

  final List<ScanMedication> medications;
  final double confidence;
  final String? notes;
  final List<ScanWarning> warnings;

  factory PrescriptionScan.fromJson(Map<String, dynamic> j) => PrescriptionScan(
        medications: [
          for (final m in (j['medications'] as List? ?? const []))
            ScanMedication.fromJson((m as Map).cast<String, dynamic>()),
        ],
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        notes: j['notes'] as String?,
        warnings: [
          for (final w in (j['warnings'] as List? ?? const []))
            ScanWarning.fromJson((w as Map).cast<String, dynamic>()),
        ],
      );
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
