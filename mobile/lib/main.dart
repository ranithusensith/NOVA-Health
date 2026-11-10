import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_gate.dart';
import 'config.dart';
import 'data/app_prefs.dart';
import 'theme/nova_settings.dart';
import 'theme/nova_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await AppPrefs.instance.load();
  if (AppConfig.isConfigured) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseKey,
    );
  }
  runApp(const NovaApp());
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key, this.home = const AuthGate()});

  /// Overridable for widget tests.
  final Widget home;

  @override
  Widget build(BuildContext context) {
    // Appearance (System / Light / Dark) and Reduce Transparency come from
    // Profile → Appearance and are stored on the device.
    final prefs = AppPrefs.instance;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => NovaSettings(
        reduceTransparency: prefs.reduceTransparency,
        child: MaterialApp(
          title: 'NOVA Health',
          debugShowCheckedModeBanner: false,
          theme: NovaTheme.light(),
          darkTheme: NovaTheme.dark(),
          themeMode: prefs.themeMode,
          home: home,
        ),
      ),
    );
  }
}
