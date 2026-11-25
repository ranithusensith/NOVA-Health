import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:nova_health/data/nutrition.dart';
import 'package:nova_health/data/scan_models.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/food_result_screen.dart';
import 'package:nova_health/screens/profile_screen.dart';
import 'package:nova_health/screens/scan_result_screen.dart';
import 'package:nova_health/screens/wearable_activity_screen.dart';
import 'package:nova_health/widgets/meal_records.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _prescription = PrescriptionScan(
  medications: [ScanMedication(name: 'Synthetic medicine', dosage: '10 mg')],
  confidence: 0.9,
);

void _tallViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 1500);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('photo expands in memory and preserves the medication draft',
      (tester) async {
    _tallViewport(tester);
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jObsAAAAASUVORK5CYII=',
    );
    await tester.pumpWidget(NovaApp(
      home: ScanResultScreen(scan: _prescription, imageBytes: image),
    ));
    final medicine = find.byType(TextField).first;
    await tester.enterText(medicine, 'Synthetic correction');
    await tester.tap(find.text('View photo'));
    await tester.pumpAndSettle();
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.maxScale, greaterThan(1));
    expect((viewer.child as Image).image, isA<MemoryImage>());
    expect(tester.widget<TextField>(medicine).controller?.text,
        'Synthetic correction');
    await tester.tap(find.text('Hide photo'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('an absent source photo has no view action', (tester) async {
    await tester
        .pumpWidget(const NovaApp(home: ScanResultScreen(scan: _prescription)));
    expect(find.text('View photo'), findsNothing);
  });

  testWidgets('a damaged source photo shows an error without resetting review',
      (tester) async {
    _tallViewport(tester);
    await tester.pumpWidget(NovaApp(
        home: ScanResultScreen(
      scan: _prescription,
      imageBytes: Uint8List.fromList([1, 2, 3]),
    )));
    await tester.runAsync(() async {
      await tester.tap(find.text('View photo'));
      await tester.pump();
      final preview =
          tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      final completion = Completer<bool>();
      final stream =
          (preview.child as Image).image.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (image, _) => completion.complete(true),
        onError: (error, stackTrace) => completion.complete(false),
      );
      stream.addListener(listener);
      expect(await completion.future, isFalse);
      stream.removeListener(listener);
    });
    await tester.pumpAndSettle();
    expect(find.text('Could not open the prescription photo.'), findsOneWidget);
    expect(find.text('Synthetic medicine'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid meal fields prevent saving and corrections round-trip',
      (tester) async {
    _tallViewport(tester);
    final writes = <Map<String, dynamic>>[];
    await tester.pumpWidget(NovaApp(
        home: FoodResultScreen(
      scan: const FoodScan(
        description: 'Synthetic lunch',
        calories: 540,
        proteinG: 22,
        carbsG: 80,
        fatG: 12,
        confidence: 0.9,
      ),
      expectedOwner: 'synthetic-owner',
      saveMeal: (row) async => writes.add(row),
    )));
    Future<void> edit(String label, String value) =>
        tester.enterText(find.byKey(ValueKey(label)), value);
    Future<void> save() async {
      await tester.tap(find.text('Confirm and save'));
      await tester.pumpAndSettle();
    }

    await edit('Calories', '5001');
    await edit('Protein', 'NaN');
    await edit('Carbs', '-1');
    await edit('Fat', '5 g');
    await save();
    expect(find.textContaining('Enter a whole number'), findsOneWidget);
    expect(
        find.textContaining('with up to one decimal place'), findsNWidgets(3));
    expect(writes, isEmpty);

    await edit('Calories', '420');
    await edit('Protein', '12,4');
    await edit('Carbs', '0');
    await edit('Fat', '');
    await save();
    expect(writes.single['user_id'], 'synthetic-owner');
    expect(writes.single['status'], 'confirmed');
    final meal = MealRecord.fromJson(writes.single);
    expect(nutritionTotal([meal], NutritionField.calories), 420);
    expect(nutritionTotal([meal], NutritionField.protein), 12.4);
    expect(nutritionTotal([meal], NutritionField.carbs), 0);
    expect(nutritionTotal([meal], NutritionField.fat), isNull);
    await tester
        .pumpWidget(NovaApp(home: Scaffold(body: MealRecords(meals: [meal]))));
    await tester.tap(find.text('Confirmed meal records'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic lunch'), findsOneWidget);
    expect(
        find.text(
            'Calories: 420 kcal · Protein: 12.4 g · Carbs: 0 g · Fat: Unknown'),
        findsOneWidget);
  });

  test('nutrition validation rejects unsupported formats and legacy values',
      () {
    for (final input in [
      '-1',
      'Infinity',
      '1e2',
      '12 g',
      '0.001',
      '12,000',
      '1.2.3',
      '501'
    ]) {
      expect(() => NutritionField.protein.parse(input), throwsFormatException);
    }
    expect(() => NutritionField.calories.parse('24.5'), throwsFormatException);
    expect(NutritionField.fat.parse('500.0'), 500);
    final valid = MealRecord.fromJson({
      'calories': 100,
      'nutrients': {'protein_g': 0.1}
    });
    final legacy = MealRecord.fromJson({
      'calories': -500,
      'nutrients': {'protein_g': '30'}
    });
    expect(nutritionTotal([valid, valid, valid], NutritionField.protein), 0.3);
    expect(nutritionTotal([valid, legacy], NutritionField.calories), isNull);
    expect(nutritionTotal([valid, legacy], NutritionField.protein), isNull);
  });

  testWidgets(
      'profile lists import actions and identifies the source as a platform',
      (tester) async {
    _tallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => Supabase.initialize(
          url: 'http://127.0.0.1:1',
          publishableKey: 'synthetic-key',
          authOptions:
              const FlutterAuthClientOptions(localStorage: EmptyLocalStorage()),
          httpClient: MockClient(
              (_) async => throw StateError('Unexpected network request')),
        ));
    addTearDown(Supabase.instance.dispose);
    await tester.pumpWidget(const NovaApp(home: ProfileScreen()));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Import steps and sleep'), 350);
    expect(find.text('Health data imports'), findsOneWidget);
    expect(find.text('Import heart rate'), findsOneWidget);
    expect(find.text('Connected devices'), findsNothing);
    for (final brand in ['Apple Watch', 'Samsung Galaxy Watch', 'Fitbit']) {
      expect(find.text(brand), findsNothing);
    }
    await tester.tap(find.text('Import steps and sleep'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(WearableActivityScreen), findsOneWidget);
    expect(find.textContaining('source identifies the health platform'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
