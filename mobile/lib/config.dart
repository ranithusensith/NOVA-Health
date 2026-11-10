/// Values come from --dart-define-from-file=dart_defines.json (never hardcode keys).
abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_KEY'); // publishable key only
  static const apiUrl =
      String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:8000');

  /// true = scans and chat return built-in sample data, so UI work needs no backend or AI key.
  static const useMockApi = bool.fromEnvironment('USE_MOCK_API');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;
}
