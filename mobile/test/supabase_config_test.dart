import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/config.dart';

void main() {
  String syntheticJwt(String role) {
    final payload = base64Url.encode(utf8.encode(jsonEncode({'role': role})));
    return 'e30.${payload.replaceAll('=', '')}.synthetic';
  }

  test('only publishable and legacy anon keys may initialize Supabase', () {
    expect(AppConfig.isSupabasePublicKey('sb_publishable_synthetic'), isTrue);
    expect(AppConfig.isSupabasePublicKey(syntheticJwt('anon')), isTrue);
    for (final key in [
      '',
      'sb_secret_synthetic',
      syntheticJwt('service_role'),
      syntheticJwt('authenticated'),
      'e30.invalid.synthetic',
    ]) {
      expect(AppConfig.isSupabasePublicKey(key), isFalse);
    }
  });
}
