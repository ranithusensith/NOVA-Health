import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/health_repository.dart';
import '../data/sample_data.dart';
import '../data/scan_models.dart';
import '../services/api_client.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/scroll_edge_fade.dart';
import 'scan_camera_screen.dart';

class _ScanField {
  _ScanField(this.label, this.icon, String value, {this.needsCheck = false}) : controller = TextEditingController(text: value);
  final String label;
  final IconData icon;
  final TextEditingController controller;
  bool needsCheck;
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
  bool _remind = true;

  late final List<List<_ScanField>> _groups = [
    for (final m in widget.scan.medications) _buildFields(m),
  ];
  List<_ScanField> get _fields => [for (final g in _groups) ...g];
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
      field('Frequency', CupertinoIcons.clock, clean(m.frequency)),
      field('Duration', CupertinoIcons.calendar, m.durationDays == null ? null : '${m.durationDays} days'),
    ];
  }

  int get _pending => _fields.where((f) => f.needsCheck).length;

  @override
  void dispose() {
    for (final f in _fields) {
      f.controller.dispose();
    }
    super.dispose();
  }

  /// Reminder times derived from how often the medicine is taken.
  List<String> _timesFor(String frequency) {
    final f = frequency.toLowerCase();
    var n = int.tryParse(RegExp(r'\d+').firstMatch(f)?.group(0) ?? '');
    if (n != null && f.contains('hour') && n > 0) n = (24 / n).round();
    n ??= f.contains('twice') ? 2 : (f.contains('thrice') ? 3 : 1);
    final count = n.clamp(1, 4).toInt();
    if (count == 1) return ['08:00'];
    if (count == 2) return ['08:00', '20:00'];
    if (count == 3) return ['08:00', '14:00', '21:00'];
    return ['08:00', '12:00', '16:00', '20:00'];
  }

  List<Map<String, dynamic>> _medicationDraft() {
    final today = DateTime.now();
    String ymd(DateTime d) => d.toIso8601String().substring(0, 10);

    final rows = <Map<String, dynamic>>[];
    for (final g in _groups) {
      final dose = g[1].controller.text.trim();
      final frequency = g[2].controller.text.trim();
      final days = int.tryParse(RegExp(r'\d+').firstMatch(g[3].controller.text)?.group(0) ?? '');
      rows.add({
        'name': g[0].controller.text.trim(),
        'dosage': dose.isEmpty ? null : dose,
        'times': _remind ? _timesFor(frequency) : <String>[],
        'start_date': ymd(today),
        'end_date': days == null ? null : ymd(today.add(Duration(days: days))),
      });
    }
    return rows;
  }

  Future<void> _confirm() async {
    final scanId = widget.scan.scanId;
    if (_saving || scanId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_groups.isEmpty || _groups.any((g) => g[0].controller.text.trim().isEmpty)) {
      messenger.showSnackBar(const SnackBar(content: Text('Every medicine needs a name.')));
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

      final draft = _medicationDraft();
      final confirm = widget.confirmPrescription ?? ApiClient.instance.confirmPrescription;
      final result = await confirm(scanId, draft, reviewToken);
      if (result.activated && result.safetyCheck.completed) HealthRepository.notifyChanged();
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
    _safetyCheck = null;
    _reviewToken = null;
    _confirmationError = null;
  }

  Widget _safetyCard(BuildContext context) {
    final c = context.nova;
    final check = _safetyCheck;
    final warnings = check?.warnings ?? const <ScanWarning>[];
    final unavailable = widget.scan.scanId == null || check?.completed == false;
    final String title;
    final String detail;
    if (unavailable) {
      title = 'Safety check unavailable';
      detail = _confirmationError ??
          (widget.scan.scanId == null
              ? 'Scan the prescription again with the live service before saving.'
              : 'NOVA must complete the safety check before saving. Try again.');
    } else if (warnings.isNotEmpty) {
      title = 'Medication safety warnings';
      detail = 'Review these warnings before adding the medicines.';
    } else if (check == null) {
      title = 'Safety check required';
      detail = 'NOVA will check the edited details before saving.';
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
                          for (var i = 0; i < _groups[g].length; i++) ...[
                            if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator),
                            _FieldRow(
                              field: _groups[g][i],
                              readOnly: _saving,
                              onEdited: () => setState(() {
                                _groups[g][i].needsCheck = false;
                                _invalidateSafetyCheck();
                              }),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: NovaSpace.gap),
                ],
                NovaCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Remind me', style: NovaType.headline.copyWith(color: c.textPrimary)),
                            Text('Times are set from how often you take it', style: NovaType.footnote.copyWith(color: c.textSecondary)),
                          ],
                        ),
                      ),
                      Semantics(
                        label: 'Reminders',
                        child: CupertinoSwitch(
                          value: _remind,
                          activeTrackColor: c.success,
                          onChanged: _saving
                              ? null
                              : (value) => setState(() {
                                  _remind = value;
                                  _invalidateSafetyCheck();
                                }),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.gap),
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
