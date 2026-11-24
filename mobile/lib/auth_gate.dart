import 'dart:async';

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
    if (!AppConfig.current.canConnect) {
      return ConfigurationErrorScreen(
          message: AppConfig.current.problem ?? 'Real mode is unavailable.');
    }

    final session = Supabase.instance.client.auth.currentSession;
    return session == null
        ? const LoginScreen()
        : _SignedInGate(key: ValueKey(session.user.id));
  }
}

/// Replace the entire navigator, including modals, at every account boundary.
class AccountNavigation extends StatefulWidget {
  const AccountNavigation({
    super.key,
    required this.initialOwner,
    required this.owners,
    required this.builder,
  });

  final String? initialOwner;
  final Stream<String?> owners;
  final Widget Function(GlobalKey<NavigatorState>) builder;

  @override
  State<AccountNavigation> createState() => _AccountNavigationState();
}

class _AccountNavigationState extends State<AccountNavigation> {
  late String? _owner = widget.initialOwner;
  var _navigator = GlobalKey<NavigatorState>();
  late final StreamSubscription<String?> _subscription;

  @override
  void initState() {
    super.initState();
    // Handle each event even when multiple account switches share a frame.
    _subscription = widget.owners.listen((owner) {
      if (owner == _owner) return;
      setState(() {
        _owner = owner;
        _navigator = GlobalKey<NavigatorState>();
      });
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_navigator);
}

/// After sign-in: ask the essential health questions once, then open the app.
class _SignedInGate extends StatefulWidget {
  const _SignedInGate({super.key});

  @override
  State<_SignedInGate> createState() => _SignedInGateState();
}

class _SignedInGateState extends State<_SignedInGate> {
  late final Future<bool> _needsOnboarding =
      ProfileRepository.instance.needsOnboarding();
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

class ConfigurationErrorScreen extends StatelessWidget {
  const ConfigurationErrorScreen({super.key, required this.message});

  final String message;

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
              'NOVA Health could not start.\n\n$message',
              textAlign: TextAlign.center,
              style: NovaType.body.copyWith(color: c.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}
