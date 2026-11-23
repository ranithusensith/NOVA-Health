import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/app_prefs.dart';
import '../data/care_repository.dart';
import '../data/health_repository.dart';
import '../data/profile_models.dart';
import '../data/profile_repository.dart';
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

/// 09 Profile and settings — account, daily goals, emergency contacts,
/// appearance, connected devices, privacy and sign out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _name;
  HealthProfile? _health;
  int _allergyCount = 0;

  @override
  void initState() {
    super.initState();
    _loadName();
    _loadHealth();
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
      debugPrint('Could not load health profile.');
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
      debugPrint('Could not load profile name.');
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
    if (ok == true) await Supabase.instance.client.auth.signOut();
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
              NovaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _GoalSlider(
                      icon: Icons.water_drop_outlined,
                      color: c.water,
                      label: 'Water',
                      valueLabel: '${(prefs.waterGoalMl / 1000).toStringAsFixed(prefs.waterGoalMl % 1000 == 0 ? 0 : 1)} L',
                      value: prefs.waterGoalMl.toDouble(),
                      min: 1000,
                      max: 4000,
                      divisions: 12,
                      onChanged: (v) => prefs.setWaterGoalMl(v.round()),
                      onChangeEnd: (_) => HealthRepository.notifyChanged(),
                    ),
                    const SizedBox(height: 8),
                    _GoalSlider(
                      icon: Icons.bedtime_outlined,
                      color: c.sleep,
                      label: 'Sleep',
                      valueLabel: '${prefs.sleepGoalHours.toStringAsFixed(prefs.sleepGoalHours % 1 == 0 ? 0 : 1)} h',
                      value: prefs.sleepGoalHours,
                      min: 5,
                      max: 10,
                      divisions: 10,
                      onChanged: prefs.setSleepGoalHours,
                      onChangeEnd: (_) => HealthRepository.notifyChanged(),
                    ),
                  ],
                ),
              ),

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

              // ---------------- Devices
              const SectionLabel('Connected devices'),
              _Group(children: [
                for (final d in const [
                  ('Apple Watch', Icons.watch_outlined),
                  ('Samsung Galaxy Watch', Icons.watch_outlined),
                  ('Fitbit', Icons.monitor_heart_outlined),
                ])
                    _NavRow(
                    icon: d.$2,
                    title: d.$1,
                    trailing: d.$1 == 'Apple Watch' ? 'Apple Health' : 'Health Connect',
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

class _GoalSlider extends StatelessWidget {
  const _GoalSlider({
    required this.icon,
    required this.color,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.onChangeEnd,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: NovaType.headline.copyWith(color: c.textPrimary))),
          Text(valueLabel, style: NovaType.number(20).copyWith(color: c.textPrimary)),
        ]),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          activeColor: color,
          semanticFormatterCallback: (_) => '$label goal $valueLabel',
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
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
