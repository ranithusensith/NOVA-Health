import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_health/data/health_repository.dart';
import 'package:nova_health/screens/medications_screen.dart';
import 'package:nova_health/screens/track_history.dart';
import 'package:nova_health/theme/nova_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('medical and tracking screens reload on edits, undo and resume',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final reads = <String>[];
    const owner = '00000000-0000-4000-8000-000000000001';
    await tester.runAsync(() async {
      await Supabase.initialize(
        url: 'https://supabase.invalid',
        publishableKey: 'synthetic-key',
        authOptions: const FlutterAuthClientOptions(
          localStorage: EmptyLocalStorage(),
          detectSessionInUri: false,
        ),
        httpClient: MockClient((request) async {
          if (request.url.host != 'supabase.invalid') {
            throw StateError('Unexpected host');
          }
          const headers = {'Content-Type': 'application/json'};
          if (request.url.path == '/auth/v1/token') {
            final expires = DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000;
            final claims = base64UrlEncode(
                utf8.encode(jsonEncode({'sub': owner, 'exp': expires})));
            return http.Response(
                jsonEncode({
                  'access_token': 'synthetic.$claims.signature',
                  'refresh_token': 'synthetic-refresh',
                  'token_type': 'bearer',
                  'expires_in': 3600,
                  'user': {
                    'id': owner,
                    'app_metadata': {},
                    'user_metadata': {}
                  },
                }),
                200,
                headers: headers,
                request: request);
          }
          reads.add(request.url.path);
          return http.Response('[]', 200, headers: headers, request: request);
        }),
      );
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'synthetic@example.invalid',
        password: 'synthetic-password',
      );
    });
    addTearDown(Supabase.instance.dispose);

    Future<void> show(Widget screen) => tester.pumpWidget(
          MaterialApp(theme: NovaTheme.light(), home: screen),
        );
    Future<void> change() async {
      HealthRepository.notifyChanged();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await show(
        const Scaffold(body: SingleChildScrollView(child: TrackHistory())));
    await tester.pumpAndSettle();
    final beforeHistory =
        reads.where((path) => path.endsWith('/water_logs')).length;
    await change(); // Same event emitted by a tracking save.
    expect(reads.where((path) => path.endsWith('/water_logs')).length,
        greaterThan(beforeHistory));

    await show(const MedicationsScreen());
    await tester.pumpAndSettle();
    final beforeMedicines =
        reads.where((path) => path.endsWith('/medications')).length;
    await change(); // A reviewed edit uses the same notification.
    await change(); // An undo changes the associated log.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(reads.where((path) => path.endsWith('/medications')).length,
        greaterThan(beforeMedicines));

    await show(
        const Scaffold(body: SingleChildScrollView(child: TrackHistory())));
    await tester.pumpAndSettle();
    await change();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
