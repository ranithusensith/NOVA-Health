import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/app_prefs.dart';
import '../data/care_repository.dart';
import '../data/daily_metrics.dart';
import '../data/health_repository.dart';
import '../data/profile_models.dart';
import '../data/profile_repository.dart';
import '../services/privacy_diagnostics.dart';
import '../services/reminder_service.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/pressable.dart';
import '../widgets/scroll_edge_fade.dart';
import '../widgets/states.dart';
import 'ai_privacy_screen.dart';
import 'cycle_screen.dart';
import 'emergency_screen.dart';
import 'health_profile_screen.dart';
import 'heart_rate_screen.dart';
import 'medications_screen.dart';
import 'records_screen.dart';
import 'reminders_screen.dart';
import 'wearable_activity_screen.dart';

/// 09 Profile and settings — account, daily goals, emergency contacts,
/// appearance, health data imports, privacy and sign out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _name;
  HealthProfile? _health;
  int _allergyCount = 0;
  DailyGoals? _goals;
  bool _goalError = false;
  bool _savingGoal = false;

  @override
  void initState() {
    super.initState();
    _loadName();
    _loadHealth();
    _loadGoals();
  }

  Future<void> _loadGoals() async {
    try {
      final goals = await HealthRepository.instance.loadDailyGoals();
      if (mounted) {
        setState(() {
          _goals = goals;
          _goalError = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _goalError = true);
    }
  }

  Future<void> _editGoal({required bool water}) async {
    final account = Supabase.instance.client.auth.currentUser?.id;
    if (account == null || _savingGoal) return;
    final initial = water ? _goals?.waterMl : _goals?.sleepHours;
    var text = initial?.toString() ?? '';
    final edited = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(water ? 'Water tracking target (mL)' : 'Sleep tracking goal (hours)'),
        content: Column(
          children: [
            Text(water
                ? 'Use your care team’s instructions if they gave you a fluid limit. Leave blank to clear.'
                : 'Leave blank to clear.'),
            const SizedBox(height: 8),
            CupertinoTextFormFieldRow(
              initialValue: text,
              placeholder: 'Optional',
              keyboardType: TextInputType.numberWithOptions(decimal: !water),
              onChanged: (value) => text = value.trim(),
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, text), child: const Text('Save')),
        ],
      ),
    );
    if (edited == null || !mounted) return;
    final num? number = water ? int.tryParse(edited) : double.tryParse(edited);
    if (edited.isNotEmpty && (number == null || !number.isFinite ||
        number < (water ? 1 : 0.1) || number > (water ? 20000 : 24))) {
      showNovaToast(context, water ? 'Enter a whole number of millilitres.' : 'Enter hours between 0.1 and 24.');
      return;
    }
    setState(() => _savingGoal = true);
    try {
      final goals = await HealthRepository.instance.saveDailyGoal(accountId: account, water: water, value: number);
      if (mounted) setState(() => _goals = goals);
    } catch (e) {
      if (mounted) showNovaToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _savingGoal = false);
    }
  }

  Future<void> _loadHealth() async {
    try {
      final profile = await ProfileRepository.instance.load();
      final allergies = await ProfileRepository.instance.allergies();
      if (!mounted) return;
      setState(() {
        _health = profile;
        _allergyCount = allergies.length;
        if (profile.fullName.isNotEmpty) _name = profile.fullName;
      });
    } catch (_) {
      logAppEvent('Could not load health profile.');
    }
  }

  void _openHealthProfile() => openHealthProfile(context, onSaved: _loadHealth);

  Future<void> _loadName() async {
    final meta = ((Supabase.instance.client.auth.currentUser?.userMetadata?['full_name'] as String?) ?? '').trim();
    setState(() => _name = meta);
    try {
      final fromProfile = await CareRepository.instance.fullName();
      if (mounted && fromProfile.isNotEmpty) setState(() => _name = fromProfile);
    } catch (_) {
      logAppEvent('Could not load profile name.');
    }
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _name ?? '');
    final c = context.nova;
    final result = await showCupertinoDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Your name'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            placeholder: 'Full name',
            style: TextStyle(color: c.textPrimary),
          ),
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty || result == _name) return;
    try {
      await CareRepository.instance.updateFullName(result);
      if (mounted) setState(() => _name = result);
    } catch (e) {
      if (mounted) showNovaToast(context, friendlyError(e));
    }
  }

  Future<void> _signOut() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Your data stays safe in your account.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final auth = Supabase.instance.client.auth;
      await ReminderService.instance.signOut(() => auth.signOut());
    } catch (e) {
      if (mounted) showNovaToast(context, friendlyError(e));
    }
  }

  void _showText(String title, String body) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) {
        final c = ctx.nova;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(NovaRadius.sheet)),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: NovaType.title2.copyWith(color: c.textPrimary)),
                  const SizedBox(height: 10),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Text(body, style: NovaType.subhead.copyWith(color: c.textPrimary)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  NovaButton(label: 'Done', kind: NovaButtonKind.secondary, onPressed: () => Navigator.pop(ctx)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final user = Supabase.instance.client.auth.currentUser;
    final prefs = AppPrefs.instance;

    return ColoredBox(
      color: c.background,
      child: ScrollEdgeFade(
        child: ListenableBuilder(
          listenable: prefs,
          builder: (context, _) => ListView(
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 8, NovaSpace.margin, pad.bottom + 140),
            children: [
              Semantics(header: true, child: Text('Profile', style: NovaType.largeTitle.copyWith(color: c.textPrimary))),
              const SizedBox(height: NovaSpace.gap),

              // ---------------- Account
              Pressable(
                onTap: _editName,
                semanticLabel: 'Edit your name',
                child: NovaCard(
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: c.primaryTint, shape: BoxShape.circle),
                        child: Text(
                          (_name?.isNotEmpty ?? false) ? _name!.characters.first.toUpperCase() : '?',
                          style: NovaType.title2.copyWith(color: c.primary),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text((_name?.isNotEmpty ?? false) ? _name! : 'Add your name',
                                style: NovaType.headline.copyWith(color: c.textPrimary)),
                            Text(user?.email ?? '', style: NovaType.subhead.copyWith(color: c.textSecondary)),
                          ],
                        ),
                      ),
                      Icon(CupertinoIcons.pencil, size: 18, color: c.textSecondary),
                    ],
                  ),
                ),
              ),

              // ---------------- Health profile summary
              const SectionLabel('Health profile'),
              _HealthSummaryCard(profile: _health, allergyCount: _allergyCount, onTap: _openHealthProfile),

              // ---------------- Health
              const SectionLabel('Health'),
              _Group(children: [
                _NavRow(
                  icon: CupertinoIcons.heart_fill,
                  title: 'Heart rate',
                  color: c.sos,
                  onTap: () => openHeartRate(context),
                ),
                if (_health?.sex != 'male')
                  _NavRow(
                    icon: Icons.calendar_month_rounded,
                    title: 'Cycle tracking',
                    color: c.sleep,
                    onTap: () => openCycle(context),
                  ),
                _NavRow(
                  icon: Icons.medication_rounded,
                  title: 'Medications',
                  onTap: () => openMedications(context),
                ),
                _NavRow(
                  icon: CupertinoIcons.bell_fill,
                  title: 'Reminders',
                  onTap: () => openReminders(context),
                ),
                _NavRow(
                  icon: CupertinoIcons.doc_text_fill,
                  title: 'Medical records',
                  onTap: () => openRecords(context),
                ),
                _NavRow(
                  icon: CupertinoIcons.person_2_fill,
                  title: 'Emergency contacts',
                  color: c.sos,
                  onTap: () => openEmergency(context),
                ),
              ]),

              // ---------------- Goals
              const SectionLabel('Daily goals'),
              if (_goals == null)
                if (_goalError)
                  ErrorCard(message: 'Could not load your tracking goals.', onRetry: _loadGoals)
                else
                  const SkeletonCard(lines: 2)
              else
                _Group(children: [
                  _NavRow(
                    icon: Icons.water_drop_outlined,
                    color: c.water,
                    title: 'Water tracking target',
                    trailing: _goals!.waterMl == null ? 'Not set' : '${_goals!.waterMl} mL',
                    onTap: () => _editGoal(water: true),
                  ),
                  _NavRow(
                    icon: Icons.bedtime_outlined,
                    color: c.sleep,
                    title: 'Sleep tracking goal',
                    trailing: _goals!.sleepHours == null ? 'Not set' : '${_goals!.sleepHours} h',
                    onTap: () => _editGoal(water: false),
                  ),
                ]),

              // ---------------- Appearance
              const SectionLabel('Appearance'),
              NovaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoSlidingSegmentedControl<ThemeMode>(
                        groupValue: prefs.themeMode,
                        onValueChanged: (m) {
                          if (m != null) prefs.setThemeMode(m);
                        },
                        children: {
                          ThemeMode.system: _seg('System', c),
                          ThemeMode.light: _seg('Light', c),
                          ThemeMode.dark: _seg('Dark', c),
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Reduce transparency', style: NovaType.headline.copyWith(color: c.textPrimary)),
                              Text('Makes glass controls solid and easier to read.',
                                  style: NovaType.footnote.copyWith(color: c.textSecondary)),
                            ],
                          ),
                        ),
                        Semantics(
                          label: 'Reduce transparency',
                          child: CupertinoSwitch(
                            value: prefs.reduceTransparency,
                            activeTrackColor: c.success,
                            onChanged: prefs.setReduceTransparency,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SectionLabel('Health data imports'),
              _Group(children: [
                _NavRow(
                  icon: Icons.watch_outlined,
                  title: 'Import steps and sleep',
                  onTap: () => openWearableActivity(context),
                ),
                _NavRow(
                  icon: Icons.monitor_heart_outlined,
                  title: 'Import heart rate',
                  onTap: () => openHeartRate(context),
                ),
              ]),

              // ---------------- Privacy
              const SectionLabel('Privacy and about'),
              _Group(children: [
                _NavRow(
                  icon: CupertinoIcons.lock_shield,
                  title: 'Privacy and consent',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AiPrivacyScreen()),
                  ),
                ),
                _NavRow(
                  icon: CupertinoIcons.info_circle,
                  title: 'About NOVA Health',
                  onTap: () => _showText(
                    'About NOVA Health',
                    'NOVA Health brings your medications, sleep, water, mood, meals and weather into one place '
                        'and turns them into simple daily guidance.\n\n'
                        'NOVA gives guidance, not medical advice. It does not diagnose or treat any condition. '
                        'Always follow your doctor or pharmacist, and in an emergency call 1990.',
                  ),
                ),
              ]),
              const SizedBox(height: NovaSpace.section),
              NovaButton(
                label: 'Sign out',
                kind: NovaButtonKind.destructive,
                icon: Icons.logout_rounded,
                onPressed: _signOut,
              ),
              const SizedBox(height: 12),
              Center(child: Text('NOVA Health · Guidance, not medical advice', style: NovaType.caption.copyWith(color: c.textSecondary))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _seg(String label, NovaColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(label, style: NovaType.subhead.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary)),
      );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator, indent: 60),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.title, required this.onTap, this.trailing, this.color});
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final String? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Pressable(
      onTap: onTap,
      semanticLabel: trailing == null ? title : '$title, $trailing',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              IconBadge(icon: icon, size: 32, foreground: color, background: color?.withValues(alpha: 0.12)),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: NovaType.body.copyWith(color: c.textPrimary))),
              if (trailing != null) ...[
                Text(trailing!, style: NovaType.subhead.copyWith(color: c.textSecondary)),
                const SizedBox(width: 6),
              ],
              Icon(CupertinoIcons.chevron_right, size: 16, color: c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Profile-tab summary of the health profile. Tap to view or edit everything.
class _HealthSummaryCard extends StatelessWidget {
  const _HealthSummaryCard({required this.profile, required this.allergyCount, required this.onTap});

  final HealthProfile? profile;
  final int allergyCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final p = profile;

    if (p == null) {
      return const SkeletonCard(lines: 3);
    }

    final lines = <String>[];
    final age = p.age;
    if (age != null || p.sex != null) {
      lines.add([if (age != null) '$age years', if (p.sex != null) p.sexLabel].join(' · '));
    }
    if (p.bloodType != null) lines.add('Blood type ${p.bloodTypeLabel}');
    if (p.heightCm != null && p.weightKg != null) {
      final bmi = p.bmi;
      lines.add(
        '${p.heightCm!.toStringAsFixed(p.heightCm! % 1 == 0 ? 0 : 1)} cm · '
        '${p.weightKg!.toStringAsFixed(p.weightKg! % 1 == 0 ? 0 : 1)} kg'
        '${bmi == null ? '' : ' · BMI ${bmi.toStringAsFixed(1)}'}',
      );
    }
    final conditionText = p.conditions.isEmpty ? 'No conditions listed' : p.conditions.join(', ');
    lines.add(conditionText);
    lines.add(allergyCount == 0 ? 'No allergies listed' : '$allergyCount ${allergyCount == 1 ? 'allergy' : 'allergies'}');

    return Pressable(
      onTap: onTap,
      semanticLabel: p.isComplete ? 'View and edit your health profile' : 'Complete your health profile',
      child: NovaCard(
        tone: p.isComplete ? NovaCardTone.normal : NovaCardTone.tinted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(icon: Icons.health_and_safety_outlined, size: 44, foreground: c.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    p.isComplete ? 'Your health details' : 'Complete your health profile',
                    style: NovaType.headline.copyWith(color: c.textPrimary),
                  ),
                ),
                Icon(CupertinoIcons.chevron_right, size: 16, color: c.textSecondary),
              ],
            ),
            const SizedBox(height: 12),
            if (!p.isComplete)
              Text(
                'Add your birthday, sex, height and weight so NOVA can give safer, more personal guidance.',
                style: NovaType.subhead.copyWith(color: c.textPrimary),
              )
            else
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(line, style: NovaType.subhead.copyWith(color: c.textSecondary)),
                ),
          ],
        ),
      ),
    );
  }
}
