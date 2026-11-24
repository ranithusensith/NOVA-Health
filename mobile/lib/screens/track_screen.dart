import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/health_repository.dart';
import '../data/sample_data.dart';
import '../services/privacy_diagnostics.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/mood_face.dart';
import '../widgets/pressable.dart';
import 'medications_screen.dart';
import 'track_history.dart';

/// Track tab: log water, sleep and mood. Saves to Supabase, then asks the
/// shell to reload Home.
class TrackScreen extends StatefulWidget {
  const TrackScreen({super.key, required this.onLogged});

  final VoidCallback onLogged;

  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  static const _moodLabels = ['Awful', 'Low', 'Okay', 'Good', 'Great'];

  final _customWater = TextEditingController();
  double _sleepHours = 7;
  int? _mood;
  bool _busy = false;

  @override
  void dispose() {
    _customWater.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(NovaSpace.margin, 0, NovaSpace.margin, 110),
      ));
  }

  Future<void> _save(Future<void> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      widget.onLogged();
      _toast(done);
    } catch (_) {
      logAppEvent('Track save failed');
      _toast('Could not save. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _addWater(int ml) => _save(() => HealthRepository.instance.logWater(ml), 'Added $ml ml of water');

  void _addCustomWater() {
    final ml = int.tryParse(_customWater.text.trim());
    if (ml == null || ml < 1 || ml > 3000) {
      _toast('Enter an amount between 1 and 3000 ml.');
      return;
    }
    _customWater.clear();
    FocusScope.of(context).unfocus();
    _addWater(ml);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final disabled = _busy;

    return ColoredBox(
      color: c.background,
      child: ListView(
        padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 8, NovaSpace.margin, pad.bottom + 140),
        children: [
          Semantics(
            header: true,
            child: Text('Track', style: NovaType.largeTitle.copyWith(color: c.textPrimary)),
          ),
          Text(formatToday(DateTime.now()), style: NovaType.subhead.copyWith(color: c.textSecondary)),
          const SizedBox(height: NovaSpace.gap),

          // ---------------- Medications shortcut
          Pressable(
            onTap: () => openMedications(context),
            semanticLabel: 'Medications. View today\'s doses and manage medicines',
            child: NovaCard(
              child: Row(children: [
                const IconBadge(icon: Icons.medication_rounded, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Medications', style: NovaType.headline.copyWith(color: c.textPrimary)),
                    Text("Today's doses, add or stop a medicine", style: NovaType.footnote.copyWith(color: c.textSecondary)),
                  ]),
                ),
                Icon(CupertinoIcons.chevron_right, size: 18, color: c.textSecondary),
              ]),
            ),
          ),
          const SizedBox(height: NovaSpace.gap),

          // ---------------- Water
          NovaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.water_drop_outlined, color: c.water),
                  const SizedBox(width: 8),
                  Text('Water', style: NovaType.headline.copyWith(color: c.textPrimary)),
                ]),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final ml in const [150, 250, 500])
                      NovaButton(
                        label: '+$ml ml',
                        kind: NovaButtonKind.secondary,
                        expand: false,
                        height: 44,
                        onPressed: disabled ? null : () => _addWater(ml),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customWater,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: NovaType.body.copyWith(color: c.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Custom amount (ml)',
                          hintStyle: NovaType.body.copyWith(color: c.textSecondary),
                          filled: true,
                          fillColor: c.fill,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(NovaRadius.capsule),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    NovaButton(
                      label: 'Add',
                      kind: NovaButtonKind.secondary,
                      expand: false,
                      height: 44,
                      onPressed: disabled ? null : _addCustomWater,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: NovaSpace.gap),

          // ---------------- Sleep
          NovaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.bedtime_outlined, color: c.sleep),
                  const SizedBox(width: 8),
                  Text('Sleep last night', style: NovaType.headline.copyWith(color: c.textPrimary)),
                  const Spacer(),
                  Text('${_sleepHours.toStringAsFixed(1)} h',
                      style: NovaType.number(22).copyWith(color: c.textPrimary)),
                ]),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(showValueIndicator: ShowValueIndicator.never),
                  child: Slider(
                    value: _sleepHours,
                    min: 0,
                    max: 14,
                    divisions: 28,
                    activeColor: c.primary,
                    semanticFormatterCallback: (v) => '${v.toStringAsFixed(1)} hours',
                    onChanged: disabled ? null : (v) => setState(() => _sleepHours = v),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Saving again replaces the previous total for today.',
                    style: NovaType.caption.copyWith(color: c.textSecondary)),
                const SizedBox(height: 8),
                NovaButton(
                  label: 'Save sleep',
                  kind: NovaButtonKind.secondary,
                  onPressed: disabled
                      ? null
                      : () => _save(
                            () => HealthRepository.instance.logSleep(_sleepHours),
                            'Saved ${_sleepHours.toStringAsFixed(1)} h of sleep',
                          ),
                ),
              ],
            ),
          ),
          const SizedBox(height: NovaSpace.gap),

          // ---------------- Mood
          NovaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How are you feeling?', style: NovaType.headline.copyWith(color: c.textPrimary)),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < 5; i++)
                      Pressable(
                        onTap: disabled ? null : () => setState(() => _mood = i),
                        semanticLabel: _moodLabels[i],
                        selected: _mood == i,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _mood == i ? c.primaryTint : c.fill,
                            border: _mood == i ? Border.all(color: c.primary, width: 2) : null,
                          ),
                          alignment: Alignment.center,
                          child: MoodFace(level: i, color: _mood == i ? c.primary : c.textPrimary),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                NovaButton(
                  label: _mood == null ? 'Pick a mood' : 'Save mood: ${_moodLabels[_mood!]}',
                  kind: NovaButtonKind.secondary,
                  onPressed: (disabled || _mood == null)
                      ? null
                      : () => _save(() => HealthRepository.instance.logMood(_mood!), 'Mood saved'),
                ),
              ],
            ),
          ),
          const SizedBox(height: NovaSpace.gap),
          const TrackHistory(),
        ],
      ),
    );
  }
}
