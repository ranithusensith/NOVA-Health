import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/profile_models.dart';

void main() {
  test('BMI and note for an adult', () {
    const p = HealthProfile(heightCm: 170, weightKg: 65, birthDate: null);
    expect(p.bmi, closeTo(22.49, 0.01));
    expect(p.bmiNote, isNull); // no birth date, so no age: no label
    final adult = p.copyWith(birthDate: DateTime(2000, 1, 1));
    expect(adult.bmiNote, 'in the typical range');
  });

  test('no BMI note for under 18', () {
    final teen = HealthProfile(heightCm: 160, weightKg: 50, birthDate: DateTime(2012, 6, 1));
    expect(teen.bmi, isNotNull);
    expect(teen.bmiNote, isNull);
  });

  test('age changes on the birthday', () {
    final p = HealthProfile(birthDate: DateTime(2000, 10, 20));
    expect(p.ageOn(DateTime(2026, 10, 19)), 25);
    expect(p.ageOn(DateTime(2026, 10, 20)), 26);
  });

  test('profile is complete only with the essentials', () {
    expect(const HealthProfile(fullName: 'Ana').isComplete, isFalse);
    final full = HealthProfile(
      fullName: 'Ana',
      birthDate: DateTime(2000, 1, 1),
      sex: 'female',
      heightCm: 165,
      weightKg: 58,
    );
    expect(full.isComplete, isTrue);
  });

  test('row round trip keeps the data', () {
    final p = HealthProfile(
      fullName: ' Ana Perera ',
      birthDate: DateTime(1999, 3, 7),
      sex: 'female',
      bloodType: 'O+',
      heightCm: 165.5,
      weightKg: 58,
      conditions: const ['Asthma'],
      medicalNotes: ' none ',
      onboardingDone: true,
    );
    final row = p.toRow();
    expect(row['full_name'], 'Ana Perera');
    expect(row['birth_date'], '1999-03-07');
    expect(row['medical_notes'], 'none');
    final back = HealthProfile.fromRow(row);
    expect(back.fullName, 'Ana Perera');
    expect(back.birthDate, DateTime(1999, 3, 7));
    expect(back.conditions, ['Asthma']);
    expect(back.onboardingDone, isTrue);
  });

  test('heart rate notes', () {
    expect(heartNote(72, 'resting'), contains('typical'));
    expect(heartNote(130, 'resting'), contains('High'));
    expect(heartNote(38, 'resting'), contains('Low'));
    expect(heartNote(150, 'active'), isNull);
  });
}
