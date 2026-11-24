import 'dart:convert';
import 'dart:io';

import 'package:nova_health/config.dart';

void main() {
  try {
    final config =
        releaseConfigFromDefines(Platform.environment['DART_DEFINES'] ?? '');
    final problem = config.problem;
    if (problem == null) return;
    stderr.writeln('error: NOVA build configuration: $problem');
  } on FormatException {
    stderr.writeln(
        'error: NOVA build configuration: Invalid or duplicate Dart definitions.');
  }
  exitCode = 1;
}

/// Flutter forwards a comma-separated list of base64-encoded KEY=VALUE entries.
AppConfig releaseConfigFromDefines(String encoded) {
  const keys = {'SUPABASE_URL', 'SUPABASE_KEY', 'API_URL', 'USE_MOCK_API'};
  final values = <String, String>{};
  for (final entry in encoded.isEmpty ? const <String>[] : encoded.split(',')) {
    final definition = utf8.decode(base64.decode(entry));
    final separator = definition.indexOf('=');
    if (separator < 1) throw const FormatException('Invalid Dart definition');
    final key = definition.substring(0, separator);
    if (key == 'dart.vm.product' || key == 'dart.vm.profile') {
      throw const FormatException('Cannot override the Flutter build mode');
    }
    if (!keys.contains(key)) continue;
    if (values.containsKey(key)) {
      throw const FormatException('Duplicate NOVA definition');
    }
    values[key] = definition.substring(separator + 1);
  }
  return AppConfig(
    isDebug: false,
    supabaseUrl: values['SUPABASE_URL'] ?? '',
    supabaseKey: values['SUPABASE_KEY'] ?? '',
    apiUrl: values['API_URL'] ?? '',
    mockFlag: values['USE_MOCK_API'] ?? 'false',
  );
}
