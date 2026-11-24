import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_health/data/symptom_repository.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/symptoms_screen.dart';
import 'package:nova_health/widgets/content.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _owner = '00000000-0000-0000-0000-000000000131';
const _other = '00000000-0000-0000-0000-000000000132';
const _entry = '00000000-0000-0000-0000-000000000133';

class _Store implements SymptomStore {
  final records = <SymptomRecord>[];
  int saves = 0;

  @override
  Future<List<SymptomRecord>> history({SymptomRecord? after}) async =>
      records.toList();

  @override
  Future<void> save(SymptomDraft draft,
      {required String entryId, SymptomRecord? existing}) async {
    saves++;
    records.removeWhere((record) => record.id == entryId);
    records.add(SymptomRecord(
      id: entryId,
      revision: 'synthetic-revision-$saves',
      name: draft.name,
      onset: draft.onset,
      status: draft.status,
      severity: draft.severity,
      notes: draft.notes,
    ));
  }

  @override
  Future<void> delete(SymptomRecord record) async => records.remove(record);
}

Finder _button(String label) => find.widgetWithText(NovaButton, label);

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(_button(label));
  await tester.tap(_button(label));
  await tester.pumpAndSettle();
}

Future<void> _open(
  WidgetTester tester,
  _Store store, {
  Future<String?> Function(SymptomDraft)? check,
  Future<bool> Function()? call,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(750, 1100);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(NovaApp(
      home: SymptomsScreen(
    store: store,
    checkEmergency: check ?? (_) async => null,
    callAmbulance: call ?? () async => true,
  )));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('creates, edits, resolves, shows history, and confirms deletion',
      (tester) async {
    final store = _Store();
    final checked = <SymptomDraft>[];
    await _open(tester, store, check: (draft) async {
      checked.add(draft);
      return null;
    });

    expect(find.text('No symptoms recorded yet.'), findsOneWidget);
    await _tap(tester, 'Log symptom');
    await _tap(tester, 'Save symptom');
    expect(find.textContaining('Enter a symptom type'), findsOneWidget);
    expect(store.records, isEmpty);
    await tester.enterText(
        find.byType(TextField).first, 'Synthetic discomfort');
    await tester.enterText(find.byType(TextField).last, 'Synthetic notes');
    await tester.tap(find.text('Severity unknown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moderate').last);
    await tester.pumpAndSettle();
    await _tap(tester, 'Save symptom');
    final created = store.records.single;
    expect(created.onset, isNotNull);
    expect(created.severity, SymptomSeverity.moderate);
    expect(checked, hasLength(1));
    expect(find.textContaining('Synthetic notes'), findsOneWidget);

    await tester.tap(find.text('Synthetic discomfort'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).first, 'Synthetic corrected discomfort');
    await tester.tap(find.text('Active'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resolved').last);
    await tester.pumpAndSettle();
    await _tap(tester, 'Save symptom');
    expect(store.records.single.id, created.id);
    expect(store.records.single.onset, created.onset);
    expect(store.records.single.status, SymptomStatus.resolved);
    expect(checked, hasLength(1));
    expect(find.textContaining('Moderate · Resolved'), findsOneWidget);

    await tester.tap(find.text('Synthetic corrected discomfort'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Delete symptom');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.records, hasLength(1));
    await _tap(tester, 'Delete symptom');
    await tester.tap(find.text('Delete entry'));
    await tester.pumpAndSettle();
    expect(store.records, isEmpty);
    expect(find.text('No symptoms recorded yet.'), findsOneWidget);
  });

  testWidgets(
      'recent urgent text offers dialing before an explicit save decision',
      (tester) async {
    final store = _Store();
    var calls = 0;
    await _open(tester, store,
        check: (_) async => 'Synthetic emergency guidance. Call 1990.',
        call: () async {
          calls++;
          return true;
        });
    await _tap(tester, 'Log symptom');
    await tester.enterText(
        find.byType(TextField).first, 'Synthetic urgent observation');
    await _tap(tester, 'Save symptom');
    expect(find.text('Symptom safety'), findsOneWidget);
    expect(store.saves, 0);
    expect(calls, 0);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Call 1990 (Sri Lanka)')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.tap(find.text('Continue to save'));
    await tester.pumpAndSettle();
    expect(store.saves, 1);
  });

  testWidgets('safety service failure leaves emergency guidance available',
      (tester) async {
    final store = _Store();
    await _open(tester, store,
        check: (_) async => throw StateError('Synthetic network failure'));
    await _tap(tester, 'Log symptom');
    await tester.enterText(
        find.byType(TextField).first, 'Synthetic observation');
    await _tap(tester, 'Save symptom');
    expect(
        find.textContaining('NOVA could not check this entry'), findsOneWidget);
    expect(store.records, isEmpty);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Save symptom'), findsOneWidget);
  });

  testWidgets(
      'legacy records show unknown fields and need a selected status to edit',
      (tester) async {
    final record = SymptomRecord.fromJson({
      'id': _entry,
      'revision': _entry,
      'name': 'Synthetic legacy symptom',
      'severity': 'unknown',
      'status': 'legacy',
    });
    final store = _Store()..records.add(record);
    await _open(tester, store);
    expect(find.textContaining('Onset unknown'), findsOneWidget);
    expect(find.textContaining('Severity unknown · Status unknown'),
        findsOneWidget);
    await tester.tap(find.text('Synthetic legacy symptom'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Save symptom');
    expect(store.saves, 0);
  });

  test('history, edits and deletion use the pinned account and stale revision',
      () async {
    final requests = <http.Request>[];
    final responses = <http.Response>[];
    final client =
        SupabaseClient('https://supabase.invalid', 'sb_publishable_synthetic',
            httpClient: MockClient((request) async {
      if (request.url.path == '/auth/v1/token') {
        final token = base64Url.encode(utf8.encode(jsonEncode({
          'sub': _owner,
          'exp': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
        })));
        return http.Response(
            jsonEncode({
              'access_token': 'e30.$token.synthetic',
              'token_type': 'bearer',
              'expires_in': 3600,
              'refresh_token': 'synthetic',
              'user': {
                'id': _owner,
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z'
              },
            }),
            200,
            request: request);
      }
      requests.add(request);
      final result = responses.removeAt(0);
      return http.Response(result.body, result.statusCode, request: request);
    }));
    addTearDown(client.dispose);
    await client.auth.signInWithPassword(
        email: 'synthetic@example.test', password: 'synthetic');
    final repository = SymptomRepository(client, _owner);
    final existing = SymptomRecord(
        id: _entry,
        revision: _entry,
        name: 'Synthetic',
        onset: DateTime.utc(2026, 1, 1),
        status: SymptomStatus.active);
    final draft = SymptomDraft(
        name: 'Synthetic corrected',
        onset: existing.onset!,
        status: SymptomStatus.resolved);

    await expectLater(SymptomRepository(client, _other).history(),
        throwsA(isA<SymptomChangesException>()));
    expect(requests, isEmpty);
    responses.addAll([
      http.Response('[]', 200),
      http.Response('', 201),
      http.Response('[]', 200),
      http.Response('[{"id":"$_entry"}]', 200)
    ]);
    await repository.history(after: existing);
    await repository.save(draft, entryId: _entry);
    await expectLater(
        repository.save(draft, entryId: _entry, existing: existing),
        throwsA(isA<SymptomChangesException>()));
    await repository.delete(existing);
    expect(requests.map((request) => request.method),
        ['GET', 'POST', 'PATCH', 'DELETE']);
    expect(requests.first.url.queryParameters['or'], contains('id.lt.$_entry'));
    expect(jsonDecode(requests[1].body)['user_id'], _owner);
    expect(jsonDecode(requests[1].body)['status'], 'resolved');
    for (final request in [requests[0], requests[2], requests[3]]) {
      expect(request.url.queryParameters['user_id'], 'eq.$_owner');
    }
    for (final request in requests.skip(2)) {
      expect(request.url.queryParameters['id'], 'eq.$_entry');
      expect(request.url.queryParameters['revision'], 'eq.$_entry');
    }
  });
}
