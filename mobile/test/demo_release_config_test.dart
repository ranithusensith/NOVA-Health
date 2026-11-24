import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/auth_gate.dart';
import 'package:nova_health/config.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/demo_home.dart';
import 'package:nova_health/services/api_client.dart';

import '../tool/validate_release_config.dart';

const _settings = {
  'SUPABASE_URL': 'https://supabase-synthetic.invalid',
  'SUPABASE_KEY': 'sb_publishable_synthetic',
  'API_URL': 'https://nova-synthetic.invalid',
};

AppConfig _config(
    {bool isDebug = false, Map<String, String> defines = const {}}) {
  final settings = {..._settings, ...defines};
  return AppConfig(
    isDebug: isDebug,
    supabaseUrl: settings['SUPABASE_URL']!,
    supabaseKey: settings['SUPABASE_KEY']!,
    apiUrl: settings['API_URL']!,
    mockFlag: settings['USE_MOCK_API'] ?? 'false',
  );
}

String _encode(Iterable<String> defines) =>
    defines.map((entry) => base64.encode(utf8.encode(entry))).join(',');

void main() {
  test('real production configuration requires explicit HTTPS and a client key',
      () {
    expect(_config().canConnect, isTrue);
    for (final settings in [
      {'API_URL': ''},
      {'API_URL': 'http://nova-synthetic.invalid'},
      {'SUPABASE_URL': 'http://supabase-synthetic.invalid'},
      {'API_URL': 'http://127.0.0.1:8000'},
      {'API_URL': 'https://localhost:8000'},
      {'API_URL': 'https://user:private-value@nova-synthetic.invalid'},
      {'API_URL': 'https://nova-synthetic.invalid?key=private-value'},
      {'SUPABASE_URL': 'https://supabase-synthetic.invalid/#private-value'},
      {'SUPABASE_KEY': 'sb_secret_private-value'},
      {'SUPABASE_KEY': 'sb_publishable_xxx'},
      {'SUPABASE_KEY': 'e30.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.synthetic'},
      {'USE_MOCK_API': 'TRUE'},
    ]) {
      final candidate = _config(defines: settings);
      expect(candidate.canConnect, isFalse, reason: settings.keys.join());
      expect(candidate.problem, isNot(contains('private-value')));
    }
  });

  test(
      'only debug real mode supports loopback HTTP and an implicit local backend',
      () {
    expect(_config(isDebug: true, defines: {'API_URL': ''}).apiBase,
        'http://127.0.0.1:8000');
    expect(
        _config(isDebug: true, defines: {'API_URL': 'http://10.0.2.2:8000/'})
            .canConnect,
        isTrue);
    expect(
        _config(
            isDebug: true,
            defines: {'API_URL': 'http://nova-synthetic.invalid'}).canConnect,
        isFalse);
  });

  test('the native build validator uses the same policy and rejects overrides',
      () {
    final definitions =
        _settings.entries.map((entry) => '${entry.key}=${entry.value}');
    expect(
        releaseConfigFromDefines(_encode([...definitions, 'EXTRA=a=b']))
            .canConnect,
        isTrue);
    expect(releaseConfigFromDefines('').canConnect, isFalse);
    expect(
        releaseConfigFromDefines(_encode([...definitions, 'USE_MOCK_API=true']))
            .problem,
        'Demo mode is available only in debug builds.');
    expect(() => releaseConfigFromDefines('not valid base64'),
        throwsFormatException);
    expect(
        () => releaseConfigFromDefines(
            _encode([...definitions, 'API_URL=https://duplicate.invalid'])),
        throwsFormatException);
    expect(
        () => releaseConfigFromDefines(
            _encode([...definitions, 'dart.vm.product=false'])),
        throwsFormatException);
  });

  final demo = _config(isDebug: true, defines: {'USE_MOCK_API': 'true'});
  test('demo ignores configured real endpoints and skips real startup hooks',
      () async {
    expect(demo.isDemo, isTrue);
    expect(demo.canConnect, isFalse);
    final app = await prepareNovaApp(
      demo,
      initializeSupabase: (_) async =>
          fail('Demo must not initialize Supabase.'),
      initializeReminders: () async =>
          fail('Demo must not touch real reminders.'),
    );
    expect(app.demoMode, isTrue);
    expect(app.home, isA<DemoHome>());
  });

  test(
      'a profile or release requesting demo fails closed even with valid real endpoints',
      () async {
    final release = _config(defines: {'USE_MOCK_API': 'true'});
    final app = await prepareNovaApp(
      release,
      initializeSupabase: (_) async =>
          fail('Invalid release must not initialize Supabase.'),
      initializeReminders: () async {},
    );
    expect(release.isDemo, isFalse);
    expect(app.home, isA<ConfigurationErrorScreen>());
  });

  test(
      'a new real startup initializes only its real settings after a demo startup',
      () async {
    final starts = <AppConfig>[];
    var reminderStarts = 0;
    Future<NovaApp> start(AppConfig settings) => prepareNovaApp(
          settings,
          initializeSupabase: (configuration) async =>
              starts.add(configuration),
          initializeReminders: () async {
            reminderStarts++;
          },
        );
    final demoApp = await start(demo);
    final real = _config();
    final realApp = await start(real);
    expect(demoApp.key, isNot(realApp.key));
    expect(realApp.demoMode, isFalse);
    expect(realApp.home, isA<AuthGate>());
    expect(starts, [real]);
    expect(reminderStarts, 1);
  });

  testWidgets(
      'demo scan saves stay in memory and do not survive an app transition',
      (tester) async {
    Future<NovaApp> start(AppConfig settings) => prepareNovaApp(
          settings,
          initializeSupabase: (_) async =>
              fail('Unexpected database initialization.'),
          initializeReminders: () async {},
        );
    await tester.pumpWidget(await start(demo));
    expect(find.text('Demo mode'), findsOneWidget);
    await tester.tap(find.text('Preview lab report'));
    await tester.pumpAndSettle();
    expect(find.textContaining('≤0.40'), findsOneWidget);
    final save = find.text('Save to demo');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Lab report'), findsOneWidget);

    await tester.pumpWidget(await start(const AppConfig(isDebug: true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not start'), findsOneWidget);
    expect(find.text('Lab report'), findsNothing);
    await tester.pumpWidget(await start(demo));
    await tester.pumpAndSettle();
    expect(find.text('No demo samples saved.'), findsOneWidget);
  });

  test(
      'real scan API calls fail before touching auth when no real mode is configured',
      () async {
    // Also run this suite with USE_MOCK_API=true and synthetic real endpoint definitions.
    expect(AppConfig.current.canConnect, isFalse);
    final api = ApiClient.instance;
    expect(api.aiAccountId, isNull);
    await expectLater(
        api.scanPrescription('Synthetic scan'), throwsA(isA<ApiException>()));
  });
}
