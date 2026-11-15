import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_shell.dart';
import 'config.dart';
import 'data/profile_repository.dart';
import 'screens/health_profile_screen.dart';
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
        return session == null ? const LoginScreen() : _SignedInGate(key: ValueKey(session.user.id));
      },
    );
  }
}

/// After sign-in: ask the essential health questions once, then open the app.
class _SignedInGate extends StatefulWidget {
  const _SignedInGate({super.key});

  @override
  State<_SignedInGate> createState() => _SignedInGateState();
}

class _SignedInGateState extends State<_SignedInGate> {
  late final Future<bool> _needsOnboarding = ProfileRepository.instance.needsOnboarding();
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    if (_done) return const AppShell();
    return FutureBuilder<bool>(
      future: _needsOnboarding,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          final c = context.nova;
          return Scaffold(
            backgroundColor: c.background,
            body: Center(child: CircularProgressIndicator(color: c.primary)),
          );
        }
        // On any error (for example offline) let the user into the app; Profile can ask again.
        if (snapshot.hasError || snapshot.data != true) return const AppShell();
        return HealthProfileScreen(
          onboarding: true,
          onDone: () => setState(() => _done = true),
        );
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
