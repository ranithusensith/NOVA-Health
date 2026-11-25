import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_gate.dart';
import 'config.dart';
import 'data/app_prefs.dart';
import 'screens/demo_home.dart';
import 'services/automatic_report_notices.dart';
import 'services/emergency_service.dart';
import 'services/outdoor_alerts.dart';
import 'services/privacy_diagnostics.dart';
import 'services/reminder_service.dart';
import 'theme/nova_settings.dart';
import 'theme/nova_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installPrivacyDiagnostics(PlatformDispatcher.instance);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  const config = AppConfig.current;
  if (!config.isDemo) await AppPrefs.instance.load();
  final app = await prepareNovaApp(
    config,
    initializeSupabase: (settings) async {
      await Supabase.initialize(
        url: settings.supabaseUrl,
        publishableKey: settings.supabaseKey,
        debug: false,
      );
      EmergencyService.instance.attach();
    },
    initializeReminders: () async {
      // Clear unaffiliated notifications even when the app has no configured session.
      await ReminderService.instance.init();
      if (config.canConnect) {
        ReminderService.instance.attach();
        await AutomaticReportNotices.instance.attach();
        await OutdoorAlerts.instance.attach();
      }
    },
  );
  runApp(app);
}

Future<NovaApp> prepareNovaApp(
  AppConfig config, {
  required Future<void> Function(AppConfig) initializeSupabase,
  required Future<void> Function() initializeReminders,
}) async {
  if (config.isDemo) {
    return const NovaApp(key: ValueKey('demo'), home: DemoHome(), demoMode: true);
  }
  final problem = config.problem;
  if (problem == null) await initializeSupabase(config);
  await initializeReminders();
  return NovaApp(
    key: const ValueKey('real'),
    home: problem == null ? const AuthGate() : ConfigurationErrorScreen(message: problem),
  );
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key, this.home = const AuthGate(), this.demoMode = false});

  /// Overridable for widget tests.
  final Widget home;
  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    if (!demoMode && home is AuthGate && AppConfig.current.canConnect) {
      final auth = Supabase.instance.client.auth;
      return AccountNavigation(
        initialOwner: auth.currentUser?.id,
        owners: auth.onAuthStateChange.map((event) => event.session?.user.id),
        builder: (navigator) {
          ReminderService.instance.navigatorKey = navigator;
          return _app(navigator);
        },
      );
    }
    return _app();
  }

  Widget _app([GlobalKey<NavigatorState>? navigator]) {
    // Appearance (System / Light / Dark) and Reduce Transparency come from
    // Profile → Appearance and are stored on the device.
    final prefs = AppPrefs.instance;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => NovaSettings(
        reduceTransparency: prefs.reduceTransparency,
        child: MaterialApp(
          key: ObjectKey(navigator),
          title: 'NOVA Health',
          debugShowCheckedModeBanner: false,
          theme: NovaTheme.light(),
          darkTheme: NovaTheme.dark(),
          themeMode: prefs.themeMode,
          navigatorKey: navigator,
          home: home,
        ),
      ),
    );
  }
}
