import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/lab_repository.dart';
import '../data/profile_models.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/lab_flag_chip.dart';
import '../widgets/states.dart';
import 'scan_camera_screen.dart';

void openRecords(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecordsScreen()));
}

/// Medical records: lab results saved from scanned reports, newest first.
class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});

  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  List<LabRecord>? _records;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final records = await LabRepository.instance.list();
      if (mounted) {
        setState(() {
          _records = records;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _scan() async {
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const ScanCameraScreen(initialMode: ScanMode.report),
    ));
    _load();
  }

  Future<void> _delete(LabRecord r) async {
    setState(() => _records = [for (final x in _records ?? <LabRecord>[]) if (x.id != r.id) x]);
    try {
      await LabRepository.instance.delete(r.id);
    } catch (e) {
      if (mounted) {
        showNovaToast(context, friendlyError(e));
        _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final records = _records;

    // Group by report date (null dates last).
    final groups = <String, List<LabRecord>>{};
    for (final r in records ?? <LabRecord>[]) {
      final key = r.reportedOn == null ? 'Date unknown' : formatDate(r.reportedOn!);
      groups.putIfAbsent(key, () => []).add(r);
    }

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 40),
            children: [
              Semantics(
                header: true,
                child: Text('Medical records', style: NovaType.largeTitle.copyWith(color: c.textPrimary)),
              ),
              const SizedBox(height: NovaSpace.gap),
              if (_error != null)
                ErrorCard(message: _error!, onRetry: _load)
              else if (records == null)
                const SkeletonCard(lines: 4)
              else if (records.isEmpty)
                EmptyStateCard(
                  icon: CupertinoIcons.doc_text,
                  title: 'No results yet',
                  body: 'Scan a lab report and NOVA will keep its results here, with a tag for anything '
                      'outside the printed range.',
                  actionLabel: 'Scan a report',
                  onAction: _scan,
                )
              else ...[
                NovaButton(label: 'Scan a report', icon: CupertinoIcons.camera, onPressed: _scan),
                for (final entry in groups.entries) ...[
                  SectionLabel(entry.key),
                  NovaCard(
                    padding: EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(NovaRadius.card),
                      child: Column(
                        children: [
                          for (var i = 0; i < entry.value.length; i++) ...[
                            if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator),
                            Dismissible(
                              key: ValueKey(entry.value[i].id),
                              direction: DismissDirection.endToStart,
                              onDismissed: (_) => _delete(entry.value[i]),
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
                                          Text(entry.value[i].test,
                                              style: NovaType.headline.copyWith(color: c.textPrimary)),
                                          Text(
                                            entry.value[i].rangeText.isEmpty
                                                ? entry.value[i].resultText
                                                : '${entry.value[i].resultText} · range ${entry.value[i].rangeText}',
                                            style: NovaType.footnote.copyWith(color: c.textSecondary),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    LabFlagChip(flag: entry.value[i].flag),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: NovaSpace.gap),
                Text(
                  'Tags come from the ranges printed on your reports. Swipe a row to delete it.',
                  style: NovaType.footnote.copyWith(color: c.textSecondary),
                ),
              ],
              const SizedBox(height: NovaSpace.section),
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
}
