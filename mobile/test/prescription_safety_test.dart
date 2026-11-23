import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/health_repository.dart';
import 'package:nova_health/data/scan_models.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/scan_result_screen.dart';
import 'package:nova_health/widgets/content.dart';

const _scanId = 'e18ff310-8ef3-4f99-8d61-9b18b4939875';
const _medications = [
  ScanMedication(
    name: 'Sample medicine',
    dosage: '10 mg',
    frequency: 'once daily',
    durationDays: 3,
  ),
];
const _warning = ScanWarning(
  severity: 'high',
  message: 'A listed allergy conflicts with this medicine.',
);
const _clearCheck = PrescriptionSafetyCheck(completed: true);
const _warningCheck = PrescriptionSafetyCheck(
  completed: true,
  warnings: [_warning],
);
const _activated = PrescriptionConfirmation(
  safetyCheck: _clearCheck,
  activated: true,
);
const _needsReview = PrescriptionConfirmation(
  safetyCheck: _warningCheck,
  activated: false,
  reviewToken: 'reviewed-draft',
);

Finder _button(String label) => find.widgetWithText(NovaButton, label);

void main() {
  test('responses need an explicit completed safety check', () {
    final scan = PrescriptionScan.fromJson({
      'scan_id': _scanId,
      'warnings': [
        {'severity': _warning.severity, 'message': _warning.message},
      ],
    });
    expect(scan.scanId, _scanId);
    expect(scan.safetyCheck.completed, isFalse);
    expect(scan.safetyCheck.warnings.single.isHigh, isTrue);
    expect(
      PrescriptionConfirmation.fromJson({'activated': true, 'warnings': []})
          .activated,
      isFalse,
    );
  });

  testWidgets('activation waits for a successful check and save', (
    tester,
  ) async {
    final pending = Completer<PrescriptionConfirmation>();
    final before = HealthRepository.changes.value;
    await tester.pumpWidget(
      NovaApp(
        home: ScanResultScreen(
          scan: const PrescriptionScan(
            medications: _medications,
            confidence: 0.9,
            scanId: _scanId,
            safetyCheck: _clearCheck,
          ),
          confirmPrescription: (id, medications, token) {
            expect(id, _scanId);
            expect(medications.single['name'], 'Sample medicine');
            expect(token, isNull);
            return pending.future;
          },
        ),
      ),
    );

    await tester.tap(_button('Confirm and save'));
    await tester.pump();
    expect(tester.widget<NovaButton>(_button('Checking…')).onPressed, isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).readOnly,
      isTrue,
    );
    expect(HealthRepository.changes.value, before);

    pending.complete(_activated);
    await tester.pumpAndSettle();
    expect(HealthRepository.changes.value, before + 1);
    expect(find.text('Sample medicine added to Medications'), findsOneWidget);
  });

  testWidgets('safety warnings are shown and require acknowledgement', (
    tester,
  ) async {
    final tokens = <String?>[];
    final before = HealthRepository.changes.value;
    await tester.pumpWidget(
      NovaApp(
        home: ScanResultScreen(
          scan: const PrescriptionScan(
            medications: _medications,
            confidence: 0.9,
            scanId: _scanId,
            safetyCheck: _warningCheck,
          ),
          confirmPrescription: (id, medications, token) async {
            tokens.add(token);
            return token == null ? _needsReview : _activated;
          },
        ),
      ),
    );
    expect(find.text('Medication safety warnings'), findsOneWidget);
    expect(
      find.textContaining('High priority · ${_warning.message}'),
      findsOneWidget,
    );
    await tester.tap(_button('Confirm and save'));
    await tester.pumpAndSettle();
    expect(HealthRepository.changes.value, before);

    await tester.tap(_button('Review warnings'));
    await tester.pumpAndSettle();
    expect(find.text(_warning.message), findsOneWidget);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(tokens, [null]);

    await tester.tap(_button('Review warnings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acknowledge and save'));
    await tester.pumpAndSettle();
    expect(tokens, [null, 'reviewed-draft']);
    expect(HealthRepository.changes.value, before + 1);
  });

  testWidgets('unavailable check prevents activation and can be retried', (
    tester,
  ) async {
    var attempts = 0;
    final before = HealthRepository.changes.value;
    await tester.pumpWidget(
      NovaApp(
        home: ScanResultScreen(
          scan: const PrescriptionScan(
            medications: _medications,
            confidence: 0.9,
            scanId: _scanId,
          ),
          confirmPrescription: (id, medications, token) async {
            attempts++;
            return attempts == 1
                ? const PrescriptionConfirmation(
                    safetyCheck: PrescriptionSafetyCheck(),
                    activated: false,
                  )
                : _activated;
          },
        ),
      ),
    );
    expect(find.text('Safety check unavailable'), findsOneWidget);

    await tester.tap(_button('Retry safety check'));
    await tester.pumpAndSettle();
    expect(find.text('Safety check unavailable'), findsOneWidget);
    expect(HealthRepository.changes.value, before);

    await tester.tap(_button('Retry safety check'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(HealthRepository.changes.value, before + 1);
  });

  testWidgets(
    'an edit invalidates review and submits the current medication details',
    (tester) async {
      final drafts = <Map<String, dynamic>>[];
      final tokens = <String?>[];
      await tester.pumpWidget(
        NovaApp(
          home: ScanResultScreen(
            scan: const PrescriptionScan(
              medications: _medications,
              confidence: 0.9,
              scanId: _scanId,
              safetyCheck: _clearCheck,
            ),
            confirmPrescription: (_, medications, token) async {
              drafts.add(medications.single);
              tokens.add(token);
              return _needsReview;
            },
          ),
        ),
      );
      await tester.tap(_button('Confirm and save'));
      await tester.pumpAndSettle();
      expect(_button('Review warnings'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Edited medicine');
      await tester.enterText(fields.at(1), 'Edited strength');
      await tester.enterText(fields.at(2), 'twice daily');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Safety check required'), findsOneWidget);
      expect(_button('Review warnings'), findsNothing);

      await tester.tap(_button('Confirm and save'));
      await tester.pumpAndSettle();
      expect(tokens, [null, null]);
      expect(drafts.last['name'], 'Edited medicine');
      expect(drafts.last['dosage'], 'Edited strength');
      expect(drafts.last['times'], ['08:00', '20:00']);
    },
  );

  testWidgets('a scan without a server identifier cannot be activated', (
    tester,
  ) async {
    await tester.pumpWidget(
      const NovaApp(
        home: ScanResultScreen(
          scan: PrescriptionScan(medications: _medications, confidence: 0.9),
        ),
      ),
    );
    expect(find.text('Safety check unavailable'), findsOneWidget);
    expect(
      tester.widget<NovaButton>(_button('Confirm and save')).onPressed,
      isNull,
    );
  });
}
