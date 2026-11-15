import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/app_prefs.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/login_screen.dart';
import 'package:nova_health/screens/track_screen.dart';
import 'package:nova_health/widgets/content.dart';
import 'package:nova_health/widgets/pressable.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.instance.load();
  });

  group('Login', () {
    testWidgets('empty form shows a validation message', (tester) async {
      await tester.pumpWidget(const NovaApp(home: LoginScreen()));
      await tester.pump();

      await tester.tap(find.widgetWithText(Pressable, 'Sign in'));
      await tester.pump();

      expect(find.text('Enter your email and a password of at least 6 characters.'), findsOneWidget);
    });

    testWidgets('a password shorter than 6 characters is rejected', (tester) async {
      await tester.pumpWidget(const NovaApp(home: LoginScreen()));
      await tester.pump();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(fields.evaluate().length - 2), 'maya@example.com');
      await tester.enterText(fields.last, '123');
      await tester.tap(find.widgetWithText(Pressable, 'Sign in'));
      await tester.pump();

      expect(find.text('Enter your email and a password of at least 6 characters.'), findsOneWidget);
    });
  });

  group('Track', () {
    testWidgets('custom water amount must be between 1 and 3000 ml', (tester) async {
      await tester.pumpWidget(NovaApp(home: Scaffold(body: TrackScreen(onLogged: () {}))));
      await tester.pump();

      final field = find.widgetWithText(TextField, 'Custom amount (ml)');
      await tester.ensureVisible(field);
      await tester.enterText(field, '5000');
      final add = find.widgetWithText(NovaButton, 'Add');
      tester.widget<NovaButton>(add).onPressed!();
      await tester.pump();

      expect(find.text('Enter an amount between 1 and 3000 ml.'), findsOneWidget);
    });

    testWidgets('mood save stays disabled until a mood is picked', (tester) async {
      await tester.pumpWidget(NovaApp(home: Scaffold(body: TrackScreen(onLogged: () {}))));
      await tester.pump();

      // Before a mood is picked the save button reads 'Pick a mood' and is disabled
      final button = find.widgetWithText(NovaButton, 'Pick a mood');
      await tester.ensureVisible(button);
      expect(tester.widget<NovaButton>(button).onPressed, isNull);

      // Select 'Good' mood (call the callback directly; a tap on the small target may miss)
      final good = find.byWidgetPredicate((w) => w is Pressable && w.semanticLabel == 'Good');
      await tester.ensureVisible(good);
      tester.widget<Pressable>(good).onTap!();
      await tester.pump();

      // Verify label changes to 'Save mood: Good'
      expect(find.widgetWithText(NovaButton, 'Save mood: Good'), findsOneWidget);
    });
  });
}