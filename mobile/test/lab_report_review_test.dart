import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/lab_repository.dart';
import 'package:nova_health/data/scan_models.dart';
import 'package:nova_health/screens/report_result_screen.dart';
import 'package:nova_health/theme/nova_theme.dart';

void main() {
  final scan = ReportScan.fromJson({
    'scan_id': '00000000-0000-4000-8000-000000000603',
    'report_type': 'Synthetic report',
    'confidence': 0.8,
    'results': [
      {
        'test': 'Sample analyte',
        'value_text': '<=0.50',
        'unit': 'mg/L',
        'reference_text': '>=0.10 (method A)',
        'reported_flag': 'Check',
      },
      {'test': 'Unreadable result'},
    ],
  });

  testWidgets(
      'requires review and submits corrected selected text with an unknown date',
      (tester) async {
    Map<String, dynamic>? sent;
    await tester.pumpWidget(MaterialApp(
      theme: NovaTheme.light(),
      home: ReportResultScreen(
        scan: scan,
        onConfirm: (date, rows) async {
          sent = scan.toReviewedJson(
            expectedUserId: '00000000-0000-4000-8000-000000000601',
            reviewedDate: date,
            reviewedRows: rows,
          );
          return rows.length;
        },
      ),
    ));
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.textContaining('<=0.50 mg/L'), findsOneWidget);
    await tester.tap(find.text('Save 2 results'));
    expect(sent, isNull);

    await tester.tap(find.byTooltip('Edit Sample analyte'));
    await tester.pumpAndSettle();
    Finder field(String label) => find.widgetWithText(TextFormField, label);
    await tester.enterText(field('Printed result'), '<=');
    await tester.tap(find.text('Apply correction'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the complete result.'), findsOneWidget);
    await tester.enterText(field('Printed result'), '<=0.40');
    await tester.enterText(field('Unit'), 'µg/L');
    await tester.enterText(field('Reference range'), '>0.20');
    await tester.enterText(field('Printed flag'), '↑');
    await tester.tap(find.text('Apply correction'));
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate(
      (widget) =>
          widget is Checkbox &&
          widget.semanticLabel == 'Include Unreadable result',
    ));
    await tester.pumpAndSettle();
    final review =
        find.text('I checked the selected results against my report.');
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save 1 result'));
    await tester.pumpAndSettle();

    expect(sent?['report_date'], isNull);
    expect(sent?['reviewed'], true);
    expect(sent?['results'], [
      {
        'test': 'Sample analyte',
        'value_text': '<=0.40',
        'extracted_value_text': '<=0.50',
        'unit': 'µg/L',
        'reference_text': '>0.20',
        'reported_flag': '↑',
      },
    ]);
  });

  test(
      'medical records display the reviewed observation before numeric projections',
      () {
    const reviewed = LabRecord(
      id: 'reviewed',
      test: 'Synthetic',
      value: 1.2,
      valueText: '1.200',
      unit: 'mg/L',
      refLow: 0.4,
      referenceText: '>=0.40 (method A)',
      reportedFlag: 'Check',
      flag: 'unknown',
    );
    expect(reviewed.resultText, '1.200 mg/L');
    expect(reviewed.rangeText, '>=0.40 (method A)');
    expect(reviewed.reportedOn, isNull);
    const legacy =
        LabRecord(id: 'legacy', test: 'Synthetic', value: 1.2, flag: 'normal');
    expect(legacy.resultText, '1.2');
  });
}
