import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter/widgets.dart';

/// Application diagnostics use fixed text. Never forward exception or stack objects.
void logAppEvent(String message) => developer.log(message, name: 'nova');

void installPrivacyDiagnostics(
  PlatformDispatcher dispatcher, {
  void Function(String) report = logAppEvent,
}) {
  // Some plugins write raw errors directly to debugPrint, even in release mode.
  debugPrint = (_, {wrapWidth}) {};
  FlutterError.onError = (_) => report('Flutter framework error.');
  dispatcher.onError = (_, __) {
    report('Unhandled application error.');
    return true;
  };
  ErrorWidget.builder = (_) => const Center(
        child: Text('This screen could not be displayed.',
            textDirection: TextDirection.ltr),
      );
}
