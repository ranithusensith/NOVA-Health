import 'dart:convert';

/// Compile-time configuration. The same validation runs at startup and before
/// native profile and release builds compile the application.
class AppConfig {
  const AppConfig({
    required this.isDebug,
    this.supabaseUrl = '',
    this.supabaseKey = '',
    this.apiUrl = '',
    this.mockFlag = 'false',
  });

  static const current = AppConfig(
    isDebug: !bool.fromEnvironment('dart.vm.product') &&
        !bool.fromEnvironment('dart.vm.profile'),
    supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
    supabaseKey: String.fromEnvironment('SUPABASE_KEY'),
    apiUrl: String.fromEnvironment('API_URL'),
    mockFlag: String.fromEnvironment('USE_MOCK_API', defaultValue: 'false'),
  );

  final bool isDebug;
  final String supabaseUrl;
  final String supabaseKey;
  final String apiUrl;
  final String mockFlag;

  bool get isDemo => isDebug && mockFlag == 'true';
  bool get canConnect => !isDemo && problem == null;

  String get apiBase =>
      (isDebug && apiUrl.isEmpty ? 'http://127.0.0.1:8000' : apiUrl)
          .replaceFirst(RegExp(r'/+$'), '');

  /// Fixed messages only. Configuration values may contain credentials.
  String? get problem {
    if (mockFlag != 'true' && mockFlag != 'false') {
      return 'USE_MOCK_API must be true or false.';
    }
    if (mockFlag == 'true') {
      return isDebug ? null : 'Demo mode is available only in debug builds.';
    }
    if (!_validEndpoint(supabaseUrl, allowPath: false)) {
      return 'Set SUPABASE_URL to a valid HTTPS project URL.';
    }
    if (!isSupabasePublicKey(supabaseKey) ||
        supabaseKey == 'sb_publishable_xxx') {
      return 'Set SUPABASE_KEY to a project publishable or legacy anon key.';
    }
    if (!_validEndpoint(apiBase, allowPath: true)) {
      return 'Set API_URL to a valid HTTPS NOVA backend URL.';
    }
    return null;
  }

  bool _validEndpoint(String value, {required bool allowPath}) {
    if (RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value)) return false;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (!allowPath && uri.path.isNotEmpty && uri.path != '/')) {
      return false;
    }
    if (uri.port < 1 || uri.port > 65535) return false;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.isEmpty || host.contains('_')) return false;
    const debugHttpHosts = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
    if (uri.scheme == 'http') return isDebug && debugHttpHosts.contains(host);
    if (uri.scheme != 'https') return false;
    if (isDebug) return true;
    return !debugHttpHosts.contains(host) &&
        !host.endsWith('.localhost') &&
        !host.startsWith('127.') &&
        !const {'0.0.0.0', '::', '10.0.2.3'}.contains(host);
  }

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
