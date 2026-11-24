import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/care_models.dart';
import 'package:nova_health/data/scan_models.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/medications_screen.dart';
import 'package:nova_health/widgets/content.dart';

const _account = '00000000-0000-0000-0000-000000000001';
const _clear = PrescriptionConfirmation(
  safetyCheck: PrescriptionSafetyCheck(completed: true),
  activated: true,
);
const _unavailable = PrescriptionConfirmation(
  safetyCheck: PrescriptionSafetyCheck(),
  activated: false,
);
const _warning = PrescriptionConfirmation(
  safetyCheck: PrescriptionSafetyCheck(
    completed: true,
    warnings: [
      ScanWarning(severity: 'high', message: 'Synthetic allergy warning.'),
    ],
  ),
  activated: false,
  reviewToken: 'synthetic-reviewed-draft',
);

Future<void> _open(
  WidgetTester tester,
  Future<PrescriptionConfirmation> Function(Map<String, dynamic>) confirm, {
  MedicationRecord? existing,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 1300);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    NovaApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            child: const Text('Open test editor'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final saved = await showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                builder: (_) => MedicationEditor(
                  accountId: _account,
                  existing: existing,
                  reviewMedication: confirm,
                ),
              );
              if (saved == true) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Medication saved')),
                );
              }
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open test editor'));
  await tester.pumpAndSettle();
}

Finder _button(String text) => find.widgetWithText(NovaButton, text);

Future<void> _tapSave(WidgetTester tester,
    [String label = 'Check safety and save']) async {
  await tester.ensureVisible(_button(label));
  await tester.tap(_button(label));
  await tester.pump();
}

void main() {
  testWidgets('manual PRN entry awaits safety and keeps directions',
      (tester) async {
    final pending = Completer<PrescriptionConfirmation>();
    await _open(tester, (draft) {
      expect(draft['expected_account_id'], _account);
      expect(draft['name'], 'Synthetic medicine');
      expect(draft['timing'], 'as_needed');
      expect(draft['times'], isEmpty);
      expect(draft['instructions'], 'Synthetic prescribed directions');
      expect(draft['reminders_enabled'], isFalse);
      expect(draft.containsKey('review_token'), isFalse);
      return pending.future;
    });
    await tester.enterText(find.byType(TextField).first, 'Synthetic medicine');
    await tester.enterText(
        find.byType(TextField).last, 'Synthetic prescribed directions');
    await tester.tap(find.text('No fixed schedule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('As needed').last);
    await tester.pumpAndSettle();
    await _tapSave(tester);
    expect(find.text('Medication saved'), findsNothing);
    expect(tester.widget<NovaButton>(_button('Checking…')).onPressed, isNull);

    pending.complete(_clear);
    await tester.pumpAndSettle();
    expect(find.text('Medication saved'), findsOneWidget);
  });

  testWidgets(
      'an edit invalidates warnings and requires acknowledgement of the new draft',
      (tester) async {
    final drafts = <Map<String, dynamic>>[];
    await _open(tester, (draft) async {
      drafts.add(draft);
      return draft.containsKey('review_token') ? _clear : _warning;
    },
        existing: MedicationRecord(
          id: 'synthetic-row',
          name: 'Synthetic prescription',
          times: const ['10:00'],
          startDate: DateTime(2026, 11, 23),
          source: 'scan',
          reviewRevision: 'synthetic-revision',
          prescriptionPlan: const PrescriptionPlan(
            timing: PrescriptionTiming.daily,
            instructions: 'Synthetic original prescription',
          ),
        ));

    expect(find.text('Synthetic original prescription'), findsOneWidget);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Synthetic allergy warning.'), findsOneWidget);
    expect(find.text('Medication saved'), findsNothing);
    expect(drafts, hasLength(1));
    expect(drafts.first['medication_id'], 'synthetic-row');
    expect(drafts.first['expected_revision'], 'synthetic-revision');
    expect(drafts.first['times'], ['10:00']);
    expect(drafts.first.containsKey('instructions'), isFalse);

    await tester.enterText(
        find.byType(TextField).at(1), 'Edited synthetic dose');
    await tester.pumpAndSettle();
    expect(_button('Acknowledge warnings and save'), findsNothing);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(drafts[1]['dosage'], 'Edited synthetic dose');
    expect(drafts[1].containsKey('review_token'), isFalse);
    await _tapSave(tester, 'Acknowledge warnings and save');
    await tester.pumpAndSettle();
    expect(drafts[2]['review_token'], 'synthetic-reviewed-draft');
    expect(find.text('Medication saved'), findsOneWidget);
  });

  testWidgets('a failed check shows an error and permits a recheck',
      (tester) async {
    var attempts = 0;
    await _open(tester, (_) async => ++attempts == 1 ? _unavailable : _clear);
    await tester.enterText(find.byType(TextField).first, 'Synthetic medicine');
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('NOVA could not complete the safety review'),
        findsOneWidget);
    expect(find.text('Medication saved'), findsNothing);
    expect(_button('Acknowledge warnings and save'), findsNothing);
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(find.text('Medication saved'), findsOneWidget);
  });
}
