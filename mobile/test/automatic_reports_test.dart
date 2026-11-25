import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/screens/automatic_reports_screen.dart';
import 'package:nova_health/services/api_client.dart';
import 'package:nova_health/services/automatic_report_notices.dart';

class _ReportApi implements ApiClient {
  @override
  String? aiAccountId = 'synthetic-owner';
  String? zone;
  bool unavailable = false;
  final changes = <(String, bool, String?)>[];

  @override
  Future<Map<String, dynamic>> automaticReports() async {
    if (unavailable) throw ApiException('Synthetic outage');
    return {
      'time_zone': zone,
      'reports': [
        if (zone != null)
          {'local_date': '2026-03-08', 'time_zone': 'America/New_York'},
      ],
    };
  }

  @override
  Future<void> setAutomaticReports(String owner,
      {required bool enabled, String? timeZone}) async {
    changes.add((owner, enabled, timeZone));
    zone = enabled ? timeZone : null;
  }

  @override
  Future<String> savedAutomaticReport(String date) async =>
      'Synthetic saved report for $date. Sleep: unknown.';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('parallel checks, failures and restarts use one durable notice claim',
      () async {
    final delivered = <String>[];
    var permission = false;
    var failed = true;
    var consumed = false;
    var claims = 0;
    ReportNoticeCoordinator start() => ReportNoticeCoordinator(
          owner: () => 'synthetic-owner',
          eligible: (_) => true,
          permission: () async => permission,
          claim: (_) async {
            claims++;
            if (failed) throw StateError('Synthetic failure before claim');
            if (consumed) return false;
            consumed = true;
            return true;
          },
          deliver: (owner, current) async {
            if (current()) delivered.add(owner);
          },
        );

    final first = start();
    await first.refresh();
    expect(claims, 0);
    permission = true;
    await expectLater(first.refresh(), throwsStateError);
    failed = false;
    await Future.wait([first.refresh(), first.refresh()]);
    expect(claims, 2);
    await start().refresh();
    expect(delivered, ['synthetic-owner']);
  });

  test(
      'a pending claim cannot display after sign-out or a switch away and back',
      () async {
    final claim = Completer<bool>();
    final displayed = <String>[];
    String? owner = 'synthetic-owner';
    final service = ReportNoticeCoordinator(
      owner: () => owner,
      eligible: (_) => true,
      permission: () async => true,
      claim: (_) => claim.future,
      deliver: (owner, current) async => displayed.add(owner),
    );
    final pending = service.refresh();
    await Future<void>.delayed(Duration.zero);
    owner = null;
    service.invalidate();
    owner = 'synthetic-other';
    service.invalidate();
    owner = 'synthetic-owner';
    service.invalidate();
    claim.complete(true);
    await pending;
    expect(displayed, isEmpty);
  });

  testWidgets(
      'schedule requires opt-in, can adopt the device zone and can purge snapshots',
      (tester) async {
    final api = _ReportApi();
    String zone = 'America/New_York';
    await tester.pumpWidget(MaterialApp(
      home: AutomaticReportsScreen(api: api, deviceZone: () async => zone),
    ));
    await tester.pumpAndSettle();
    final toggle =
        find.widgetWithText(SwitchListTile, 'Generate daily reports');
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(api.changes, isEmpty);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(api.changes.single, ('synthetic-owner', true, 'America/New_York'));
    await tester.tap(find.text('2026-03-08'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sleep: unknown'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    zone = 'Asia/Colombo';
    await tester.tap(find.text('Use device zone'));
    await tester.pumpAndSettle();
    expect(api.changes.last, ('synthetic-owner', true, 'Asia/Colombo'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(api.changes.length, 2);
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(api.changes.last, ('synthetic-owner', false, null));
    expect(find.text('2026-03-08'), findsNothing);
  });

  testWidgets('an unavailable report index can be retried', (tester) async {
    final api = _ReportApi()..unavailable = true;
    await tester
        .pumpWidget(MaterialApp(home: AutomaticReportsScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Reports unavailable. Retry'), findsOneWidget);
    api.unavailable = false;
    await tester.tap(find.text('Reports unavailable. Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Generate daily reports'), findsOneWidget);
  });
}
