import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/care_models.dart';
import '../data/care_repository.dart';
import '../data/health_repository.dart';
import '../theme/nova_theme.dart';
import '../widgets/charts.dart';
import '../widgets/content.dart';
import '../widgets/mood_face.dart';
import '../widgets/states.dart';

enum _Range { today, week }

/// Track history: Today totals or a 7-day view of water, sleep and mood.
/// Reloads whenever something is logged.
class TrackHistory extends StatefulWidget {
  const TrackHistory({super.key});

  @override
  State<TrackHistory> createState() => _TrackHistoryState();
}

class _TrackHistoryState extends State<TrackHistory> {
  _Range _range = _Range.week;
  late Future<List<DayStats>> _future = CareRepository.instance.history(days: 7);

  @override
  void initState() {
    super.initState();
    HealthRepository.changes.addListener(_reload);
  }

  @override
  void dispose() {
    HealthRepository.changes.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _future = CareRepository.instance.history(days: 7));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('History'),
        CupertinoSlidingSegmentedControl<_Range>(
          groupValue: _range,
          onValueChanged: (r) {
            if (r != null) setState(() => _range = r);
          },
          children: {
            _Range.today: _seg('Today', c),
            _Range.week: _seg('7 days', c),
          },
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<DayStats>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const SkeletonCard(lines: 3, height: 140);
            if (snap.hasError) return ErrorCard(message: friendlyError(snap.error!), onRetry: _reload);
            final days = snap.data!;
            return _range == _Range.today ? _today(context, days.last) : _week(context, days);
          },
        ),
      ],
    );
  }

  Widget _seg(String label, NovaColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(label, style: NovaType.subhead.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary)),
      );

  Widget _today(BuildContext context, DayStats d) {
    final c = context.nova;
    const moods = ['Awful', 'Low', 'Okay', 'Good', 'Great'];
    Widget tile(IconData icon, Color color, String label, String value) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(18)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(height: 6),
                Text(label, style: NovaType.caption.copyWith(color: c.textSecondary)),
                Text(value, style: NovaType.headline.copyWith(color: c.textPrimary)),
              ],
            ),
          ),
        );
    return NovaCard(
      child: Column(
        children: [
          Row(children: [
            tile(Icons.directions_walk, c.steps, 'Steps', d.steps == null ? 'Unknown' : '${d.steps} · ${d.stepsSource}'),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            tile(Icons.water_drop_outlined, c.water, 'Water',
                d.waterMl == null ? 'Unknown' : '${d.waterMl} mL'),
            const SizedBox(width: 10),
            tile(Icons.bedtime_outlined, c.sleep, 'Sleep', d.sleepHours == null ? 'Unknown'
                : '${d.sleepHours!.toStringAsFixed(1)} h${d.sleepSource == null ? '' : ' · ${d.sleepSource}'}'),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            tile(Icons.mood_rounded, c.warning, 'Mood', d.moodLevel == null ? '—' : moods[d.moodLevel!]),
            const SizedBox(width: 10),
            tile(
              Icons.medication_rounded, c.primary, 'Doses',
              d.unassignedDoseLogs > 0 ? '${d.unassignedDoseLogs} unassigned'
                  : (d.dosesScheduled == 0 ? '—' : '${d.dosesTaken} of ${d.dosesScheduled}'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _week(BuildContext context, List<DayStats> days) {
    final c = context.nova;
    final labels = [for (final d in days) weekdayShort(d.day)];

    final water = [for (final d in days) d.waterMl == null ? null : d.waterMl! / 1000];
    final loggedWater = water.whereType<double>().toList();
    final waterAvg = loggedWater.isEmpty ? null : loggedWater.reduce((a, b) => a + b) / loggedWater.length;

    final sleep = [for (final d in days) d.sleepHours];
    final sleepLogged = sleep.whereType<double>().toList();
    final sleepAvg = sleepLogged.isEmpty ? null : sleepLogged.reduce((a, b) => a + b) / sleepLogged.length;
    final sleepGoal = days.last.sleepGoalHours;

    final steps = [for (final day in days) day.steps?.toDouble()];
    final stepDays = steps.whereType<double>().length;
    final moods = [for (final d in days) d.moodLevel];
    final moodLogged = moods.whereType<int>().toList();

    String hm(double h) {
      final m = (h * 60).round();
      return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChartCard(
          icon: Icons.directions_walk,
          color: c.steps,
          title: 'Imported steps',
          goalLabel: '',
          chart: SleepBarChart(values: steps, labels: labels, goal: null, color: c.steps, semanticTitle: 'Steps per day', unit: 'steps'),
          summary: stepDays == 0 ? 'No step totals available' : 'Step totals available for $stepDays of ${days.length} days',
        ),
        const SizedBox(height: 12),
        _ChartCard(
          icon: Icons.water_drop_outlined,
          color: c.water,
          title: 'Water',
          goalLabel: days.last.waterGoalMl == null ? '' : 'Target ${days.last.waterGoalMl} mL',
          chart: SleepBarChart(
            values: water,
            labels: labels,
            goal: null,
            color: c.water,
            semanticTitle: 'Water per day',
            unit: 'litres',
          ),
          summary: waterAvg == null ? 'No available water totals'
              : 'Avg ${waterAvg.toStringAsFixed(2)} L on ${loggedWater.length} logged days',
        ),
        const SizedBox(height: 12),
        _ChartCard(
          icon: Icons.bedtime_outlined,
          color: c.sleep,
          title: 'Sleep',
          goalLabel: sleepGoal == null ? '' : 'Goal $sleepGoal h',
          chart: SleepBarChart(values: sleep, labels: labels, goal: sleepGoal, color: c.sleep),
          summary: sleepAvg == null
              ? 'No sleep totals available this week'
              : 'Avg ${hm(sleepAvg)} on ${sleepLogged.length} recorded night${sleepLogged.length == 1 ? '' : 's'}',
        ),
        const SizedBox(height: 12),
        _ChartCard(
          icon: Icons.mood_rounded,
          color: c.warning,
          title: 'Mood',
          goalLabel: '',
          chart: Semantics(
            label: 'Mood per day: ${[
              for (var i = 0; i < days.length; i++)
                '${labels[i]} ${moods[i] == null ? 'not logged' : const ['awful', 'low', 'okay', 'good', 'great'][moods[i]!]}'
            ].join(', ')}',
            excludeSemantics: true,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < days.length; i++)
                  Column(
                    children: [
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: moods[i] == null
                            ? Center(
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(color: c.separator, shape: BoxShape.circle),
                                ),
                              )
                            : MoodFace(level: moods[i]!, color: c.primary, size: 28),
                      ),
                      const SizedBox(height: 6),
                      Text(labels[i], style: NovaType.caption.copyWith(color: c.textSecondary)),
                    ],
                  ),
              ],
            ),
          ),
          summary: moodLogged.isEmpty
              ? 'No mood logged this week'
              : 'Logged on ${moodLogged.length} of 7 days · mostly ${const ['awful', 'low', 'okay', 'good', 'great'][_mostCommon(moodLogged)]}',
        ),
      ],
    );
  }

  int _mostCommon(List<int> values) {
    final counts = <int, int>{};
    for (final v in values) {
      counts[v] = (counts[v] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key > a.key) ? b : a).key;
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.goalLabel,
    required this.chart,
    required this.summary,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String goalLabel;
  final Widget chart;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: NovaType.headline.copyWith(color: c.textPrimary))),
            if (goalLabel.isNotEmpty)
              Text(goalLabel, style: NovaType.caption.copyWith(fontWeight: FontWeight.w600, color: color)),
          ]),
          const SizedBox(height: 12),
          chart,
          const SizedBox(height: 10),
          Text(summary, style: NovaType.footnote.copyWith(color: c.textPrimary)),
        ],
      ),
    );
  }
}
