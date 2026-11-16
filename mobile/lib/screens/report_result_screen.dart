import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/health_repository.dart';
import '../data/lab_repository.dart';
import '../data/profile_models.dart';
import '../data/scan_models.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/lab_flag_chip.dart';
import '../widgets/pressable.dart';
import '../widgets/states.dart';
import 'scan_camera_screen.dart';

/// Lab report scan result. The user ticks the rows to keep; nothing is saved
/// until they confirm. Flags come from the printed reference ranges.
class ReportResultScreen extends StatefulWidget {
  const ReportResultScreen({super.key, required this.scan, this.imageBytes});

  final ReportScan scan;
  final Uint8List? imageBytes;

  @override
  State<ReportResultScreen> createState() => _ReportResultScreenState();
}

class _ReportResultScreenState extends State<ReportResultScreen> {
  bool _saving = false;

  int get _selected => widget.scan.results.where((r) => r.include).length;

  Future<void> _confirm() async {
    if (_saving) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (_selected == 0) {
      messenger.showSnackBar(const SnackBar(content: Text('Tick at least one result to save.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await LabRepository.instance.save(widget.scan);
      HealthRepository.notifyChanged();
      navigator.popUntil((r) => r.isFirst);
      messenger.showSnackBar(SnackBar(content: Text('$saved ${saved == 1 ? 'result' : 'results'} saved to Medical records')));
    } catch (e) {
      debugPrint('Saving lab results failed: $e');
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  void _retake() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const ScanCameraScreen(initialMode: ScanMode.report),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final scan = widget.scan;
    final lowConfidence = scan.confidence < 0.7;
    final flagged = scan.results.where((r) => r.flag == 'low' || r.flag == 'high').length;

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 190),
            children: [
              Semantics(
                header: true,
                child: Text('Check the results', style: NovaType.largeTitle.copyWith(color: c.textPrimary)),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (scan.reportType != null) scan.reportType!,
                  if (scan.reportDate != null) formatDate(scan.reportDate!),
                ].join(' · '),
                style: NovaType.subhead.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: NovaSpace.gap),
              if (lowConfidence) ...[
                NovaCard(
                  tone: NovaCardTone.tinted,
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 22, color: c.warningContent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'The photo was hard to read. Compare each number with your report before saving.',
                          style: NovaType.subhead.copyWith(color: c.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.gap),
              ],
              NovaCard(
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(NovaRadius.card),
                  child: Column(
                    children: [
                      for (var i = 0; i < scan.results.length; i++) ...[
                        if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator),
                        _ResultRow(
                          draft: scan.results[i],
                          onChanged: (v) => setState(() => scan.results[i].include = v),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: NovaSpace.gap),
              Text(
                flagged == 0
                    ? 'Tags are worked out from the reference ranges printed on your report.'
                    : '$flagged ${flagged == 1 ? 'result is' : 'results are'} outside the printed range. '
                        'Only a doctor can tell what that means for you. Please share the report with them.',
                style: NovaType.footnote.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(
                'Nothing is saved until you confirm. Guidance, not medical advice.',
                style: NovaType.footnote.copyWith(color: c.textSecondary),
              ),
            ],
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
                    label: _saving ? 'Saving…' : 'Save $_selected ${_selected == 1 ? 'result' : 'results'}',
                    onPressed: _saving ? null : _confirm,
                  ),
                  const SizedBox(height: 4),
                  NovaButton(label: 'Retake photo', kind: NovaButtonKind.plain, height: 44, onPressed: _retake),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.draft, required this.onChanged});

  final LabResultDraft draft;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final record = LabRecord(
      id: '',
      test: draft.test,
      value: draft.value,
      valueText: draft.valueText,
      unit: draft.unit,
      refLow: draft.refLow,
      refHigh: draft.refHigh,
      flag: draft.flag,
    );
    return Pressable(
      onTap: () => onChanged(!draft.include),
      semanticLabel: '${draft.test}, ${record.resultText}. ${draft.include ? 'Included' : 'Not included'}',
      selected: draft.include,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              draft.include ? CupertinoIcons.check_mark_circled_solid : CupertinoIcons.circle,
              color: draft.include ? c.primary : c.textSecondary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(draft.test, style: NovaType.headline.copyWith(color: c.textPrimary)),
                  Text(
                    record.rangeText.isEmpty ? record.resultText : '${record.resultText} · range ${record.rangeText}',
                    style: NovaType.footnote.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            LabFlagChip(flag: draft.flag),
          ],
        ),
      ),
    );
  }
}
