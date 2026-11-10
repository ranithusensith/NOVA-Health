import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_shell.dart';
import 'config.dart';
import 'screens/login_screen.dart';
import 'theme/nova_theme.dart';

/// Shows the login screen until a Supabase session exists, then the app.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.isConfigured) return const _MissingConfig();

    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = snapshot.data?.session ?? auth.currentSession;
        return session == null ? const LoginScreen() : const AppShell();
      },
    );
  }
}

class _MissingConfig extends StatelessWidget {
  const _MissingConfig();

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(NovaSpace.margin),
            child: Text(
              'Missing SUPABASE_URL or SUPABASE_KEY.\n\n'
              'Run with:\nflutter run --dart-define-from-file=dart_defines.json',
              textAlign: TextAlign.center,
              style: NovaType.body.copyWith(color: c.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}
