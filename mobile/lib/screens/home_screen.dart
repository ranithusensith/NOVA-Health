import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/care_repository.dart';
import '../data/health_repository.dart';
import '../data/sample_data.dart';
import '../services/privacy_diagnostics.dart';
import '../theme/nova_theme.dart';
import '../widgets/activity_rings.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/mood_face.dart';
import '../widgets/pressable.dart';
import '../widgets/scroll_edge_fade.dart';
import '../widgets/states.dart';
import 'daily_report_screen.dart';
import 'emergency_screen.dart';
import 'medications_screen.dart';
import 'weather_card.dart';
import '../data/weather.dart';

/// 02 Home — hero screen: insight, rings, next dose, weather tip and mood check.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.data,
    this.loading = false,
    this.error,
    this.onRetry,
    this.onOpenTrack,
    this.onToggleEmpty,
    this.weather,
  });

  final HealthSnapshot data;
  final WeatherSession? weather;

  /// First load in progress: show skeletons instead of empty cards.
  final bool loading;

  /// Last load failed (shown above the cards with a Retry button).
  final String? error;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenTrack;
  final VoidCallback? onToggleEmpty;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final now = DateTime.now();

    return ColoredBox(
      color: c.background,
      child: Stack(
        children: [
          ScrollEdgeFade(
            child: ListView(
              padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 8, NovaSpace.margin, pad.bottom + 140),
              children: [
                GestureDetector(
                  onLongPress: onToggleEmpty,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 96),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            data.isEmpty ? 'Welcome, ${data.firstName}' : '${greetingFor(now)}, ${data.firstName}',
                            style: NovaType.largeTitle.copyWith(color: c.textPrimary),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(formatToday(now), style: NovaType.subhead.copyWith(color: c.textSecondary)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.gap),
                if (error != null) ...[
                  ErrorCard(message: error!, onRetry: onRetry),
                  const SizedBox(height: NovaSpace.gap),
                ],
                if (loading) ...const [
                  SkeletonCard(lines: 3),
                  SizedBox(height: NovaSpace.gap),
                  SkeletonCard(lines: 2, height: 120),
                  SizedBox(height: NovaSpace.gap),
                  SkeletonCard(lines: 2),
                ] else ...[
                  if (data.isEmpty)
                    _EmptyInsightCard(onOpenTrack: onOpenTrack)
                  else
                    _InsightCard(data: data, onOpenReport: () => openDailyReport(context)),
                  const SizedBox(height: NovaSpace.gap),
                  _RingsCard(data: data),
                  const SizedBox(height: NovaSpace.gap),
                  if (data.nextMedication != null)
                    _NextMedCard(data: data)
                  else if (data.medsToday > 0)
                    _DoseStatusCard(data: data)
                  else
                    const _NoMedsCard(),
                  if (!data.isEmpty) ...[
                    const SizedBox(height: NovaSpace.gap),
                    const _MoodCard(),
                  ],
                ],
                if (weather != null) ...[
                  const SizedBox(height: NovaSpace.gap),
                  WeatherCard(session: weather!),
                ],
              ],
            ),
          ),
          Positioned(
            top: pad.top + 4,
            right: NovaSpace.margin,
            child: _SosButton(onTap: () => openEmergency(context)),
          ),
        ],
      ),
    );
  }
}

class _SosButton extends StatelessWidget {
  const _SosButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Pressable(
      onTap: onTap,
      semanticLabel: 'Emergency SOS',
      child: Glass(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.exclamationmark_triangle, size: 20, color: c.sos),
            const SizedBox(width: 6),
            Text('SOS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: c.sos)),
          ],
        ),
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({required this.data, required this.onOpenReport});
  final HealthSnapshot data;
  final VoidCallback onOpenReport;

  /// Short, plain-language insight built from today's real numbers.
  /// The full summary lives in the daily report.
  static String insightFor(HealthSnapshot d) {
    final parts = <String>[];
    if (d.sleepMinutes case final minutes?) {
      parts.add('Sleep: ${formatMinutes(minutes)}${d.sleepSource == null ? ' logged' : ' from ${d.sleepSource}'}.');
    }
    if (d.waterL case final litres?) {
      parts.add('You logged ${litres.toStringAsFixed(2)} L of water.');
    }
    if (d.nextMedication?.overdue ?? false) {
      parts.add('One dose is overdue; check Medications.');
    }
    if (parts.isEmpty) return 'Log your water, sleep and mood today to get a more personal insight.';
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      tone: NovaCardTone.tinted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 20, color: c.primary),
              const SizedBox(width: 8),
              Text("Today's insight", style: NovaType.headline.copyWith(color: c.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          Text(insightFor(data), style: NovaType.body.copyWith(color: c.textPrimary)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Based on:', style: NovaType.caption.copyWith(color: c.textSecondary)),
              if (data.sleepMinutes != null) SourceChip(label: 'Sleep', color: c.sleep),
              if (data.waterL != null) SourceChip(label: 'Hydration', color: c.water),
              SourceChip(label: 'Medications', color: c.primary),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Pressable(
                onTap: onOpenReport,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('View daily report', style: NovaType.headline.copyWith(color: c.primary)),
                      Icon(CupertinoIcons.chevron_right, size: 16, color: c.primary),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Align(alignment: Alignment.centerRight, child: DisclaimerNote()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyInsightCard extends StatelessWidget {
  const _EmptyInsightCard({this.onOpenTrack});
  final VoidCallback? onOpenTrack;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      tone: NovaCardTone.tinted,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        children: [
          IconBadge(icon: Icons.watch_outlined, size: 72, background: c.surface),
          const SizedBox(height: 12),
          Text('No data yet', style: NovaType.headline.copyWith(fontSize: 20, color: c.textPrimary)),
          const SizedBox(height: 6),
          Text(
            'Log your first entry or add a medication and your daily insight will appear here.',
            textAlign: TextAlign.center,
            style: NovaType.subhead.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 16),
          NovaButton(label: 'Log water, sleep or mood', icon: Icons.add_rounded, onPressed: onOpenTrack),
          const SizedBox(height: 10),
          NovaButton(
            label: 'Add a medication',
            kind: NovaButtonKind.secondary,
            icon: Icons.medication_rounded,
            onPressed: () => openMedications(context),
          ),
          const SizedBox(height: 12),
          const DisclaimerNote(),
        ],
      ),
    );
  }
}

class _RingsCard extends StatelessWidget {
  const _RingsCard({required this.data});
  final HealthSnapshot data;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final rings = [
      if (data.sleepProgress case final progress?) RingValue(progress, c.sleep),
      if (data.stepsProgress case final progress?) RingValue(progress, c.steps),
    ];
    return NovaCard(
      child: Row(
        children: [
          if (rings.isNotEmpty) ...[
            ActivityRings(
              size: 110,
              semanticLabel: 'Recorded progress toward saved goals',
              rings: rings,
            ),
            const SizedBox(width: 18),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Legend(color: c.water, label: 'Water', value: data.waterL == null ? 'Unknown' : '${data.waterL!.toStringAsFixed(2)} L',
                    goal: data.waterGoalL == null ? '' : ' · ${data.waterGoalL} L target'),
                const SizedBox(height: 12),
                _Legend(color: c.sleep, label: 'Sleep', value: data.sleepMinutes == null ? 'Unknown' : formatMinutes(data.sleepMinutes!),
                    goal: [
                      if (data.sleepGoalMinutes != null) ' / ${formatMinutes(data.sleepGoalMinutes!)}',
                      if (data.sleepSource != null) ' · ${data.sleepSource}',
                    ].join()),
                const SizedBox(height: 12),
                _Legend(color: c.steps, label: 'Steps', value: data.steps == null ? 'Unknown' : formatThousands(data.steps!), goal: data.stepsSource == null ? '' : ' · ${data.stepsSource}'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, required this.value, required this.goal});
  final Color color;
  final String label;
  final String value;
  final String goal;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Row(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: NovaType.caption.copyWith(color: c.textSecondary)),
              Text.rich(
                TextSpan(
                  text: value,
                  style: NovaType.number(20).copyWith(color: c.textPrimary),
                  children: [TextSpan(text: goal, style: NovaType.subhead.copyWith(color: c.textSecondary))],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NextMedCard extends StatefulWidget {
  const _NextMedCard({required this.data});
  final HealthSnapshot data;

  @override
  State<_NextMedCard> createState() => _NextMedCardState();
}

class _NextMedCardState extends State<_NextMedCard> {
  bool _saving = false;

  Future<void> _take() async {
    if (_saving) return;
    final med = widget.data.nextMedication!;
    final occurrence = med.occurrence;
    if (occurrence == null) {
      openMedications(context); // no reminder times yet: manage it there
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final logId = await CareRepository.instance.logDose(occurrence);
      if (!messenger.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(logId == null ? 'This dose was already logged' : '${med.name} marked as taken'),
          action: logId == null
              ? null
              : SnackBarAction(label: 'Undo', onPressed: () async {
                  try {
                    await CareRepository.instance.undoDose(occurrence, logId);
                  } catch (e) {
                    if (messenger.mounted) {
                      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
                    }
                  }
                }),
        ));
    } catch (e) {
      logAppEvent('logDose failed');
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final med = widget.data.nextMedication!;
    final taken = widget.data.medsTakenToday;
    final when = med.occurrence == null ? med.time : (med.overdue ? 'Missed · ${med.time}' : 'Next dose · ${med.time}');
    return Pressable(
      onTap: () => openMedications(context),
      semanticLabel: '${med.name} ${med.dose}, $when. Open medications',
      child: NovaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(
                  icon: Icons.medication_rounded,
                  background: med.overdue ? c.alertSurface : null,
                  foreground: med.overdue ? c.alert : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${med.name} ${med.dose}'.trim(), style: NovaType.headline.copyWith(color: c.textPrimary)),
                      Text(when, style: NovaType.subhead.copyWith(color: med.overdue ? c.alert : c.textSecondary)),
                    ],
                  ),
                ),
                if (widget.data.medsToday > 0)
                  StatusLabel(icon: CupertinoIcons.checkmark_alt, label: '$taken of ${widget.data.medsToday} taken', color: c.success),
              ],
            ),
            const SizedBox(height: 12),
            NovaButton(
              label: _saving ? 'Saving…' : (med.occurrence == null ? 'Manage medication' : 'Mark as taken'),
              onPressed: _saving ? null : _take,
            ),
          ],
        ),
      ),
    );
  }
}

class _DoseStatusCard extends StatelessWidget {
  const _DoseStatusCard({required this.data});
  final HealthSnapshot data;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final allTaken = data.medsTakenToday == data.medsToday;
    final title = allTaken ? 'All doses taken' : 'Some doses could not be verified';
    final color = allTaken ? c.success : c.warning;
    return Pressable(
      onTap: () => openMedications(context),
      semanticLabel: '$title. Open medications',
      child: NovaCard(
        child: Row(
          children: [
            IconBadge(
              icon: allTaken ? CupertinoIcons.checkmark_alt : CupertinoIcons.info_circle,
              background: color.withValues(alpha: 0.15),
              foreground: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: NovaType.headline.copyWith(color: c.textPrimary)),
                  Text(allTaken ? '${data.medsTakenToday} of ${data.medsToday} today. Nice work.' : 'Check Medications for details.',
                      style: NovaType.subhead.copyWith(color: c.textSecondary)),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 20, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _NoMedsCard extends StatelessWidget {
  const _NoMedsCard();

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Pressable(
      onTap: () => openMedications(context),
      child: NovaCard(
        child: Row(
          children: [
            const IconBadge(icon: Icons.medication_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No medications added', style: NovaType.headline.copyWith(color: c.textPrimary)),
                  Text('Add one by hand or scan a prescription.', style: NovaType.subhead.copyWith(color: c.textSecondary)),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 20, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _MoodCard extends StatefulWidget {
  const _MoodCard();

  @override
  State<_MoodCard> createState() => _MoodCardState();
}

class _MoodCardState extends State<_MoodCard> {
  static const _labels = ['Awful', 'Low', 'Okay', 'Good', 'Great'];
  int? _selected;
  bool _saving = false;

  /// One tap saves the mood, same as the Track tab.
  Future<void> _pick(int i) async {
    if (_saving) return;
    final previous = _selected;
    setState(() {
      _selected = i;
      _saving = true;
    });
    try {
      await HealthRepository.instance.logMood(i);
    } catch (e) {
      logAppEvent('logMood failed');
      if (mounted) {
        setState(() => _selected = previous);
        showNovaToast(context, friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('How are you feeling?', style: NovaType.headline.copyWith(color: c.textPrimary))),
              if (_saving)
                const CupertinoActivityIndicator()
              else if (_selected != null)
                StatusLabel(icon: CupertinoIcons.checkmark_alt, label: 'Logged · ${_labels[_selected!]}', color: c.success),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < 5; i++)
                Pressable(
                  onTap: _saving ? null : () => _pick(i),
                  semanticLabel: _labels[i],
                  selected: _selected == i,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _selected == i ? c.primaryTint : c.fill,
                      border: _selected == i ? Border.all(color: c.primary, width: 2) : null,
                    ),
                    alignment: Alignment.center,
                    child: MoodFace(level: i, color: _selected == i ? c.primary : c.textPrimary),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
