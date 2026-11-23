import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/screens/ai_privacy_screen.dart';
import 'package:nova_health/screens/scan_camera_screen.dart';
import 'package:nova_health/services/api_client.dart';

Future<void> openDialog<T>(
  WidgetTester tester,
  Widget dialog,
  ValueChanged<T?> onClosed,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) {
        return TextButton(
          onPressed: () async => onClosed(await showDialog<T>(
            context: context,
            builder: (_) => dialog,
          )),
          child: const Text('Open'),
        );
      }),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  test('provider and version are required even when account consent is set',
      () {
    AiPrivacyStatus status(
            {bool available = true, String? version, bool enabled = true}) =>
        AiPrivacyStatus.fromJson({
          'enabled': enabled,
          'provider_available': available,
          'disclosure_version': version ?? AiPrivacyStatus.disclosureVersion,
        });
    expect(status().allowed, isTrue);
    expect(status(enabled: false).allowed, isFalse);
    expect(status(available: false).allowed, isFalse);
    expect(status(version: 'previous').allowed, isFalse);
  });

  testWidgets(
      'consent requires the explicit action after seeing the provider disclosure',
      (tester) async {
    bool? result;
    await openDialog<bool>(
        tester, const AiConsentDialog(), (value) => result = value);
    expect(find.text('Share with Google Gemini?'), findsOneWidget);
    expect(find.textContaining('Google may retain requests'), findsOneWidget);
    expect(result, isNull);
    await tester.tap(find.text('Keep off'));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable sharing'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets(
      'chat asserts an explicit share and defaults to no saved health data',
      (tester) async {
    AiChatShare? result;
    await openDialog<AiChatShare>(
        tester, const AiChatReview(), (value) => result = value);
    expect(find.textContaining('four earlier questions'), findsOneWidget);
    expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((box) => box.value == false),
        isTrue);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Lab results'));
    await tester.tap(find.text('Lab results'));
    await tester.tap(find.text('Share question'));
    await tester.pumpAndSettle();
    expect(result?.healthData, ['lab_results']);
    expect(result?.includeEarlierQuestions, isFalse);
  });

  testWidgets('medical review blocks empty text and returns only edited text',
      (tester) async {
    String? result;
    await openDialog<String>(
      tester,
      const MedicalTextReview(text: '', extractionMessage: 'No text was read.'),
      (value) => result = value,
    );
    expect(find.text('No text was read.'), findsOneWidget);
    final share = find.widgetWithText(FilledButton, 'Share text with Gemini');
    expect(tester.widget<FilledButton>(share).onPressed, isNull);
    await tester.enterText(
        find.byType(TextField), 'Fixture Name\nParacetamol 500 mg');
    await tester.enterText(find.byType(TextField), 'Paracetamol 500 mg');
    await tester.pump();
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(result, 'Paracetamol 500 mg');
  });

  testWidgets('closing medical review does not return source data',
      (tester) async {
    String? result = 'not closed';
    await openDialog<String>(
      tester,
      const MedicalTextReview(text: 'Paracetamol 500 mg'),
      (value) => result = value,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
