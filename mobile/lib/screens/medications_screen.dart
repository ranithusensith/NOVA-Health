import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/care_models.dart';
import '../data/care_repository.dart';
import '../data/health_repository.dart';
import '../data/sample_data.dart';
import '../data/scan_models.dart';
import '../services/api_client.dart';
import '../services/privacy_diagnostics.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/scroll_edge_fade.dart';
import '../widgets/states.dart';
import 'scan_camera_screen.dart';

void openMedications(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MedicationsScreen()));
}

/// 03 Medications — today's timeline (Morning / Afternoon / Evening), every
/// active medicine, add / edit / stop, and mark a dose taken.
class MedicationsScreen extends StatefulWidget {
  const MedicationsScreen({super.key});

  @override
  State<MedicationsScreen> createState() => _MedicationsScreenState();
}

class _MedicationsData {
  const _MedicationsData(this.schedule, this.meds);
  final List<DoseSlot> schedule;
  final List<MedicationRecord> meds;
}

class _MedicationsScreenState extends State<MedicationsScreen> with WidgetsBindingObserver {
  late Future<_MedicationsData> _future = _fetch();
  final Set<DoseKey> _busy = {};

  Future<_MedicationsData> _fetch() async {
    final repo = CareRepository.instance;
    final results = await Future.wait([repo.todaySchedule(), repo.medications()]);
    return _MedicationsData(results[0] as List<DoseSlot>, results[1] as List<MedicationRecord>);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HealthRepository.changes.addListener(_reload);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HealthRepository.changes.removeListener(_reload);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  void _reload() {
    if (!mounted) return;
    final data = _fetch();
    setState(() {
      _future = data;
    });
  }

  Future<void> _take(DoseSlot slot) async {
    final id = slot.occurrence.key;
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      final inserted = await CareRepository.instance.logDose(slot.occurrence);
      if (mounted) {
        showNovaToast(context, inserted == null ? 'This dose was already logged' : '${slot.medication.name} marked as taken');
      }
    } catch (e) {
      logAppEvent('logDose failed');
      if (mounted) showNovaToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _undo(DoseSlot slot) async {
    final id = slot.occurrence.key;
    final logId = slot.logId;
    if (logId == null) return;
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await CareRepository.instance.undoDose(slot.occurrence, logId);
    } catch (e) {
      logAppEvent('undoLastDose failed');
      if (mounted) showNovaToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _openEditor([MedicationRecord? existing]) async {
    await showMedicationEditor(context, existing: existing);
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
            child: RefreshIndicator(
              onRefresh: () async {
                _reload();
                await _future.catchError((_) => const _MedicationsData([], []));
              },
              child: FutureBuilder<_MedicationsData>(
                future: _future,
                builder: (context, snap) {
                  final children = <Widget>[
                    Semantics(header: true, child: Text('Medications', style: NovaType.largeTitle.copyWith(color: c.textPrimary))),
                    const SizedBox(height: 2),
                  ];
                  if (snap.connectionState != ConnectionState.done && !snap.hasData) {
                    children.addAll(const [
                      SizedBox(height: NovaSpace.gap),
                      SkeletonCard(lines: 4),
                      SizedBox(height: NovaSpace.gap),
                      SkeletonCard(lines: 2),
                    ]);
                  } else if (snap.hasError) {
                    children.addAll([
                      const SizedBox(height: NovaSpace.gap),
                      ErrorCard(message: friendlyError(snap.error!), onRetry: _reload),
                    ]);
                  } else {
                    children.addAll(_content(context, snap.data!));
                  }
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 120),
                    children: children,
                  );
                },
              ),
            ),
          ),
          Positioned(top: pad.top + 4, left: NovaSpace.margin, child: const GlassBackButton(label: 'Home')),
          Positioned(
            top: pad.top + 4,
            right: NovaSpace.margin,
            child: GlassIconButton(
              icon: CupertinoIcons.plus,
              label: 'Add medication',
              tinted: true,
              iconSize: 22,
              onTap: _openEditor,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context, _MedicationsData data) {
    final c = context.nova;
    if (data.meds.isEmpty) {
      return [
        Text('Nothing scheduled yet', style: NovaType.subhead.copyWith(color: c.textSecondary)),
        const SizedBox(height: NovaSpace.gap),
        EmptyStateCard(
          icon: Icons.medication_rounded,
          title: 'No medications added',
          body: 'Add a medicine by hand, or scan a prescription and check the details before saving.',
          actionLabel: 'Add medication',
          onAction: _openEditor,
          secondaryLabel: 'Scan prescription instead',
          onSecondary: () => Navigator.of(context).push(
            MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ScanCameraScreen()),
          ),
        ),
      ];
    }

    final taken = data.schedule.where((s) => s.state == DoseState.taken).length;
    final missed = data.schedule.where((s) => s.state == DoseState.missed).length;
    final groups = <String, List<DoseSlot>>{};
    for (final s in data.schedule) {
      groups.putIfAbsent(s.period, () => []).add(s);
    }

    return [
      Text(
        data.schedule.isEmpty ? 'No scheduled doses today' : '$taken of ${data.schedule.length} doses taken today',
        style: NovaType.subhead.copyWith(color: c.textSecondary),
      ),
      if (data.schedule.any((slot) => slot.state == DoseState.unverified)) ...[
        const SizedBox(height: NovaSpace.gap),
        const _Banner(
          icon: CupertinoIcons.info_circle,
          text: 'An earlier log has no scheduled time. Check your dosing records before logging another dose.',
        ),
      ],
      if (missed > 0) ...[
        const SizedBox(height: NovaSpace.gap),
        _Banner(
          icon: CupertinoIcons.exclamationmark_circle,
          text: missed == 1
              ? 'You missed 1 dose today. Take it now only if your doctor or the label says it is okay.'
              : 'You missed $missed doses today. Check the label or ask your pharmacist before taking a late dose.',
        ),
      ],
      for (final period in const ['Morning', 'Afternoon', 'Evening'])
        if (groups[period] != null) ...[
          SectionLabel(period),
          NovaCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < groups[period]!.length; i++) ...[
                  if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator, indent: 64),
                  _DoseRow(
                    slot: groups[period]![i],
                    busy: _busy.contains(groups[period]![i].occurrence.key),
                    onTake: () => _take(groups[period]![i]),
                    onUndo: () => _undo(groups[period]![i]),
                  ),
                ],
              ],
            ),
          ),
        ],
      const SectionLabel('All medicines'),
      NovaCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < data.meds.length; i++) ...[
              if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator, indent: 64),
              _MedicineRow(med: data.meds[i], onTap: () => _openEditor(data.meds[i])),
            ],
          ],
        ),
      ),
      const SizedBox(height: NovaSpace.gap),
      const Center(child: DisclaimerNote(icon: true)),
    ];
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.warningSurface, borderRadius: BorderRadius.circular(18)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c.warningContent),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: NovaType.footnote.copyWith(color: c.textPrimary))),
        ],
      ),
    );
  }
}

class _DoseRow extends StatelessWidget {
  const _DoseRow({required this.slot, required this.busy, required this.onTake, required this.onUndo});
  final DoseSlot slot;
  final bool busy;
  final VoidCallback onTake;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final (IconData icon, Color color, String status) = switch (slot.state) {
      DoseState.taken => (CupertinoIcons.checkmark_circle_fill, c.success, 'Taken'),
      DoseState.due => (CupertinoIcons.bell_fill, c.primary, 'Due now'),
      DoseState.upcoming => (CupertinoIcons.clock, c.primary, 'Upcoming'),
      DoseState.missed => (CupertinoIcons.exclamationmark_circle_fill, c.alert, 'Missed'),
      DoseState.unverified => (CupertinoIcons.info_circle, c.warningContent, 'Unverified'),
    };
    final time = formatDoseClock(slot);
    return Semantics(
      label: '${slot.medication.label} at $time, $status',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(slot.medication.label, style: NovaType.headline.copyWith(color: c.textPrimary)),
                    Text('$time · $status', style: NovaType.footnote.copyWith(color: c.textSecondary)),
                  ],
                ),
              ),
            ),
            if (busy)
              const Padding(padding: EdgeInsets.all(12), child: CupertinoActivityIndicator())
            else if (slot.state == DoseState.taken)
              NovaButton(label: 'Undo', kind: NovaButtonKind.plain, expand: false, height: 44, onPressed: onUndo)
            else if (slot.state != DoseState.unverified)
              NovaButton(
                label: 'Take',
                kind: slot.state == DoseState.upcoming ? NovaButtonKind.secondary : NovaButtonKind.primary,
                expand: false,
                height: 44,
                onPressed: onTake,
              ),
          ],
        ),
      ),
    );
  }
}

class _MedicineRow extends StatelessWidget {
  const _MedicineRow({required this.med, required this.onTap});
  final MedicationRecord med;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final plan = med.prescriptionPlan;
    final times = med.times.isEmpty
        ? (plan?.timing == PrescriptionTiming.interval
            ? plan!.intervalLabel
            : plan?.timing.label ?? 'No fixed schedule')
        : med.times.map((t) {
            final p = parseClock(t)!;
            return formatClock(DateTime(2000, 1, 1, p.hour, p.minute));
          }).join(' · ');
    final until = med.endDate == null ? '' : ' · until ${med.endDate!.day}/${med.endDate!.month}';
    return Pressable(
      onTap: onTap,
      semanticLabel: 'Edit ${med.label}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            IconBadge(icon: med.source == 'scan' ? Icons.document_scanner_outlined : Icons.medication_rounded, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(med.label, style: NovaType.headline.copyWith(color: c.textPrimary)),
                  Text('$times$until', style: NovaType.footnote.copyWith(color: c.textSecondary)),
                  if (plan?.instructions != null)
                    Text(plan!.instructions!, style: NovaType.footnote.copyWith(color: c.textSecondary)),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 18, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- editor sheet

/// Add or edit a medication in a bottom sheet. Returns true when saved.
Future<bool> showMedicationEditor(BuildContext context,
    {MedicationRecord? existing}) async {
  final accountId = ApiClient.instance.aiAccountId;
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MedicationEditor(
      existing: existing,
      accountId: accountId,
      reviewMedication: CareRepository.instance.reviewMedication,
    ),
  );
  return saved ?? false;
}

class MedicationEditor extends StatefulWidget {
  const MedicationEditor(
      {super.key,
      this.existing,
      required this.accountId,
      required this.reviewMedication});
  final MedicationRecord? existing;
  final String? accountId;
  final Future<PrescriptionConfirmation> Function(Map<String, dynamic>)
      reviewMedication;

  @override
  State<MedicationEditor> createState() => _MedicationEditorState();
}

class _MedicationEditorState extends State<MedicationEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _dose = TextEditingController(text: widget.existing?.dosage ?? '');
  final _instructions = TextEditingController();
  final _frequency = TextEditingController();
  late final String _draftId = _newDraftId();
  late List<String> _times = <String>{...?widget.existing?.times}.toList();
  late DateTime? _start = _isEdit ? widget.existing!.startDate : DateTime.now();
  late DateTime? _end = widget.existing?.endDate;
  PrescriptionPlan? get _plan => widget.existing?.prescriptionPlan;
  bool get _canChooseTiming =>
      !_isEdit ||
      (widget.existing!.source == 'manual' &&
          _plan?.timing != PrescriptionTiming.interval);
  late PrescriptionTiming _chosenTiming = _plan?.timing ??
      (_times.isEmpty
          ? PrescriptionTiming.unscheduled
          : PrescriptionTiming.daily);
  PrescriptionTiming get _timing => _canChooseTiming
      ? _chosenTiming
      : (_plan?.timing ??
          (_times.isEmpty
              ? PrescriptionTiming.unscheduled
              : PrescriptionTiming.daily));
  bool get _showTimes =>
      _timing == PrescriptionTiming.daily ||
      (!_canChooseTiming && _plan == null);
  late bool _remind =
      (_isEdit && _timing.isScheduled) && widget.existing!.remindersEnabled;
  bool _saving = false;
  String? _error;
  PrescriptionConfirmation? _review;

  bool get _isEdit => widget.existing != null;

  static String _newDraftId() {
    final random = Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  void _change(VoidCallback update) {
    if (_saving) return;
    setState(() {
      update();
      _review = null;
      _error = null;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _dose.dispose();
    _instructions.dispose();
    _frequency.dispose();
    super.dispose();
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
        context: context, initialTime: const TimeOfDay(hour: 20, minute: 0));
    if (picked == null || !mounted) return;
    final t = clockString(picked.hour, picked.minute);
    if (_times.contains(t)) return;
    _change(() => _times = [..._times, t]..sort());
  }

  Future<void> _pickDate({required bool end}) async {
    final now = DateTime.now();
    final start = _start ?? dayOf(now);
    final proposedEnd = _end ?? start;
    final initial = end && !proposedEnd.isBefore(start) ? proposedEnd : start;
    final earliest = end ? start : DateTime(now.year - 1);
    final latest = DateTime(now.year + 3);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.isBefore(earliest) ? initial : earliest,
      lastDate: initial.isAfter(latest) ? initial : latest,
    );
    if (picked == null || !mounted) return;
    _change(() {
      if (end) {
        _end = picked;
      } else {
        _start = picked;
        if (_end != null && _end!.isBefore(picked)) _end = null;
      }
    });
  }

  Future<void> _save() async {
    final accountId = widget.accountId;
    final existing = widget.existing;
    final token = _review?.reviewToken;
    final name = _name.text.trim();
    final dose = _dose.text.trim();
    final instructions = _instructions.text.trim();
    final frequency = _frequency.text.trim();
    final timing = _timing;
    if (accountId == null ||
        (existing != null && existing.reviewRevision == null)) {
      setState(() => _error =
          'Reopen Medications while signed in to check this medication.');
      return;
    }
    if (name.isEmpty ||
        name.length > 120 ||
        dose.length > 60 ||
        instructions.length > 500 ||
        frequency.length > 160) {
      setState(() => _error =
          'Enter a medicine name and check the length of the details.');
      return;
    }
    if (timing == PrescriptionTiming.daily && _times.isEmpty) {
      setState(() => _error = 'Choose at least one daily dose time.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.reviewMedication({
        'expected_account_id': accountId,
        'draft_id': _draftId,
        if (existing != null) ...{
          'medication_id': existing.id,
          'expected_revision': existing.reviewRevision,
        } else
          'instructions': instructions.isEmpty ? null : instructions,
        if (!_isEdit &&
            timing == PrescriptionTiming.daily &&
            frequency.isNotEmpty)
          'frequency': frequency,
        if (_canChooseTiming) 'timing': timing.value,
        'name': name,
        'dosage': dose.isEmpty ? null : dose,
        'times': timing == PrescriptionTiming.daily ? [..._times] : <String>[],
        'start_date': _start == null ? null : ymd(_start!),
        'end_date': _end == null ? null : ymd(_end!),
        'reminders_enabled': timing.isScheduled && _remind,
        if (token != null) 'review_token': token,
      });
      if (!mounted) return;
      if (result.activated) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _saving = false;
          _review = result;
          if (!result.safetyCheck.completed ||
              result.reviewToken == null ||
              result.safetyCheck.warnings.isEmpty) {
            _review = null;
            _error =
                'NOVA could not complete the safety review. Try again before saving.';
          }
        });
      }
    } catch (e) {
      logAppEvent('Saving medication failed');
      if (mounted) {
        setState(() {
          _saving = false;
          _review = null;
          _error = e is ApiException ? e.message : friendlyError(e);
        });
      }
    }
  }

  Future<void> _stop() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Stop ${widget.existing!.name}?'),
        content: const Text(
            'It leaves your schedule today. Past doses stay in your history.'),
        actions: [
          CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      await CareRepository.instance
          .stopMedication(widget.existing!.id, widget.accountId);
      if (mounted) navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ApiException ? e.message : friendlyError(e);
        });
      }
    }
  }

  String _date(DateTime d) => '${d.day}/${d.month}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final fieldStyle = NovaType.body.copyWith(color: c.textPrimary);
    final plan = _plan;
    final firstDose = plan?.firstDoseAt?.toLocal();
    final warnings = _review?.safetyCheck.warnings ?? const <ScanWarning>[];
    final editor = Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 8, keyboard + 8),
      child: Glass(
        radius: NovaRadius.sheet,
        fillOpacity: 0.94,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                      color: c.textSecondary.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(3)),
                ),
              ),
              const SizedBox(height: 14),
              Text(_isEdit ? 'Edit medication' : 'Add medication',
                  style: NovaType.title2.copyWith(color: c.textPrimary)),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                readOnly: _saving,
                onChanged: (_) => _change(() {}),
                textCapitalization: TextCapitalization.words,
                style: fieldStyle,
                decoration: novaFieldDecoration(c, 'Medicine name',
                    icon: Icons.medication_rounded),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _dose,
                readOnly: _saving,
                onChanged: (_) => _change(() {}),
                style: fieldStyle,
                decoration: novaFieldDecoration(
                    c, 'Dose (e.g. 10 mg, 1 tablet)',
                    icon: CupertinoIcons.plus_circle),
              ),
              const SizedBox(height: 16),
              if (_canChooseTiming) ...[
                InputDecorator(
                  decoration: novaFieldDecoration(c, 'Schedule',
                      icon: CupertinoIcons.clock),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<PrescriptionTiming>(
                      value: _chosenTiming,
                      isExpanded: true,
                      isDense: true,
                      items: [
                        for (final timing in [
                          PrescriptionTiming.unscheduled,
                          PrescriptionTiming.daily,
                          PrescriptionTiming.asNeeded
                        ])
                          DropdownMenuItem(
                              value: timing, child: Text(timing.label)),
                      ],
                      onChanged: (timing) {
                        if (timing != null) {
                          _change(() => _chosenTiming = timing);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (!_isEdit && _timing == PrescriptionTiming.daily) ...[
                TextField(
                  controller: _frequency,
                  readOnly: _saving,
                  onChanged: (_) => _change(() {}),
                  style: fieldStyle,
                  decoration: novaFieldDecoration(
                      c, 'Written frequency (optional)',
                      icon: CupertinoIcons.clock),
                ),
                const SizedBox(height: 10),
              ],
              if (!_isEdit) ...[
                TextField(
                  controller: _instructions,
                  readOnly: _saving,
                  onChanged: (_) => _change(() {}),
                  maxLines: 2,
                  style: fieldStyle,
                  decoration: novaFieldDecoration(
                      c, 'Written instructions (optional)',
                      icon: CupertinoIcons.doc_text),
                ),
                const SizedBox(height: 12),
              ],
              if (plan != null) ...[
                Text('Original directions',
                    style: NovaType.headline.copyWith(color: c.textPrimary)),
                for (final text in [
                  plan.dosageText,
                  plan.frequency,
                  plan.instructions,
                  plan.durationText
                ].whereType<String>())
                  Text(text,
                      style: NovaType.subhead.copyWith(color: c.textSecondary)),
                if (plan.timing == PrescriptionTiming.interval &&
                    firstDose != null)
                  Text(
                    '${plan.intervalLabel} · First dose ${_date(firstDose)} at ${formatClock(firstDose)}',
                    style: NovaType.subhead.copyWith(color: c.textSecondary),
                  ),
                const SizedBox(height: 12),
              ],
              if (_timing.isScheduled)
                Row(
                  children: [
                    Expanded(
                        child: Text('Reminders',
                            style: NovaType.headline
                                .copyWith(color: c.textPrimary))),
                    Semantics(
                      label: 'Reminders',
                      child: CupertinoSwitch(
                        value: _remind,
                        activeTrackColor: c.success,
                        onChanged: (v) => _change(() => _remind = v),
                      ),
                    ),
                  ],
                ),
              if (_showTimes) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in _times)
                      InputChip(
                        label: Text(formatClock(DateTime(2000, 1, 1,
                            parseClock(t)!.hour, parseClock(t)!.minute))),
                        onDeleted: () =>
                            _change(() => _times = [..._times]..remove(t)),
                        deleteButtonTooltipMessage: 'Remove time',
                        shape: const StadiumBorder(),
                        side: BorderSide.none,
                        backgroundColor: c.primaryTint,
                        labelStyle: NovaType.subhead.copyWith(
                            color: c.primary, fontWeight: FontWeight.w600),
                      ),
                    ActionChip(
                      avatar:
                          Icon(CupertinoIcons.plus, size: 16, color: c.primary),
                      label: const Text('Add time'),
                      onPressed: _addTime,
                      shape: const StadiumBorder(),
                      side: BorderSide(color: c.separator),
                      backgroundColor: c.surface,
                      labelStyle: NovaType.subhead.copyWith(color: c.primary),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _DateField(
                      label: 'Starts',
                      value: _start == null ? 'No start date' : _date(_start!),
                      onTap: plan?.timing == PrescriptionTiming.interval
                          ? null
                          : () => _pickDate(end: false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _DateField(
                      label: 'Ends',
                      value: _end == null ? 'No end date' : _date(_end!),
                      onTap: () => _pickDate(end: true),
                      onClear: _end == null
                          ? null
                          : () => _change(() => _end = null),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: NovaType.footnote.copyWith(color: c.alert)),
              ],
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: NovaCard(
                    tone: warnings.any((warning) => warning.isHigh)
                        ? NovaCardTone.alert
                        : NovaCardTone.tinted,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Medication safety warnings',
                            style: NovaType.headline
                                .copyWith(color: c.textPrimary)),
                        for (final warning in warnings)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${warning.isHigh ? 'High priority' : 'Caution'} · ${warning.message}',
                              style: NovaType.subhead
                                  .copyWith(color: c.textPrimary),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              NovaButton(
                label: _saving
                    ? 'Checking…'
                    : (warnings.isEmpty
                        ? 'Check safety and save'
                        : 'Acknowledge warnings and save'),
                onPressed: _saving ? null : _save,
              ),
              if (_isEdit) ...[
                const SizedBox(height: 8),
                NovaButton(
                  label: 'Stop this medicine',
                  kind: NovaButtonKind.destructive,
                  onPressed: _saving ? null : _stop,
                ),
              ] else ...[
                const SizedBox(height: 4),
                NovaButton(
                  label: 'Scan prescription instead',
                  kind: NovaButtonKind.plain,
                  icon: CupertinoIcons.camera,
                  height: 44,
                  onPressed: _saving
                      ? null
                      : () {
                          final navigator = Navigator.of(context);
                          navigator.pop(false);
                          navigator.push(
                            MaterialPageRoute(
                                fullscreenDialog: true,
                                builder: (_) => const ScanCameraScreen()),
                          );
                        },
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return AbsorbPointer(absorbing: _saving, child: editor);
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap, this.onClear});
  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Pressable(
      onTap: onTap,
      semanticLabel: '$label: $value',
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: NovaType.caption.copyWith(color: c.textSecondary)),
                  Text(value, style: NovaType.subhead.copyWith(color: c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (onClear != null)
              IconButton(
                onPressed: onClear,
                tooltip: 'Clear end date',
                icon: Icon(CupertinoIcons.xmark_circle_fill, size: 18, color: c.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
