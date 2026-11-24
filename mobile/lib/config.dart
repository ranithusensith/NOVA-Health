import 'dart:convert';

/// Values come from --dart-define-from-file=dart_defines.json (never hardcode keys).
abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey =
      String.fromEnvironment('SUPABASE_KEY'); // publishable key only
  static const apiUrl =
      String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:8000');

  /// true = scans and chat return built-in sample data, so UI work needs no backend or AI key.
  static const useMockApi = bool.fromEnvironment('USE_MOCK_API');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && isSupabasePublicKey(supabaseKey);

  static bool isSupabasePublicKey(String key) {
    if (RegExp(r'^sb_publishable_[A-Za-z0-9_-]+$').hasMatch(key)) return true;
    // Legacy Supabase projects can still use a JWT with the anon role.
    if (!RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')
        .hasMatch(key)) {
      return false;
    }
    try {
      final encodedPayload = base64Url.normalize(key.split('.')[1]);
      final payload = jsonDecode(utf8.decode(base64Url.decode(encodedPayload)));
      return payload is Map<String, dynamic> && payload['role'] == 'anon';
    } on FormatException {
      return false;
    }
  }
}
