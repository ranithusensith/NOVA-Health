enum RecordComparison {
  sleepSteps('sleep_steps', 'Sleep and steps', {
    'sleep': 'Sleep logs',
    'steps': 'Imported step totals',
  }),
  medicationSymptoms('medication_symptoms', 'Scheduled doses and symptoms', {
    'scheduled_doses': 'Scheduled dose logs',
    'symptoms': 'Symptom logs',
  }),
  mealsWater('meals_water', 'Meals and hydration', {
    'meals': 'Confirmed meal logs',
    'water': 'Water logs',
  });

  const RecordComparison(this.id, this.label, this.sources);
  final String id;
  final String label;
  final Map<String, String> sources;
}
