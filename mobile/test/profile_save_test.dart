import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_health/data/health_repository.dart';
import 'package:nova_health/data/profile_models.dart';
import 'package:nova_health/data/profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _account = '00000000-0000-0000-0000-000000000005';

void main() {
  late List<http.Request> requests;
  late List<http.Response> responses;
  late ProfileRepository repository;

  setUp(() {
    requests = [];
    responses = [];
    final client = SupabaseClient(
      'https://supabase.invalid',
      'sb_publishable_synthetic',
      httpClient: MockClient((request) async {
        requests.add(request);
        final response = responses.removeAt(0);
        return http.Response(response.body, response.statusCode,
            request: request);
      }),
    );
    addTearDown(client.dispose);
    repository = ProfileRepository(client: client);
  });

  test('save sends one transaction and only announces a confirmed response',
      () async {
    responses.addAll([
      http.Response(
          '{"code":"23514","message":"Synthetic database error"}', 400),
      http.Response('', 204),
    ]);
    final profile = HealthProfile(
      fullName: ' Synthetic Patient ',
      birthDate: DateTime(1995, 5, 5),
      sex: 'other',
      heightCm: 170,
      weightKg: 65,
      conditions: ['Synthetic condition'],
      medicalNotes: ' Synthetic notes ',
    );
    final changeCount = HealthRepository.changes.value;

    await expectLater(
      repository
          .save(profile, accountId: _account, allergies: ['Synthetic allergy']),
      throwsA(isA<PostgrestException>()),
    );
    expect(HealthRepository.changes.value, changeCount);
    expect(requests, hasLength(1));

    await repository
        .save(profile, accountId: _account, allergies: ['Synthetic allergy']);
    expect(HealthRepository.changes.value, changeCount + 1);
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/save_health_profile');
      expect(jsonDecode(request.body), {
        'p_expected_user_id': _account,
        'p_full_name': 'Synthetic Patient',
        'p_birth_date': '1995-05-05',
        'p_sex': 'other',
        'p_blood_type': null,
        'p_height_cm': 170,
        'p_weight_kg': 65,
        'p_conditions': ['Synthetic condition'],
        'p_medical_notes': 'Synthetic notes',
        'p_allergies': ['Synthetic allergy'],
      });
    }
  });

  test('skip saves only the name and onboarding choice for the loaded account',
      () async {
    responses.add(http.Response('[{"id":"$_account"}]', 200));
    await repository.skipOnboarding(' Synthetic Patient ', accountId: _account);
    final request = requests.single;
    expect(request.method, 'PATCH');
    expect(request.url.path, '/rest/v1/profiles');
    expect(request.url.queryParameters['id'], 'eq.$_account');
    expect(jsonDecode(request.body), {
      'full_name': 'Synthetic Patient',
      'onboarding_done': true,
    });
  });
}
