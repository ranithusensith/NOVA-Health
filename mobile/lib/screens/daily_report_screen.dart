import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_prefs.dart';
import '../data/care_models.dart';
import '../data/care_repository.dart';
import '../data/sample_data.dart';
import '../services/api_client.dart';
import '../theme/nova_theme.dart';
import '../widgets/activity_rings.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/mood_face.dart';
import '../widgets/pressable.dart';
import '../widgets/scroll_edge_fade.dart';
import '../widgets/states.dart';

void openDailyReport(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DailyReportScreen()));
}

/// 07 Daily report — NOVA summary for one day (GET /api/v1/reports/daily) plus
/// that day's tracked numbers, with a date switcher.
class DailyReportScreen extends StatefulWidget {
  const DailyReportScreen({super.key, this.initialDate});

  final DateTime? initialDate;

  @override
  State<DailyReportScreen> createState() => _DailyReportScreenState();
}

class _ReportData {
  const _ReportData(this.stats, this.summary, this.summaryError);
  final DayStats stats;
  final String? summary;
  final String? summaryError;
}

class _DailyReportScreenState extends State<DailyReportScreen> {
  late DateTime _day = dayOf(widget.initialDate ?? DateTime.now());
  late Future<_ReportData> _future = _fetch();

  bool get _isToday => _day == dayOf(DateTime.now());

  Future<_ReportData> _fetch() async {
    final day = _day;
    final stats = await CareRepository.instance.dayStats(day);
    String? summary;
    String? summaryError;
    try {
      summary = await ApiClient.instance.dailyReport(day);
    } on ApiException catch (e) {
      summaryError = e.message;
    } catch (e) {
      summaryError = friendlyError(e);
    }
    return _ReportData(stats, summary, summaryError);
  }

  void _go(int deltaDays) {
    final next = _day.add(Duration(days: deltaDays));
    if (next.isAfter(dayOf(DateTime.now()))) return;
    setState(() {
      _day = next;
      _future = _fetch();
    });
  }

  String _dayTitle() {
    final today = dayOf(DateTime.now());
    if (_day == today) return 'Today';
    if (_day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return formatToday(_day);
  }

  /// 0–100 day score: equal parts water, sleep, medication adherence (and mood when logged).
  int _score(DayStats s) {
    final prefs = AppPrefs.instance;
    final parts = <double>[
      (s.waterMl / prefs.waterGoalMl).clamp(0.0, 1.0),
      ((s.sleepHours ?? 0) / prefs.sleepGoalHours).clamp(0.0, 1.0),
      if (s.dosesScheduled > 0 && s.unassignedDoseLogs == 0)
        (s.dosesTaken / s.dosesScheduled).clamp(0.0, 1.0),
      if (s.moodLevel != null) s.moodLevel! / 4,
    ];
    return (parts.reduce((a, b) => a + b) / parts.length * 100).round();
  }

  List<String> _suggestions(DayStats s) {
    final prefs = AppPrefs.instance;
    final out = <String>[];
    if (s.waterMl < prefs.waterGoalMl) {
      out.add('Drink about ${((prefs.waterGoalMl - s.waterMl) / 250).ceil()} more glasses of water, spread through the day.');
    }
    if ((s.sleepHours ?? 0) < prefs.sleepGoalHours) {
      out.add('Start winding down 30 minutes earlier tonight to get closer to ${prefs.sleepGoalHours.toStringAsFixed(prefs.sleepGoalHours % 1 == 0 ? 0 : 1)} hours of sleep.');
    }
    if (s.unassignedDoseLogs == 0 && s.dosesScheduled > 0 && s.dosesTaken < s.dosesScheduled) {
      out.add('Keep reminders on so no dose is missed tomorrow.');
    }
    if (s.moodLevel != null && s.moodLevel! <= 1) {
      out.add('Your mood was low. A short walk or talking to someone you trust can help.');
    }
    if (out.isEmpty) out.add('Great day. Keep the same routine tomorrow.');
    return out.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ScrollEdgeFade(
            child: FutureBuilder<_ReportData>(
              future: _future,
              builder: (context, snap) {
                final children = <Widget>[
                  Semantics(header: true, child: Text('Daily report', style: NovaType.largeTitle.copyWith(color: c.textPrimary))),
                  const SizedBox(height: 8),
                  _DateSwitcher(
                    title: _dayTitle(),
                    onPrev: () => _go(-1),
                    onNext: _isToday ? null : () => _go(1),
                  ),
                  const SizedBox(height: NovaSpace.gap),
                ];
                if (snap.connectionState != ConnectionState.done) {
                  children.addAll(const [
                    SkeletonCard(lines: 2, height: 120),
                    SizedBox(height: NovaSpace.gap),
                    SkeletonCard(lines: 3),
                  ]);
                } else if (snap.hasError) {
                  children.add(ErrorCard(message: friendlyError(snap.error!), onRetry: () => _go(0)));
                } else {
                  children.addAll(_content(context, snap.data!));
                }
                return ListView(
                  padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 110),
                  children: children,
                );
              },
            ),
          ),
          Positioned(top: pad.top + 4, left: NovaSpace.margin, child: const GlassBackButton(label: 'Home')),
          Positioned(
            right: NovaSpace.margin,
            bottom: (pad.bottom > 0 ? pad.bottom : 12) + 8,
            child: FutureBuilder<_ReportData>(
              future: _future,
              builder: (context, snap) => Pressable(
                onTap: snap.hasData ? () => _copy(context, snap.data!) : null,
                semanticLabel: 'Copy report',
                child: Glass(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.doc_on_doc, size: 20, color: c.primary),
                      const SizedBox(width: 8),
                      Text('Copy report', style: NovaType.headline.copyWith(color: c.primary)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, _ReportData data) {
    final s = data.stats;
    final text = StringBuffer()
      ..writeln('NOVA Health daily report: ${formatToday(_day)}')
      ..writeln('Day score: ${_score(s)}/100')
      ..writeln('Water: ${(s.waterMl / 1000).toStringAsFixed(1)} L')
      ..writeln('Sleep: ${s.sleepHours == null ? 'not logged' : '${s.sleepHours!.toStringAsFixed(1)} h'}')
      ..writeln('Medications: ${s.dosesTaken} of ${s.dosesScheduled} doses');
    if (s.unassignedDoseLogs > 0) {
      text.writeln('${s.unassignedDoseLogs} dose log(s) without a scheduled time');
    }
    text
      ..writeln()
      ..writeln(data.summary ?? '')
      ..writeln()
      ..writeln('Guidance, not medical advice.');
    Clipboard.setData(ClipboardData(text: text.toString().trim()));
    showNovaToast(context, 'Report copied');
  }

  List<Widget> _content(BuildContext context, _ReportData data) {
    final c = context.nova;
    final s = data.stats;
    final prefs = AppPrefs.instance;
    final score = _score(s);
    const moods = ['Awful', 'Low', 'Okay', 'Good', 'Great'];

    return [
      NovaCard(
        child: Row(
          children: [
            SizedBox(
              width: 110,
              height: 110,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ActivityRings(
                    size: 110,
                    stroke: 12,
                    semanticLabel: 'Day score $score out of 100',
                    rings: [RingValue(score / 100, c.primary)],
                  ),
                  ExcludeSemantics(child: Text('$score', style: NovaType.number(30).copyWith(color: c.textPrimary))),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Day score', style: NovaType.headline.copyWith(color: c.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    score >= 80 ? 'A strong day.' : (score >= 50 ? 'A fair day with room to improve.' : 'A tough day. Small steps help.'),
                    style: NovaType.subhead.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: NovaSpace.gap),
      NovaCard(
        tone: NovaCardTone.tinted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.auto_awesome_rounded, size: 20, color: c.primary),
              const SizedBox(width: 8),
              Text('Summary', style: NovaType.headline.copyWith(color: c.textPrimary)),
            ]),
            const SizedBox(height: 8),
            if (data.summary != null && data.summary!.trim().isNotEmpty)
              Text(data.summary!.trim(), style: NovaType.body.copyWith(color: c.textPrimary))
            else
              Text(
                data.summaryError == null
                    ? 'No summary for this day yet.'
                    : 'The summary is not available right now (${data.summaryError}). Your numbers below are still up to date.',
                style: NovaType.subhead.copyWith(color: c.textSecondary),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Based on:', style: NovaType.caption.copyWith(color: c.textSecondary)),
              SourceChip(label: 'Sleep', color: c.sleep),
              SourceChip(label: 'Hydration', color: c.water),
              SourceChip(label: 'Medications', color: c.primary),
              SourceChip(label: 'Mood', color: c.warning),
            ]),
            const SizedBox(height: 8),
            const DisclaimerNote(),
          ],
        ),
      ),
      const SectionLabel('Sections'),
      _MetricCard(
        icon: Icons.bedtime_outlined,
        color: c.sleep,
        title: 'Sleep',
        value: s.sleepHours == null ? 'Not logged' : '${s.sleepHours!.toStringAsFixed(1)} h',
        progress: (s.sleepHours ?? 0) / prefs.sleepGoalHours,
        insight: s.sleepHours == null
            ? 'Log last night\'s sleep in Track to see this.'
            : (s.sleepHours! >= prefs.sleepGoalHours ? 'You reached your sleep goal.' : '${(prefs.sleepGoalHours - s.sleepHours!).toStringAsFixed(1)} h under your goal.'),
      ),
      const SizedBox(height: 12),
      _MetricCard(
        icon: Icons.water_drop_outlined,
        color: c.water,
        title: 'Hydration',
        value: '${(s.waterMl / 1000).toStringAsFixed(1)} of ${(prefs.waterGoalMl / 1000).toStringAsFixed(1)} L',
        progress: s.waterMl / prefs.waterGoalMl,
        insight: s.waterMl >= prefs.waterGoalMl ? 'Water goal reached.' : '${prefs.waterGoalMl - s.waterMl} ml left to reach your goal.',
      ),
      const SizedBox(height: 12),
      _MetricCard(
        icon: Icons.restaurant_outlined,
        color: c.warning,
        title: 'Nutrition',
        value: s.calories == 0 ? 'No meals scanned' : '${formatThousands(s.calories)} kcal',
        progress: null,
        insight: s.calories == 0 ? 'Scan a meal to estimate calories.' : 'From the meals you scanned and confirmed.',
      ),
      const SizedBox(height: 12),
      _MetricCard(
        icon: Icons.medication_rounded,
        color: c.primary,
        title: 'Medications',
        value: s.dosesScheduled == 0 ? 'None scheduled' : '${s.dosesTaken} of ${s.dosesScheduled} doses',
        progress: s.dosesScheduled == 0 || s.unassignedDoseLogs > 0 ? null : s.dosesTaken / s.dosesScheduled,
        insight: s.unassignedDoseLogs > 0
            ? '${s.unassignedDoseLogs} dose log(s) without a scheduled time.'
            : (s.dosesScheduled == 0
                ? 'No medication reminders on this day.'
                : (s.dosesTaken >= s.dosesScheduled ? 'Every dose taken.' : '${s.dosesScheduled - s.dosesTaken} dose(s) not logged.')),
      ),
      const SizedBox(height: 12),
      NovaCard(
        child: Row(
          children: [
            IconBadge(icon: Icons.mood_rounded, size: 40, background: c.warningSurface, foreground: c.warningContent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mood', style: NovaType.headline.copyWith(color: c.textPrimary)),
                  Text(s.moodLevel == null ? 'Not logged' : moods[s.moodLevel!], style: NovaType.subhead.copyWith(color: c.textSecondary)),
                ],
              ),
            ),
            if (s.moodLevel != null) MoodFace(level: s.moodLevel!, color: c.primary, size: 32),
          ],
        ),
      ),
      const SectionLabel('Top 3 suggestions for tomorrow'),
      NovaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, tip) in _suggestions(s).indexed) ...[
              if (i > 0) const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: c.primaryTint, shape: BoxShape.circle),
                    child: Text('${i + 1}', style: NovaType.footnote.copyWith(fontWeight: FontWeight.w700, color: c.primary)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tip, style: NovaType.subhead.copyWith(color: c.textPrimary))),
                ],
              ),
            ],
            const SizedBox(height: 12),
            const DisclaimerNote(),
          ],
        ),
      ),
    ];
  }
}

class _DateSwitcher extends StatelessWidget {
  const _DateSwitcher({required this.title, required this.onPrev, required this.onNext});
  final String title;
  final VoidCallback onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Row(
      children: [
        GlassIconButton(icon: CupertinoIcons.chevron_left, label: 'Previous day', onTap: onPrev, iconColor: c.primary),
        Expanded(
          child: Text(title, textAlign: TextAlign.center, style: NovaType.headline.copyWith(color: c.textPrimary)),
        ),
        Opacity(
          opacity: onNext == null ? 0.35 : 1,
          child: GlassIconButton(icon: CupertinoIcons.chevron_right, label: 'Next day', onTap: onNext, iconColor: c.primary),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.progress,
    required this.insight,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String value;
  final double? progress;
  final String insight;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: NovaType.headline.copyWith(color: c.textPrimary))),
              Text(value, style: NovaType.subhead.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary)),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(NovaRadius.capsule),
              child: LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0),
                minHeight: 8,
                color: color,
                backgroundColor: color.withValues(alpha: 0.16),
                semanticsLabel: '$title progress',
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(insight, style: NovaType.footnote.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }
}
