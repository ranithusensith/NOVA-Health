import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'privacy_diagnostics.dart';

// Use the same Android options as the emergency cache. The pinned plugin
// shares one native storage instance and has separate keys for each item.
const deviceAuthVault = FlutterSecureStorage(
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
    sharedPreferencesName: 'NovaEmergencyContacts',
  ),
  iOptions: IOSOptions(
    accountName: 'nova.auth',
    accessibility: KeychainAccessibility.unlocked_this_device,
  ),
);

class SecureAuthStorage extends LocalStorage {
  SecureAuthStorage(
    String projectUrl, {
    FlutterSecureStorage storage = deviceAuthVault,
    Future<String?> Function(String accessToken)? verifyLegacyUser,
  })  : _project = Uri.parse(projectUrl),
        _storage = storage,
        _verifyLegacyUser = verifyLegacyUser;

  static final device = SecureAuthStorage(
    AppConfig.current.supabaseUrl,
    verifyLegacyUser: (token) async => (await Supabase.instance.client.auth
            .getUser(token)
            .timeout(const Duration(seconds: 8)))
        .user
        ?.id,
  );
  static const _legacyVerifier = 'supabase.auth.token-code-verifier';
  final Uri _project;
  final FlutterSecureStorage _storage;
  final Future<String?> Function(String accessToken)? _verifyLegacyUser;
  SharedPreferences? _prefs;
  Future<void> _tail = Future.value();

  String get _legacyKey => 'sb-${_project.host.split('.').first}-auth-token';
  String get _sessionKey => 'nova.session.v1:${_project.origin}';
  String get _blockedKey => 'nova.session.purge-pending:${_project.origin}';
  GotrueAsyncStorage get pkceStorage =>
      _SecurePkceStorage(_storage, _project.origin);

  Future<T> _queue<T>(Future<T> Function() work) {
    final operation = _tail.then((_) => work());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _removePreference(SharedPreferences prefs, String key) async {
    if (prefs.containsKey(key) && !await prefs.remove(key)) {
      throw StateError('Could not remove legacy authentication state.');
    }
  }

  Future<void> _block(SharedPreferences prefs) async {
    if (!await prefs.setBool(_blockedKey, true)) {
      throw StateError('Could not persist the session recovery fence.');
    }
  }

  Future<bool> _belongsToProject(String raw) async {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final session = Session.fromJson(data);
      if (session == null ||
          (session.refreshToken?.isEmpty ?? true) ||
          session.user.id.isEmpty) {
        return false;
      }
      final parts = session.accessToken.split('.');
      if (parts.length != 3) return false;
      final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return claims is Map &&
          claims['iss'] == '${_project.origin}/auth/v1' &&
          claims['sub'] == session.user.id &&
          await _verifyLegacyUser?.call(session.accessToken) == session.user.id;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> initialize() => _queue(() async {
        try {
          final prefs = _prefs = await SharedPreferences.getInstance();
          // An unfinished write or logout must never revive a previous session.
          if (prefs.getBool(_blockedKey) == true) {
            await _purge(prefs);
            return;
          }
          final legacy = prefs.get(_legacyKey);
          await _removePreference(prefs, _legacyVerifier);
          if (legacy == null) return;
          await _block(prefs);
          final existing = await _storage.read(key: _sessionKey);
          await _removePreference(prefs, _legacyKey);
          if (existing == null &&
              legacy is String &&
              await _belongsToProject(legacy)) {
            await _storage.write(key: _sessionKey, value: legacy);
          }
          await _removePreference(prefs, _blockedKey);
        } catch (_) {
          final prefs = _prefs;
          if (prefs != null) {
            try {
              await _purge(prefs);
            } catch (_) {
              _prefs = null;
            }
          }
          logAppEvent(
              'Stored authentication could not be recovered. Sign in again.');
        }
      });

  Future<void> _purge(SharedPreferences prefs) async {
    await _block(prefs);
    await _removePreference(prefs, _legacyKey);
    await _removePreference(prefs, _legacyVerifier);
    await _storage.delete(key: _sessionKey);
    await pkceStorage.removeItem(key: _legacyVerifier);
    await _removePreference(prefs, _blockedKey);
  }

  @override
  Future<String?> accessToken() => _queue(() async {
        final prefs = _prefs;
        if (prefs == null || prefs.getBool(_blockedKey) == true) return null;
        try {
          return await _storage.read(key: _sessionKey);
        } catch (_) {
          try {
            await _purge(prefs);
          } catch (_) {
            // Keep the recovery fence for the next launch.
          }
          logAppEvent('Secure authentication storage could not be read.');
          return null;
        }
      });

  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;

  @override
  Future<void> persistSession(String persistSessionString) => _queue(() async {
        final prefs = _prefs;
        if (prefs == null) return;
        await _block(prefs);
        await _storage.write(key: _sessionKey, value: persistSessionString);
        await _removePreference(prefs, _blockedKey);
      });

  @override
  Future<void> removePersistedSession() => _queue(() async {
        final prefs = _prefs;
        if (prefs != null) await _purge(prefs);
      });
}

class _SecurePkceStorage extends GotrueAsyncStorage {
  _SecurePkceStorage(this._storage, this._project);
  final FlutterSecureStorage _storage;
  final String _project;

  String _key(String key) => 'nova.auth.pkce:$_project:$key';

  @override
  Future<String?> getItem({required String key}) =>
      _storage.read(key: _key(key));

  @override
  Future<void> removeItem({required String key}) =>
      _storage.delete(key: _key(key));

  @override
  Future<void> setItem({required String key, required String value}) =>
      _storage.write(key: _key(key), value: value);
}
