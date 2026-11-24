import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/nova_orb.dart';
import '../widgets/pressable.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _isSignUp = false;
  bool _loading = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.length < 6) {
      setState(() => _error = 'Enter your email and a password of at least 6 characters.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });

    final auth = Supabase.instance.client.auth;
    try {
      if (_isSignUp) {
        final res = await auth.signUp(
          email: email,
          password: password,
          data: {'full_name': _name.text.trim()},
        );
        if (res.session == null && mounted) {
          setState(() => _info = 'Account created. Confirm your email, then sign in.');
        }
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
      // On success AuthGate swaps this screen for the app automatically.
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _error = switch (e.code) {
          'email_not_confirmed' => 'Confirm your email before signing in.',
          'invalid_credentials' => 'Check your email and password and try again.',
          'weak_password' => 'Choose a stronger password and try again.',
          'over_request_rate_limit' || 'over_email_send_rate_limit' =>
            'Too many attempts. Wait a moment and try again.',
          _ => 'Could not complete sign-in or signup. Please try again.',
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Something went wrong. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _decoration(NovaColors c, String label, IconData icon) {
    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: c.textSecondary, size: 20),
      filled: true,
      fillColor: c.fill,
      labelStyle: NovaType.subhead.copyWith(color: c.textSecondary),
      border: border(Colors.transparent),
      enabledBorder: border(Colors.transparent),
      focusedBorder: border(c.primary, 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final fieldStyle = NovaType.body.copyWith(color: c.textPrimary);

    return Scaffold(
      backgroundColor: c.background,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [c.primaryTint.withValues(alpha: 0.7), c.background],
            stops: const [0, 0.55],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(NovaSpace.margin),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 3D orb: shrinks smoothly when the keyboard opens.
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      height: keyboardOpen ? 110 : 230,
                      alignment: Alignment.center,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: const NovaOrb(size: 220),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'NOVA Health',
                      textAlign: TextAlign.center,
                      style: NovaType.largeTitle.copyWith(color: c.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isSignUp
                          ? 'Create your account'
                          : 'Your personal health companion',
                      textAlign: TextAlign.center,
                      style: NovaType.subhead.copyWith(color: c.textSecondary),
                    ),
                    const SizedBox(height: NovaSpace.section),

                    // Form card slides and fades in.
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      builder: (context, v, child) => Opacity(
                        opacity: v,
                        child: Transform.translate(offset: Offset(0, (1 - v) * 28), child: child),
                      ),
                      child: NovaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_isSignUp) ...[
                              TextField(
                                controller: _name,
                                style: fieldStyle,
                                textInputAction: TextInputAction.next,
                                decoration: _decoration(c, 'Full name', Icons.person_outline),
                              ),
                              const SizedBox(height: 12),
                            ],
                            TextField(
                              controller: _email,
                              style: fieldStyle,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              textInputAction: TextInputAction.next,
                              decoration: _decoration(c, 'Email', Icons.mail_outline),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _password,
                              style: fieldStyle,
                              obscureText: true,
                              onSubmitted: (_) => _loading ? null : _submit(),
                              decoration: _decoration(c, 'Password', Icons.lock_outline),
                            ),
                            const SizedBox(height: 16),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(_error!,
                                    style: NovaType.footnote.copyWith(color: c.alert)),
                              ),
                            if (_info != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(_info!,
                                    style: NovaType.footnote.copyWith(color: c.success)),
                              ),
                            Pressable(
                              semanticLabel: _isSignUp ? 'Create account' : 'Sign in',
                              onTap: _loading ? null : _submit,
                              child: Container(
                                height: 52,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: c.primary,
                                  borderRadius: BorderRadius.circular(NovaRadius.capsule),
                                ),
                                child: _loading
                                    ? SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: c.onPrimary,
                                        ),
                                      )
                                    : Text(
                                        _isSignUp ? 'Create account' : 'Sign in',
                                        style: NovaType.headline.copyWith(color: c.onPrimary),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Pressable(
                      semanticLabel:
                          _isSignUp ? 'Switch to sign in' : 'Switch to create account',
                      onTap: () => setState(() {
                        _isSignUp = !_isSignUp;
                        _error = null;
                        _info = null;
                      }),
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        child: Text(
                          _isSignUp
                              ? 'Already have an account? Sign in'
                              : 'New here? Create an account',
                          style: NovaType.subhead.copyWith(color: c.primary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
