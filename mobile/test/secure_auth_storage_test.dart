import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/services/secure_auth_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _url = 'https://synthetic.supabase.invalid';
const _legacy = 'sb-synthetic-auth-token';
const _pkce = 'supabase.auth.token-code-verifier';
const _secureKey = 'nova.session.v1:$_url';
const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

String session(String owner, {String issuer = '$_url/auth/v1'}) {
  final claims =
      base64UrlEncode(utf8.encode(jsonEncode({'iss': issuer, 'sub': owner})));
  return jsonEncode({
    'access_token': 'synthetic.$claims.signature',
    'refresh_token': 'synthetic-refresh',
    'token_type': 'bearer',
    'user': {'id': owner, 'app_metadata': {}, 'user_metadata': {}},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final entries = <String, String>{};
  String? failure;

  setUp(() {
    entries.clear();
    failure = null;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == failure) {
        throw PlatformException(code: 'synthetic_failure');
      }
      final args = call.arguments as Map;
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return entries[key];
        case 'write':
          entries[key] = args['value'] as String;
          return null;
        case 'delete':
          entries.remove(key);
          return null;
      }
      throw MissingPluginException(call.method);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test(
      'migrates a matching legacy session and removes plaintext and the old verifier',
      () async {
    final legacy = session('synthetic-a');
    SharedPreferences.setMockInitialValues(
        {_legacy: legacy, _pkce: 'synthetic-verifier'});
    final storage =
        SecureAuthStorage(_url, verifyLegacyUser: (_) async => 'synthetic-a');
    await storage.initialize();
    expect(await storage.accessToken(), legacy);
    expect(entries[_secureKey], legacy);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(_legacy), isFalse);
    expect(prefs.containsKey(_pkce), isFalse);
  });

  test(
      'a secure account wins over legacy data, and foreign or malformed data cannot migrate',
      () async {
    final current = session('synthetic-b');
    entries[_secureKey] = current;
    SharedPreferences.setMockInitialValues({_legacy: session('synthetic-a')});
    var storage = SecureAuthStorage(_url);
    await storage.initialize();
    expect(await storage.accessToken(), current);
    for (final candidate in [
      session('synthetic-a', issuer: 'https://other.invalid/auth/v1'),
      'broken'
    ]) {
      entries.clear();
      SharedPreferences.setMockInitialValues({_legacy: candidate});
      storage = SecureAuthStorage(_url);
      await storage.initialize();
      expect(await storage.accessToken(), isNull);
      expect((await SharedPreferences.getInstance()).containsKey(_legacy),
          isFalse);
    }
  });

  test('storage options are device-only on iOS and encrypted on Android', () {
    final ios = deviceAuthVault.iOptions.toMap();
    expect(ios['accessibility'], 'unlocked_this_device');
    expect(ios['synchronizable'], 'false');
    expect(
        deviceAuthVault.aOptions.toMap()['encryptedSharedPreferences'], 'true');
  });

  test('restart, account replacement, PKCE and sign-out use scoped secure keys',
      () async {
    final storage = SecureAuthStorage(_url);
    await storage.initialize();
    final first = storage.persistSession(session('synthetic-a'));
    final second = storage.persistSession(session('synthetic-b'));
    await Future.wait([first, second]);
    await storage.pkceStorage.setItem(key: _pkce, value: 'synthetic-verifier');
    final restarted = SecureAuthStorage(_url);
    await restarted.initialize();
    expect(await restarted.accessToken(), session('synthetic-b'));
    expect(
        await restarted.pkceStorage.getItem(key: _pkce), 'synthetic-verifier');
    final other = SecureAuthStorage('https://synthetic.other.invalid');
    await other.initialize();
    expect(await other.hasAccessToken(), isFalse);
    await restarted.removePersistedSession();
    expect(await restarted.hasAccessToken(), isFalse);
    expect(await restarted.pkceStorage.getItem(key: _pkce), isNull);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('failed secure logout cannot restore the old account on restart',
      () async {
    final storage = SecureAuthStorage(_url);
    await storage.initialize();
    await storage.persistSession(session('synthetic-a'));
    failure = 'delete';
    await expectLater(
        storage.removePersistedSession(), throwsA(isA<PlatformException>()));
    expect(await storage.hasAccessToken(), isFalse);
    failure = null;
    final restarted = SecureAuthStorage(_url);
    await restarted.initialize();
    expect(await restarted.hasAccessToken(), isFalse);
    expect(entries, isEmpty);
  });

  test('failed migration removes the plaintext and requires sign-in', () async {
    SharedPreferences.setMockInitialValues({_legacy: session('synthetic-a')});
    failure = 'write';
    final storage =
        SecureAuthStorage(_url, verifyLegacyUser: (_) async => 'synthetic-a');
    await storage.initialize();
    expect(await storage.hasAccessToken(), isFalse);
    expect(
        (await SharedPreferences.getInstance()).containsKey(_legacy), isFalse);
  });

  test('legacy identity must be confirmed by the configured Auth project',
      () async {
    for (final verify in <Future<String?> Function(String)>[
      (_) async => 'synthetic-other',
      (_) async => throw StateError('Synthetic Auth unavailable'),
    ]) {
      SharedPreferences.setMockInitialValues({_legacy: session('synthetic-a')});
      final storage = SecureAuthStorage(_url, verifyLegacyUser: verify);
      await storage.initialize();
      expect(await storage.hasAccessToken(), isFalse);
      expect((await SharedPreferences.getInstance()).containsKey(_legacy),
          isFalse);
      expect(entries, isEmpty);
    }
  });
}
