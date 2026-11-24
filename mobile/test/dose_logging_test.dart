import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_health/data/care_models.dart';
import 'package:nova_health/data/care_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _alice = '00000000-0000-0000-0000-000000000007';
const _bob = '00000000-0000-0000-0000-000000000008';
const _medication = '00000000-0000-0000-0000-000000000107';
const _log = '00000000-0000-0000-0000-000000000207';

void main() {
  late List<http.Request> requests;
  late List<({String body, int code})> responses;
  late CareRepository repository;

  setUp(() async {
    requests = [];
    responses = [];
    final expires = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    final token = base64Url.encode(utf8.encode(jsonEncode({'exp': expires}))).replaceAll('=', '');
    final client = SupabaseClient('https://supabase.invalid', 'sb_publishable_synthetic',
      httpClient: MockClient((request) async {
        if (request.url.path == '/auth/v1/token') {
          return http.Response(jsonEncode({
            'access_token': 'e30.$token.synthetic',
            'token_type': 'bearer',
            'user': {'id': _alice, 'aud': 'authenticated', 'created_at': '2026-11-01T00:00:00Z'},
          }), 200, request: request, headers: {'content-type': 'application/json'});
        }
        requests.add(request);
        final response = responses.removeAt(0);
        return http.Response(response.body, response.code, request: request);
      }),
    );
    addTearDown(client.dispose);
    await client.auth.signInWithPassword(email: 'synthetic@example.test', password: 'synthetic');
    repository = CareRepository(client: client);
  });

  test('logging and retries use the selected schedule and Undo targets its returned log', () async {
    final selectedTime = DateTime(2026, 11, 1, 21);
    final occurrence = DoseOccurrence(
      accountId: _alice, medicationId: _medication, at: selectedTime, followsLocalClock: true,
    );
    responses.addAll([
      (body: '[{"id":"$_log"}]', code: 201),
      (body: '[]', code: 201),
      (body: '', code: 204),
    ]);

    expect(await repository.logDose(occurrence), _log);
    expect(await repository.logDose(occurrence), isNull);
    await repository.undoDose(occurrence, _log);

    final [insert, retry, undo] = requests;
    expect(insert.method, 'POST');
    expect(insert.url.path, '/rest/v1/medication_logs');
    expect(insert.url.queryParameters['on_conflict'], 'user_id,medication_id,occurrence_key');
    expect(insert.headers['Prefer'], contains('resolution=ignore-duplicates'));
    expect(retry.url, insert.url);
    expect(retry.body, insert.body);
    expect(jsonDecode(insert.body), {
      'user_id': _alice,
      'medication_id': _medication,
      'scheduled_at': selectedTime.toUtc().toIso8601String(),
      'scheduled_local_at': '2026-11-01T21:00:00.000',
      'status': 'taken',
    });
    expect(undo.method, 'DELETE');
    expect(undo.url.queryParameters, {
      'user_id': 'eq.$_alice',
      'medication_id': 'eq.$_medication',
      'occurrence_key': 'eq.${occurrence.key.occurrenceKey}',
      'id': 'eq.$_log',
    });
  });

  test('an occurrence loaded under another account cannot be logged or undone', () async {
    final oldOccurrence = DoseOccurrence(
      accountId: _bob, medicationId: _medication, at: DateTime.utc(2026, 11, 1), followsLocalClock: false,
    );
    await expectLater(repository.logDose(oldOccurrence), throwsStateError);
    await expectLater(repository.undoDose(oldOccurrence, _log), throwsStateError);
    expect(requests, isEmpty);
  });
}
