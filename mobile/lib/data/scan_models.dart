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

class PrescriptionScan {
  const PrescriptionScan({required this.medications, required this.confidence, this.notes});

  final List<ScanMedication> medications;
  final double confidence;
  final String? notes;

  factory PrescriptionScan.fromJson(Map<String, dynamic> j) => PrescriptionScan(
        medications: [
          for (final m in (j['medications'] as List? ?? const []))
            ScanMedication.fromJson((m as Map).cast<String, dynamic>()),
        ],
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        notes: j['notes'] as String?,
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
