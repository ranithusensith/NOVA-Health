import 'package:flutter/material.dart';

import '../data/nutrition.dart';
import 'content.dart';

class MealRecords extends StatelessWidget {
  const MealRecords({super.key, required this.meals});

  final List<MealRecord> meals;

  @override
  Widget build(BuildContext context) => NovaCard(
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            title: const Text('Confirmed meal records'),
            children: [
              for (final meal in meals)
                ListTile(
                  title: Text(meal.description.isEmpty
                      ? 'Unnamed meal'
                      : meal.description),
                  subtitle: Text([
                    for (final field in NutritionField.values)
                      '${field.label}: ${field.display(meal.values[field])}',
                  ].join(' · ')),
                ),
            ],
          ),
        ),
      );
}
