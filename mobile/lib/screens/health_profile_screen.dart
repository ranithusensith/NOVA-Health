import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/health_repository.dart';
import '../data/profile_models.dart';
import '../data/profile_repository.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/states.dart';

void openHealthProfile(BuildContext context, {VoidCallback? onSaved}) {
  Navigator.of(context)
      .push<bool>(MaterialPageRoute(builder: (_) => const HealthProfileScreen()))
      .then((saved) {
    if (saved == true) onSaved?.call();
  });
}

/// Essential health data. Shown once after the first sign-in ([onboarding]),
/// and reachable any time from Profile to view or edit.
class HealthProfileScreen extends StatefulWidget {
  const HealthProfileScreen({super.key, this.onboarding = false, this.onDone});

  final bool onboarding;

  /// Called after the questions are saved or skipped (onboarding only).
  final VoidCallback? onDone;

  @override
  State<HealthProfileScreen> createState() => _HealthProfileScreenState();
}

class _HealthProfileScreenState extends State<HealthProfileScreen> {
  final _name = TextEditingController();
  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _notes = TextEditingController();
  final _customAllergy = TextEditingController();

  DateTime? _birth;
  String? _sex;
  String? _blood;
  final Set<String> _conditions = {};
  final List<String> _allergies = [];

  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _height, _weight, _notes, _customAllergy]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final profile = await ProfileRepository.instance.load();
      final allergies = await ProfileRepository.instance.allergies();
      final metaName =
          ((Supabase.instance.client.auth.currentUser?.userMetadata?['full_name'] as String?) ?? '').trim();
      if (!mounted) return;
      setState(() {
        _name.text = profile.fullName.isNotEmpty ? profile.fullName : metaName;
        _birth = profile.birthDate;
        _sex = profile.sex;
        _blood = profile.bloodType;
        if (profile.heightCm != null) _height.text = _trim(profile.heightCm!);
        if (profile.weightKg != null) _weight.text = _trim(profile.weightKg!);
        _notes.text = profile.medicalNotes;
        _conditions
          ..clear()
          ..addAll(profile.conditions);
        _allergies
          ..clear()
          ..addAll(allergies.map((a) => a.name));
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = friendlyError(e);
        });
      }
    }
  }

  static String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  double? _num(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _pickBirth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birth ?? DateTime(now.year - 25, 1, 1),
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked != null) setState(() => _birth = picked);
  }

  String? _validate() {
    if (_name.text.trim().length < 2) return 'Enter your name.';
    if (_birth == null) return 'Choose your date of birth.';
    if (_sex == null) return 'Choose an option for sex.';
    final h = _num(_height);
    final w = _num(_weight);
    if (h == null || h < 50 || h > 250) return 'Enter your height in cm (50 to 250).';
    if (w == null || w < 2 || w > 400) return 'Enter your weight in kg (2 to 400).';
    return null;
  }

  HealthProfile _current({required bool done}) => HealthProfile(
        fullName: _name.text.trim(),
        birthDate: _birth,
        sex: _sex,
        bloodType: _blood,
        heightCm: _num(_height),
        weightKg: _num(_weight),
        conditions: _conditions.toList(),
        medicalNotes: _notes.text,
        onboardingDone: done,
      );

  Future<void> _save() async {
    if (_saving) return;
    final error = _validate();
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await ProfileRepository.instance.save(_current(done: true));
      await ProfileRepository.instance.replaceAllergies(_allergies);
      HealthRepository.notifyChanged();
      if (!mounted) return;
      if (widget.onboarding) {
        widget.onDone?.call();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = friendlyError(e);
        });
      }
    }
  }

  /// Onboarding only: keep the name, ask again later from Profile.
  Future<void> _skip() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ProfileRepository.instance.save(HealthProfile(fullName: _name.text.trim(), onboardingDone: true));
      if (mounted) widget.onDone?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = friendlyError(e);
        });
      }
    }
  }

  void _addCustomAllergy() {
    final text = _customAllergy.text.trim();
    if (text.isEmpty) return;
    if (!_allergies.any((a) => a.toLowerCase() == text.toLowerCase())) {
      setState(() => _allergies.add(text));
    }
    _customAllergy.clear();
  }

  void _toggleAllergy(String name) {
    setState(() {
      final i = _allergies.indexWhere((a) => a.toLowerCase() == name.toLowerCase());
      if (i >= 0) {
        _allergies.removeAt(i);
      } else {
        _allergies.add(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final onboarding = widget.onboarding;

    final bmiProfile = _current(done: false);
    final bmi = bmiProfile.bmi;
    final bmiNote = bmiProfile.bmiNote;

    final customAllergies = [
      for (final a in _allergies)
        if (!commonAllergies.any((x) => x.toLowerCase() == a.toLowerCase())) a,
    ];

    return Scaffold(
      backgroundColor: c.background,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          if (_loading)
            ListView(
              padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 72, NovaSpace.margin, 24),
              children: const [SkeletonCard(lines: 4), SizedBox(height: 16), SkeletonCard(lines: 4)],
            )
          else if (_loadError != null)
            Padding(
              padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 72, NovaSpace.margin, 24),
              child: ErrorCard(message: _loadError!, onRetry: _load),
            )
          else
            ListView(
              padding: EdgeInsets.fromLTRB(
                  NovaSpace.margin, pad.top + (onboarding ? 24 : 64), NovaSpace.margin, pad.bottom + 40),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    onboarding ? 'Set up your health profile' : 'Health profile',
                    style: NovaType.largeTitle.copyWith(color: c.textPrimary),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  onboarding
                      ? 'A few details help NOVA give safer, more personal guidance. Only you can see them, and you can change them any time.'
                      : 'Only you can see this. It helps NOVA give safer, more personal guidance.',
                  style: NovaType.subhead.copyWith(color: c.textSecondary),
                ),

                // ---------------------------------------------- About you
                const SectionLabel('About you'),
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        style: NovaType.body.copyWith(color: c.textPrimary),
                        decoration: novaFieldDecoration(c, 'Full name', icon: CupertinoIcons.person),
                      ),
                      const SizedBox(height: 12),
                      Pressable(
                        onTap: _pickBirth,
                        semanticLabel: _birth == null ? 'Choose date of birth' : 'Date of birth ${formatDate(_birth!)}',
                        child: Container(
                          height: 54,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(16)),
                          child: Row(
                            children: [
                              Icon(CupertinoIcons.calendar, size: 20, color: c.textSecondary),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _birth == null ? 'Date of birth' : formatDate(_birth!),
                                  style: NovaType.body.copyWith(
                                    color: _birth == null ? c.textSecondary : c.textPrimary,
                                  ),
                                ),
                              ),
                              if (_birth != null && bmiProfile.age != null)
                                Text('${bmiProfile.age} yrs',
                                    style: NovaType.subhead.copyWith(color: c.textSecondary)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('Sex', style: NovaType.subhead.copyWith(color: c.textSecondary)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final e in sexOptions.entries)
                            _OptionChip(
                              label: e.value,
                              selected: _sex == e.key,
                              onTap: () => setState(() => _sex = e.key),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text('Blood type (optional)', style: NovaType.subhead.copyWith(color: c.textSecondary)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final b in bloodTypeOptions)
                            _OptionChip(
                              label: b,
                              selected: _blood == (b == 'Not sure' ? 'unknown' : b),
                              onTap: () => setState(() {
                                final value = b == 'Not sure' ? 'unknown' : b;
                                _blood = _blood == value ? null : value;
                              }),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // ---------------------------------------------- Body
                const SectionLabel('Height and weight'),
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _height,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                              onChanged: (_) => setState(() {}),
                              style: NovaType.body.copyWith(color: c.textPrimary),
                              decoration: novaFieldDecoration(c, 'Height (cm)', icon: CupertinoIcons.resize_v),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _weight,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                              onChanged: (_) => setState(() {}),
                              style: NovaType.body.copyWith(color: c.textPrimary),
                              decoration: novaFieldDecoration(c, 'Weight (kg)', icon: CupertinoIcons.gauge),
                            ),
                          ),
                        ],
                      ),
                      if (bmi != null && bmi.isFinite && bmi > 5 && bmi < 80) ...[
                        const SizedBox(height: 12),
                        Text(
                          'BMI ${bmi.toStringAsFixed(1)}${bmiNote == null ? '' : ', $bmiNote'}. '
                          'BMI is only a rough guide.',
                          style: NovaType.footnote.copyWith(color: c.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),

                // ---------------------------------------------- History
                const SectionLabel('Medical history'),
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Tap any that apply. Leave empty if none.',
                          style: NovaType.subhead.copyWith(color: c.textSecondary)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final name in commonConditions)
                            _OptionChip(
                              label: name,
                              selected: _conditions.contains(name),
                              onTap: () => setState(() {
                                if (!_conditions.remove(name)) _conditions.add(name);
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _notes,
                        minLines: 2,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        style: NovaType.body.copyWith(color: c.textPrimary),
                        decoration: novaFieldDecoration(
                          c,
                          'Other conditions, surgeries, notes',
                          icon: CupertinoIcons.doc_text,
                        ),
                      ),
                    ],
                  ),
                ),

                // ---------------------------------------------- Allergies
                const SectionLabel('Allergies'),
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('NOVA checks new medicines against these.',
                          style: NovaType.subhead.copyWith(color: c.textSecondary)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final name in commonAllergies)
                            _OptionChip(
                              label: name,
                              selected: _allergies.any((a) => a.toLowerCase() == name.toLowerCase()),
                              onTap: () => _toggleAllergy(name),
                            ),
                          for (final name in customAllergies)
                            _OptionChip(label: '$name  ✕', selected: true, onTap: () => _toggleAllergy(name)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _customAllergy,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _addCustomAllergy(),
                              style: NovaType.body.copyWith(color: c.textPrimary),
                              decoration: novaFieldDecoration(c, 'Another allergy', icon: CupertinoIcons.plus_circle),
                            ),
                          ),
                          const SizedBox(width: 8),
                          NovaButton(
                            label: 'Add',
                            kind: NovaButtonKind.secondary,
                            expand: false,
                            height: 50,
                            onPressed: _addCustomAllergy,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: NovaSpace.gap),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(CupertinoIcons.lock_shield, size: 18, color: c.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This is stored in your private NOVA account. Only your age range, never your name or '
                        'date of birth, is used to personalise AI guidance.',
                        style: NovaType.footnote.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: NovaSpace.gap),
                if (_formError != null) ...[
                  Text(_formError!, style: NovaType.subhead.copyWith(color: c.alert)),
                  const SizedBox(height: 12),
                ],
                NovaButton(
                  label: _saving ? 'Saving…' : (onboarding ? 'Save and continue' : 'Save changes'),
                  onPressed: _saving ? null : _save,
                ),
                if (onboarding) ...[
                  const SizedBox(height: 4),
                  NovaButton(
                    label: 'Skip for now',
                    kind: NovaButtonKind.plain,
                    onPressed: _saving ? null : _skip,
                  ),
                ],
              ],
            ),
          if (!onboarding)
            Positioned(
              top: pad.top + 4,
              left: NovaSpace.margin,
              child: const GlassBackButton(label: 'Profile'),
            ),
        ],
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      selected: selected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? c.primaryTint : c.fill,
          borderRadius: BorderRadius.circular(NovaRadius.capsule),
          border: selected ? Border.all(color: c.primary, width: 1.5) : Border.all(color: Colors.transparent, width: 1.5),
        ),
        child: Text(
          label,
          style: NovaType.subhead.copyWith(
            color: selected ? c.primary : c.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
