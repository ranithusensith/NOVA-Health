import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/cycle_logic.dart';
import '../data/profile_models.dart';
import '../data/profile_repository.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/states.dart';

void openCycle(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CycleScreen()));
}

/// Cycle tracking: log period start and end, see the cycle day, the next
/// expected date (an estimate from your own history) and past periods.
class CycleScreen extends StatefulWidget {
  const CycleScreen({super.key});

  @override
  State<CycleScreen> createState() => _CycleScreenState();
}

class _CycleScreenState extends State<CycleScreen> {
  List<PeriodRecord>? _periods;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final periods = await ProfileRepository.instance.periods();
      if (mounted) {
        setState(() {
          _periods = periods;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _logStart() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _StartPeriodSheet(),
    );
    if (saved == true) {
      if (mounted) showNovaToast(context, 'Period start saved');
      await _load();
    }
  }

  Future<void> _endToday(PeriodRecord p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ProfileRepository.instance.endPeriod(p.id, DateTime.now());
      await _load();
    } catch (e) {
      if (mounted) showNovaToast(context, friendlyError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete(PeriodRecord p) async {
    setState(() => _periods = [for (final x in _periods ?? <PeriodRecord>[]) if (x.id != p.id) x]);
    try {
      await ProfileRepository.instance.deletePeriod(p.id);
    } catch (e) {
      if (mounted) {
        showNovaToast(context, friendlyError(e));
        _load();
      }
    }
  }

  static String _flow(String? f) => switch (f) {
        'light' => 'Light flow',
        'medium' => 'Medium flow',
        'heavy' => 'Heavy flow',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final periods = _periods;

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 40),
            children: [
              Semantics(
                header: true,
                child: Text('Cycle tracking', style: NovaType.largeTitle.copyWith(color: c.textPrimary)),
              ),
              const SizedBox(height: NovaSpace.gap),
              if (_error != null)
                ErrorCard(message: _error!, onRetry: _load)
              else if (periods == null)
                const SkeletonCard(lines: 4)
              else if (periods.isEmpty)
                EmptyStateCard(
                  icon: Icons.calendar_month_rounded,
                  title: 'Track your cycle',
                  body: 'Log the first day of your period and NOVA will estimate when the next one is due, '
                      'using your own history.',
                  actionLabel: 'Log period start',
                  onAction: _logStart,
                )
              else ...[
                _summaryCard(c, periods),
                const SizedBox(height: NovaSpace.gap),
                _actions(periods),
                const SectionLabel('History'),
                _history(c, periods),
              ],
              const SizedBox(height: NovaSpace.section),
              Text(
                'Dates are estimates from your own logs. They are not for contraception or pregnancy planning. '
                'See a doctor if your cycles are often shorter than 21 or longer than 35 days, or your periods '
                'are very painful or heavy.',
                style: NovaType.footnote.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: 12),
              const DisclaimerNote(),
            ],
          ),
          Positioned(
            top: pad.top + 4,
            left: NovaSpace.margin,
            child: const GlassBackButton(label: 'Profile'),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(NovaColors c, List<PeriodRecord> periods) {
    final s = summarizeCycle(periods, DateTime.now());
    final until = s.daysUntilNext;
    final day = s.cycleDay;

    String nextText = '';
    if (s.nextStart != null && until != null) {
      final when = until > 1
          ? 'in $until days'
          : until == 1
              ? 'tomorrow'
              : until == 0
                  ? 'today'
                  : '${-until} ${until == -1 ? 'day' : 'days'} ago';
      nextText = 'Next period expected around ${formatDate(s.nextStart!)} ($when)';
    }

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(icon: Icons.calendar_month_rounded, size: 44, foreground: c.sleep),
              const SizedBox(width: 12),
              Text(s.onPeriod ? 'Period in progress' : 'Cycle',
                  style: NovaType.headline.copyWith(color: c.textPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          if (day != null && day <= 60)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Day', style: NovaType.headline.copyWith(color: c.textSecondary)),
                const SizedBox(width: 8),
                Text('$day', style: NovaType.number(48).copyWith(color: c.textPrimary)),
              ],
            ),
          if (nextText.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(nextText, style: NovaType.body.copyWith(color: c.textPrimary)),
          ],
          const SizedBox(height: 6),
          Text(
            s.isEstimate
                ? 'Typical cycle: ${s.avgLength} days. Log two or more periods for your own average.'
                : 'Your average cycle: ${s.avgLength} days.',
            style: NovaType.subhead.copyWith(color: c.textSecondary),
          ),
          if (s.irregular) ...[
            const SizedBox(height: 8),
            Text('Your cycle length varies a lot, so predictions may be less accurate.',
                style: NovaType.footnote.copyWith(color: c.warningContent)),
          ],
        ],
      ),
    );
  }

  Widget _actions(List<PeriodRecord> periods) {
    final s = summarizeCycle(periods, DateTime.now());
    final latest = [...periods]..sort((a, b) => b.start.compareTo(a.start));
    final current = latest.first;
    if (s.onPeriod) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NovaButton(
            label: _busy ? 'Saving…' : 'Period ended today',
            onPressed: _busy ? null : () => _endToday(current),
          ),
          const SizedBox(height: 4),
          NovaButton(label: 'Log another start date', kind: NovaButtonKind.plain, onPressed: _logStart),
        ],
      );
    }
    return NovaButton(label: 'Period started', icon: CupertinoIcons.add, onPressed: _logStart);
  }

  Widget _history(NovaColors c, List<PeriodRecord> periods) {
    final shown = periods.take(12).toList();
    return NovaCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NovaRadius.card),
        child: Column(
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator),
              Dismissible(
                key: ValueKey(shown[i].id),
                direction: DismissDirection.endToStart,
                onDismissed: (_) => _delete(shown[i]),
                background: Container(
                  color: c.alert,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(CupertinoIcons.delete, color: Colors.white),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shown[i].end == null
                                  ? '${formatDate(shown[i].start)} to now'
                                  : '${formatDate(shown[i].start)} to ${formatDate(shown[i].end!)}',
                              style: NovaType.headline.copyWith(color: c.textPrimary),
                            ),
                            if (_flow(shown[i].flow).isNotEmpty || (shown[i].note ?? '').isNotEmpty)
                              Text(
                                [
                                  if (_flow(shown[i].flow).isNotEmpty) _flow(shown[i].flow),
                                  if ((shown[i].note ?? '').isNotEmpty) shown[i].note!,
                                ].join(' · '),
                                style: NovaType.footnote.copyWith(color: c.textSecondary),
                              ),
                          ],
                        ),
                      ),
                      if (shown[i].end != null)
                        Text(
                          '${shown[i].end!.difference(shown[i].start).inDays + 1} days',
                          style: NovaType.subhead.copyWith(color: c.textSecondary),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------- sheet
class _StartPeriodSheet extends StatefulWidget {
  const _StartPeriodSheet();

  @override
  State<_StartPeriodSheet> createState() => _StartPeriodSheetState();
}

class _StartPeriodSheetState extends State<_StartPeriodSheet> {
  final _note = TextEditingController();
  DateTime _start = DateTime.now();
  String? _flow;
  String? _error;
  bool _saving = false;

  static const _flows = {'light': 'Light', 'medium': 'Medium', 'heavy': 'Heavy'};

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: now.subtract(const Duration(days: 120)),
      lastDate: now,
      helpText: 'First day of period',
    );
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ProfileRepository.instance.startPeriod(start: _start, flow: _flow, note: _note.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(NovaRadius.sheet)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Period started', style: NovaType.title2.copyWith(color: c.textPrimary)),
              const SizedBox(height: 16),
              Pressable(
                onTap: _pickDate,
                semanticLabel: 'Start date ${formatDate(_start)}',
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(16)),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.calendar, size: 20, color: c.textSecondary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(formatDate(_start), style: NovaType.body.copyWith(color: c.textPrimary)),
                      ),
                      Text('Change', style: NovaType.subhead.copyWith(color: c.primary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('Flow (optional)', style: NovaType.subhead.copyWith(color: c.textSecondary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _flows.entries)
                    Pressable(
                      onTap: () => setState(() => _flow = _flow == e.key ? null : e.key),
                      semanticLabel: e.value,
                      selected: _flow == e.key,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: _flow == e.key ? c.primaryTint : c.fill,
                          borderRadius: BorderRadius.circular(NovaRadius.capsule),
                          border: Border.all(color: _flow == e.key ? c.primary : Colors.transparent, width: 1.5),
                        ),
                        child: Text(
                          e.value,
                          style: NovaType.subhead.copyWith(
                            color: _flow == e.key ? c.primary : c.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _note,
                maxLength: 120,
                style: NovaType.body.copyWith(color: c.textPrimary),
                decoration: novaFieldDecoration(c, 'Note (optional)', icon: CupertinoIcons.doc_text),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(_error!, style: NovaType.footnote.copyWith(color: c.alert)),
              ],
              const SizedBox(height: 12),
              NovaButton(label: _saving ? 'Saving…' : 'Save', onPressed: _saving ? null : _save),
            ],
          ),
        ),
      ),
    );
  }
}
