enum NutritionField {
  calories('Calories', 'calories', 'kcal', 5000),
  protein('Protein', 'protein_g', 'g', 500),
  carbs('Carbs', 'carbs_g', 'g', 800),
  fat('Fat', 'fat_g', 'g', 500);

  const NutritionField(this.label, this.key, this.unit, this.maximum);
  final String label;
  final String key;
  final String unit;
  final int maximum;

  static final _whole = RegExp(r'^[0-9]+$');
  static final _decimal = RegExp(r'^[0-9]+(?:[.,][0-9])?$');

  num? parse(String text) {
    final input = text.trim();
    if (input.isEmpty) return null;
    final whole = this == calories;
    final valid = (whole ? _whole : _decimal).hasMatch(input);
    final value = !valid
        ? null
        : whole
            ? int.tryParse(input)
            : double.tryParse(input.replaceAll(',', '.'));
    if (value == null || !value.isFinite || value > maximum) {
      throw FormatException(whole
          ? 'Enter a whole number from 0 to $maximum $unit.'
          : 'Enter 0 to $maximum $unit with up to one decimal place.');
    }
    return value;
  }

  num? read(Map<String, dynamic> row) {
    final nutrients = row['nutrients'];
    final value = this == calories
        ? row[key]
        : nutrients is Map
            ? nutrients[key]
            : null;
    if (value is! num || !value.isFinite || value < 0 || value > maximum) {
      return null;
    }
    if (this == calories) return value is int ? value : null;
    final tenths = value * 10;
    return tenths == tenths.round() ? value : null;
  }

  String display(num? value) => value == null
      ? 'Unknown'
      : '${value % 1 == 0 ? value.toInt() : value.toStringAsFixed(1)} $unit';
}

class MealRecord {
  MealRecord.fromJson(Map<String, dynamic> row)
      : description = (row['description'] as String?)?.trim() ?? '',
        values = {
          for (final field in NutritionField.values) field: field.read(row),
        };

  final String description;
  final Map<NutritionField, num?> values;
}

num? nutritionTotal(List<MealRecord>? meals, NutritionField field) {
  if (meals == null || meals.isEmpty) return null;
  var tenths = 0;
  for (final meal in meals) {
    final value = meal.values[field];
    if (value == null) return null;
    tenths += (value * 10).round();
  }
  return field == NutritionField.calories ? tenths ~/ 10 : tenths / 10;
}
