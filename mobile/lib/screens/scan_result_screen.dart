import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/care_models.dart';
import '../data/care_repository.dart';
import '../data/sample_data.dart';
import '../data/scan_models.dart';
import '../services/api_client.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/scroll_edge_fade.dart';
import '../widgets/states.dart';
import 'scan_camera_screen.dart';

class _ScanField {
  _ScanField(this.label, this.icon, String value, {this.needsCheck = false}) : controller = TextEditingController(text: value);
  final String label;
  final IconData icon;
  final TextEditingController controller;
  bool needsCheck;
}

class _MedicationDraft {
  _MedicationDraft(this.original, this.fields);

  final ScanMedication original;
  final List<_ScanField> fields;
  PrescriptionTiming? timing;
  DateTime? start;
  DateTime? end;
  bool endChosen = false;
  final scheduleInput = TextEditingController();
  final intervalMinuteInput = TextEditingController();
  TimeOfDay? firstDose;
  bool remindersEnabled = false;
  bool confirmed = false;

  List<String> get dailyTimes => scheduleInput.text.split(',').map((time) => time.trim()).toList()..sort();
  int? get intervalMinutes {
    final hoursText = scheduleInput.text.trim();
    final minutesText = intervalMinuteInput.text.trim();
    final hours = hoursText.isEmpty ? 0 : int.tryParse(hoursText);
    final minutes = minutesText.isEmpty ? 0 : int.tryParse(minutesText);
    if (hours == null || hours < 0 || hours > 8760 || minutes == null || minutes < 0 || minutes > 59) {
      return null;
    }
    return hours * 60 + minutes;
  }

  DateTime? get firstDoseAt {
    final date = start;
    final clock = firstDose;
    if (date == null || clock == null) return null;
    final at = DateTime(date.year, date.month, date.day, clock.hour, clock.minute);
    return at.hour == clock.hour && at.minute == clock.minute ? at : null;
  }

  bool get ready {
    if (timing == null || start == null || !endChosen) return false;
    if (timing == PrescriptionTiming.daily) {
      final times = dailyTimes;
      final clock = RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$');
      return times.length <= 24 && times.toSet().length == times.length && times.every(clock.hasMatch);
    }
    if (timing == PrescriptionTiming.interval) {
      final minutes = intervalMinutes;
      return minutes != null && minutes > 0 && minutes <= 525600 && firstDoseAt != null;
    }
    return true;
  }

  Map<String, dynamic> toJson() {
    final first = start!;
    final plan = PrescriptionPlan(
      timing: timing!,
      dosageText: original.dosage,
      frequency: original.frequency,
      instructions: original.instructions,
      durationText: original.durationText,
      intervalMinutes: intervalMinutes,
      firstDoseAt: firstDoseAt,
    );
    final dose = fields[1].controller.text.trim();
    return {
      'name': fields[0].controller.text.trim(),
      'dosage': dose.isEmpty ? null : dose,
      'times': timing == PrescriptionTiming.daily ? dailyTimes : <String>[],
      'start_date': ymd(first),
      'end_date': end == null ? null : ymd(end!),
      'prescription_plan': plan.toJson(),
      'reminders_enabled': timing!.isScheduled && remindersEnabled,
      'schedule_confirmed': confirmed,
    };
  }
}

/// 04 Scan — prescription result. AI-extracted values are editable and nothing
/// is saved until the user confirms. Low-confidence fields are amber.
class ScanResultScreen extends StatefulWidget {
  const ScanResultScreen({super.key, required this.scan, this.imageBytes, this.confirmPrescription});

  final PrescriptionScan scan;
  final Uint8List? imageBytes;
  final Future<PrescriptionConfirmation> Function(
    String scanId,
    List<Map<String, dynamic>> medications,
    String? reviewToken,
  )? confirmPrescription;

  @override
  State<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends State<ScanResultScreen> {
  final DateTime _scannedAt = DateTime.now();

  late final List<_MedicationDraft> _groups = [
    for (final m in widget.scan.medications) _MedicationDraft(m, _buildFields(m)),
  ];
  List<_ScanField> get _fields => [for (final g in _groups) ...g.fields];
  bool _saving = false;
  late PrescriptionSafetyCheck? _safetyCheck = widget.scan.safetyCheck;
  String? _reviewToken;
  String? _confirmationError;

  String get _confirmLabel {
    if (_saving) return 'Checking…';
    if (_reviewToken != null) return 'Review warnings';
    if (_safetyCheck?.completed == false && widget.scan.scanId != null) return 'Retry safety check';
    return 'Confirm and save';
  }

  /// Fields are amber ("please check") when missing or when the whole scan was low confidence.
  List<_ScanField> _buildFields(ScanMedication m) {
    final low = widget.scan.confidence < 0.75;
    String? clean(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
    _ScanField field(String label, IconData icon, String? value) =>
        _ScanField(label, icon, value ?? '', needsCheck: value == null || low);
    return [
      field('Medicine', Icons.medication_rounded, clean(m.name)),
      field('Dose', CupertinoIcons.plus_circle, clean(m.dosage)),
    ];
  }

  int get _pending => _fields.where((f) => f.needsCheck).length;

  @override
  void dispose() {
    for (final f in _fields) {
      f.controller.dispose();
    }
    for (final group in _groups) {
      group.scheduleInput.dispose();
      group.intervalMinuteInput.dispose();
    }
    super.dispose();
  }

  Future<void> _confirm() async {
    final scanId = widget.scan.scanId;
    if (_saving || scanId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_groups.isEmpty || _groups.any((g) => g.fields.first.controller.text.trim().isEmpty)) {
      messenger.showSnackBar(const SnackBar(content: Text('Every medicine needs a name.')));
      return;
    }
    if (_groups.any((g) => !g.ready || !g.confirmed)) {
      messenger.showSnackBar(const SnackBar(content: Text('Confirm the schedule and course dates for each medicine.')));
      return;
    }
    final navigator = Navigator.of(context);
    final reviewToken = _reviewToken;
    setState(() => _saving = true);
    try {
      if (reviewToken != null || _pending > 0) {
        final reviewingWarnings = reviewToken != null;
        final ok = await showCupertinoDialog<bool>(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: Text(reviewingWarnings ? 'Review medication warnings' : 'Check prescription details'),
            content: Text(reviewingWarnings
                ? _safetyCheck!.warnings.map((warning) => warning.message).join('\n\n')
                : 'Make sure the details match your prescription before continuing.'),
            actions: [
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Go back'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(reviewingWarnings ? 'Acknowledge and save' : 'Continue to safety check'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
      }

      final draft = [for (final group in _groups) group.toJson()];
      final confirm = widget.confirmPrescription ?? ApiClient.instance.confirmPrescription;
      final result = await confirm(scanId, draft, reviewToken);
      if (result.activated && result.safetyCheck.completed) CareRepository.notifyMedicationsChanged();
      if (!mounted) return;
      if (!result.activated || !result.safetyCheck.completed) {
        setState(() {
          _safetyCheck = result.safetyCheck;
          _reviewToken = result.reviewToken;
          _confirmationError = null;
        });
        return;
      }

      final count = draft.length;
      final first = draft.first['name'];
      navigator.popUntil((r) => r.isFirst);
      messenger.showSnackBar(SnackBar(
        content: Text(count == 1 ? '$first added to Medications' : '$count medicines added to Medications'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _safetyCheck = const PrescriptionSafetyCheck();
        _reviewToken = null;
        _confirmationError = e is ApiException ? e.message : 'Check your connection and try again.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _invalidateSafetyCheck() {
    if (_safetyCheck?.completed != false) _safetyCheck = null;
    _reviewToken = null;
    _confirmationError = null;
  }

  void _changeSchedule(_MedicationDraft draft, [VoidCallback? change]) {
    setState(() {
      change?.call();
      draft.confirmed = false;
      _invalidateSafetyCheck();
    });
  }

  Future<void> _pickCourseDate(_MedicationDraft draft, {required bool isEnd}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isEnd ? draft.end ?? draft.start! : draft.start ?? now,
      firstDate: isEnd ? draft.start! : DateTime(now.year - 10),
      lastDate: DateTime(now.year + (isEnd ? 11 : 10), 12, 31),
      helpText: isEnd ? 'Choose last day' : 'Choose start date',
    );
    if (picked == null || !mounted) return;
    _changeSchedule(draft, () {
      if (isEnd) {
        draft.end = picked;
        draft.endChosen = true;
      } else if (draft.start != picked) {
        draft.start = picked;
        draft.end = null;
        draft.endChosen = false;
      }
    });
  }

  Future<void> _pickFirstDose(_MedicationDraft draft) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: draft.firstDose ?? TimeOfDay.now(),
      helpText: 'Choose first dose time',
    );
    if (picked != null && mounted) _changeSchedule(draft, () => draft.firstDose = picked);
  }

  Widget _scheduleCard(BuildContext context, _MedicationDraft draft) {
    final c = context.nova;
    final timing = draft.timing;
    final start = draft.start;
    final end = draft.end;
    final scannedDays = draft.original.suggestedCourseDays;
    final suggestedEnd = start != null && scannedDays != null ? inclusiveCourseEnd(start, scannedDays) : null;
    final directions = [
      if (draft.original.dosage != null) 'Dose: ${draft.original.dosage}',
      if (draft.original.frequency != null) draft.original.frequency!,
      if (draft.original.instructions != null) draft.original.instructions!,
      if (draft.original.durationText != null) draft.original.durationText!,
    ];
    return NovaCard(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Scanned directions', style: NovaType.headline.copyWith(color: c.textPrimary)),
            const SizedBox(height: 4),
            Text(
              directions.isEmpty ? 'No directions could be read. Check the original prescription.' : directions.join('\n'),
              style: NovaType.subhead.copyWith(color: c.textSecondary),
            ),
            if (draft.original.mentionsAsNeeded)
              const Text('The scan mentions as-needed use. Check the prescription before choosing fixed timing.'),
            const SizedBox(height: 12),
            Text('Schedule', style: NovaType.headline.copyWith(color: c.textPrimary)),
            Wrap(
              spacing: 8,
              children: [
                for (final choice in PrescriptionTiming.values)
                  ChoiceChip(
                    label: Text(choice.label),
                    selected: timing == choice,
                    onSelected: _saving
                        ? null
                        : (_) {
                            if (timing != choice) {
                              _changeSchedule(draft, () {
                                draft.timing = choice;
                                draft.scheduleInput.clear();
                                draft.intervalMinuteInput.clear();
                                draft.firstDose = null;
                                if (!choice.isScheduled) draft.remindersEnabled = false;
                              });
                            }
                          },
                  ),
              ],
            ),
            if (timing?.isScheduled == true) ...[
              const SizedBox(height: 8),
              if (timing == PrescriptionTiming.daily)
                TextField(
                  controller: draft.scheduleInput,
                  readOnly: _saving,
                  decoration: novaFieldDecoration(c, 'Daily times (HH:MM, comma-separated)'),
                  onChanged: (_) => _changeSchedule(draft),
                ),
              if (timing == PrescriptionTiming.interval) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: draft.scheduleInput,
                        readOnly: _saving,
                        keyboardType: TextInputType.number,
                        decoration: novaFieldDecoration(c, 'Hours between doses'),
                        onChanged: (_) => _changeSchedule(draft),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: draft.intervalMinuteInput,
                        readOnly: _saving,
                        keyboardType: TextInputType.number,
                        decoration: novaFieldDecoration(c, 'Additional minutes'),
                        onChanged: (_) => _changeSchedule(draft),
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: _saving ? null : () => _pickFirstDose(draft),
                  child: Text(draft.firstDose == null ? 'First dose time' : 'First dose: ${draft.firstDose!.format(context)}'),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Notifications for this medicine'),
                value: draft.remindersEnabled,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          draft.remindersEnabled = value;
                          _invalidateSafetyCheck();
                        }),
              ),
            ],
            Text('Course dates', style: NovaType.headline.copyWith(color: c.textPrimary)),
            Wrap(
              children: [
                TextButton(
                  onPressed: _saving ? null : () => _pickCourseDate(draft, isEnd: false),
                  child: Text(start == null ? 'Choose start date' : 'Starts ${ymd(start)}'),
                ),
                TextButton(
                  onPressed: _saving || start == null ? null : () => _pickCourseDate(draft, isEnd: true),
                  child: Text(end == null ? 'Choose last day' : 'Ends ${ymd(end)}'),
                ),
                ChoiceChip(
                  label: const Text('No end date'),
                  selected: draft.endChosen && end == null,
                  onSelected: _saving || start == null
                      ? null
                      : (_) => _changeSchedule(draft, () {
                            draft.end = null;
                            draft.endChosen = true;
                          }),
                ),
                if (suggestedEnd != null)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _changeSchedule(draft, () {
                              draft.end = suggestedEnd;
                              draft.endChosen = true;
                            }),
                    child: Text('Use scanned duration · Ends ${ymd(suggestedEnd)}'),
                  ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('I confirm the schedule and course dates'),
              value: draft.confirmed,
              onChanged: _saving || !draft.ready
                  ? null
                  : (value) => setState(() {
                        draft.confirmed = value == true;
                        _invalidateSafetyCheck();
                      }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _safetyCard(BuildContext context) {
    final c = context.nova;
    final check = _safetyCheck;
    final warnings = check?.warnings ?? widget.scan.safetyCheck.warnings;
    final unavailable = widget.scan.scanId == null || check?.completed == false;
    final String title;
    final String detail;
    if (unavailable) {
      title = 'Safety check unavailable';
      detail = _confirmationError ??
          (widget.scan.scanId == null
              ? 'Scan the prescription again with the live service before saving.'
              : 'NOVA must complete the safety check before saving. Try again.');
    } else if (check == null) {
      title = 'Safety check required';
      detail = warnings.isEmpty
          ? 'NOVA will check the edited details before saving.'
          : 'NOVA will recheck the current details. Scan warnings are shown below.';
    } else if (warnings.isNotEmpty) {
      title = 'Medication safety warnings';
      detail = 'Review these warnings before adding the medicines.';
    } else {
      title = 'Prescription safety check';
      detail = 'No warnings found by NOVA’s scan check. Your final details will be checked before saving.';
    }
    return Semantics(
      liveRegion: true,
      child: NovaCard(
        tone: unavailable || warnings.any((warning) => warning.isHigh) ? NovaCardTone.alert : NovaCardTone.tinted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: NovaType.headline.copyWith(color: c.textPrimary)),
            const SizedBox(height: 4),
            Text(detail, style: NovaType.subhead.copyWith(color: c.textSecondary)),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${warning.isHigh ? 'High priority' : 'Caution'} · ${warning.message}',
                  style: NovaType.subhead.copyWith(
                    color: c.textPrimary,
                    fontWeight: warning.isHigh ? FontWeight.w600 : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _retake() {
    if (_saving) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ScanCameraScreen()),
    );
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
            bottomHeight: 190,
            child: ListView(
              padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 180),
              children: [
                Semantics(header: true, child: Text('Check the details', style: NovaType.largeTitle.copyWith(color: c.textPrimary))),
                const SizedBox(height: 4),
                Text('We read this from your photo. Edit anything that looks off before saving.',
                    style: NovaType.subhead.copyWith(color: c.textSecondary)),
                const SizedBox(height: NovaSpace.gap),
                NovaCard(
                  padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
                  child: Row(
                    children: [
                      _PhotoThumb(bytes: widget.imageBytes),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Prescription photo', style: NovaType.headline.copyWith(color: c.textPrimary)),
                            Text(
                              'Scanned today, ${formatClock(_scannedAt)} · '
                              '${_pending == 0 ? 'all fields checked' : '$_pending of ${_fields.length} fields need a check'}',
                              style: NovaType.footnote.copyWith(color: c.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      Pressable(
                        onTap: () {},
                        child: SizedBox(
                          height: 44,
                          child: Center(child: Text('View', style: NovaType.subhead.copyWith(fontWeight: FontWeight.w600, color: c.primary))),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.gap),
                _safetyCard(context),
                const SizedBox(height: NovaSpace.gap),
                for (var g = 0; g < _groups.length; g++) ...[
                  if (_groups.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'Medicine ${g + 1} of ${_groups.length}',
                        style: NovaType.footnote.copyWith(color: c.textSecondary),
                      ),
                    ),
                  NovaCard(
                    padding: EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(NovaRadius.card),
                      child: Column(
                        children: [
                          for (final field in _groups[g].fields) ...[
                            if (field != _groups[g].fields.first)
                              Divider(height: 0.5, thickness: 0.5, color: c.separator),
                            _FieldRow(
                              field: field,
                              readOnly: _saving,
                              onEdited: () => _changeSchedule(_groups[g], () => field.needsCheck = false),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: NovaSpace.gap),
                  _scheduleCard(context, _groups[g]),
                  const SizedBox(height: NovaSpace.gap),
                ],
                Text(
                  'AI-extracted — nothing is saved until you confirm.\nGuidance, not medical advice.',
                  textAlign: TextAlign.center,
                  style: NovaType.footnote.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          Positioned(
            top: pad.top + 4,
            left: NovaSpace.margin,
            child: GlassBackButton(label: 'Scan', onTap: _retake),
          ),
          Positioned(
            left: NovaSpace.margin,
            right: NovaSpace.margin,
            bottom: (pad.bottom > 0 ? pad.bottom : 12) + 6,
            child: Glass(
              radius: NovaRadius.sheet,
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NovaButton(
                    label: _confirmLabel,
                    onPressed: _saving || widget.scan.scanId == null ? null : _confirm,
                  ),
                  const SizedBox(height: 4),
                  NovaButton(label: 'Retake photo', kind: NovaButtonKind.plain, height: 44, onPressed: _saving ? null : _retake),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, required this.readOnly, required this.onEdited});
  final _ScanField field;
  final bool readOnly;
  final VoidCallback onEdited;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final warn = field.needsCheck;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: warn ? c.warningSurface : Colors.transparent,
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          IconBadge(
            icon: field.icon,
            size: 36,
            background: warn ? c.warningIconSurface : c.primaryTint,
            foreground: warn ? c.warningContent : c.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  warn ? '${field.label} · Please check' : field.label,
                  style: NovaType.caption.copyWith(color: warn ? c.warningContent : c.textSecondary),
                ),
                const SizedBox(height: 2),
                TextField(
                  controller: field.controller,
                  readOnly: readOnly,
                  onChanged: (_) => onEdited(),
                  style: NovaType.body.copyWith(color: c.textPrimary),
                  cursorColor: c.primary,
                  decoration: InputDecoration.collapsed(hintText: field.label),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          warn
              ? Semantics(
                  label: 'Low confidence, please check',
                  child: Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 22, color: c.warningContent),
                )
              : StatusLabel(icon: CupertinoIcons.checkmark_alt, label: 'Clear', color: c.success),
        ],
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({this.bytes});
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    if (bytes != null) {
      return ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.memory(bytes!, width: 56, height: 56, fit: BoxFit.cover),
        ),
      );
    }
    Widget line(double f, Color col) => FractionallySizedBox(
          widthFactor: f,
          child: Container(height: 4, decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(2))),
        );
    return ExcludeSemantics(
      child: Container(
        width: 56,
        height: 56,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFF6F3EA), borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            line(.8, const Color(0xFF8C8779)),
            line(.55, const Color(0xFFB9B4A5)),
            line(.7, const Color(0xFFB9B4A5)),
            line(.4, const Color(0xFFB9B4A5)),
          ],
        ),
      ),
    );
  }
}
