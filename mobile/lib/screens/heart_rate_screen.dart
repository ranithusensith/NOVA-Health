import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/care_models.dart';
import '../data/profile_models.dart';
import '../data/profile_repository.dart';
import '../services/health_sync.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/states.dart';

String _lastSyncKey(String accountId) => 'heart.lastSync.$accountId';

void openHeartRate(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HeartRateScreen()));
}

/// Heart rate: add a reading by hand, see the 7-day trend, and import readings
/// from Apple Health (Apple Watch) or Health Connect (Samsung and other watches).
class HeartRateScreen extends StatefulWidget {
  const HeartRateScreen({super.key});

  @override
  State<HeartRateScreen> createState() => _HeartRateScreenState();
}

class _HeartRateScreenState extends State<HeartRateScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  List<HeartReading>? _readings;
  String? _error;
  bool _syncing = false;
  String? _syncMessage;
  DateTime? _lastSync;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _pulse
        ..stop()
        ..value = 0.5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repository = ProfileRepository.instance;
      final accountId = repository.currentAccountId;
      if (accountId == null) throw HealthSyncException('Sign in to view your heart rate readings.');
      final readings = await repository.heartReadings(days: 7);
      final prefs = await SharedPreferences.getInstance();
      final last = DateTime.tryParse(prefs.getString(_lastSyncKey(accountId)) ?? '');
      if (!mounted || repository.currentAccountId != accountId) return;
      setState(() {
        _readings = readings;
        _lastSync = last?.toLocal();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    final repository = ProfileRepository.instance;
    final sync = HeartSync.instance;
    String? accountId;
    String message;
    try {
      accountId = repository.currentAccountId;
      final result = await sync.importRecent();
      if (result.found == 0) {
        message = 'No readable heart rate samples were found in the last 7 days. Check that '
            '${sync.sourceName} has readings and that NOVA Health has Heart Rate access.';
      } else {
        if (accountId != null && repository.currentAccountId == accountId) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_lastSyncKey(accountId), DateTime.now().toUtc().toIso8601String());
        }
        message = result.imported == 0
            ? 'These readings are already saved in NOVA Health.'
            : 'Imported ${result.imported} ${result.imported == 1 ? 'reading' : 'readings'} from ${sync.sourceName}.';
        await _load();
      }
    } on HealthSyncException catch (e) {
      message = e.message;
    } catch (e) {
      message = friendlyError(e);
    }
    if (mounted) {
      setState(() {
        _syncing = false;
        _syncMessage = accountId == null || repository.currentAccountId == accountId ? message : null;
      });
    }
  }

  Future<void> _addReading() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddReadingSheet(),
    );
    if (saved == true) {
      if (mounted) showNovaToast(context, 'Heart rate saved');
      await _load();
    }
  }

  Future<void> _delete(HeartReading r) async {
    setState(() => _readings = [for (final x in _readings ?? <HeartReading>[]) if (x.id != r.id) x]);
    try {
      await ProfileRepository.instance.deleteHeartReading(r.id);
    } catch (e) {
      if (mounted) {
        showNovaToast(context, friendlyError(e));
        _load();
      }
    }
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return formatDate(t);
  }

  static String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final readings = _readings;

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 40),
            children: [
              Row(
                children: [
                  ScaleTransition(
                    scale: Tween<double>(begin: 0.9, end: 1.1)
                        .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
                    child: Icon(CupertinoIcons.heart_fill, size: 34, color: c.sos),
                  ),
                  const SizedBox(width: 10),
                  Semantics(
                    header: true,
                    child: Text('Heart rate', style: NovaType.largeTitle.copyWith(color: c.textPrimary)),
                  ),
                ],
              ),
              const SizedBox(height: NovaSpace.gap),
              if (_error != null)
                ErrorCard(message: _error!, onRetry: _load)
              else if (readings == null)
                const SkeletonCard(lines: 4)
              else ...[
                _latestCard(c, readings),
                if (readings.isNotEmpty) ...[
                  const SizedBox(height: NovaSpace.gap),
                  _trendCard(c, readings),
                ],
                const SizedBox(height: NovaSpace.gap),
                NovaButton(label: 'Add a reading', icon: CupertinoIcons.add, onPressed: _addReading),
                const SectionLabel('Health platform import'),
                _importCard(c),
                if (readings.isNotEmpty) ...[
                  const SectionLabel('Last 7 days'),
                  _historyList(c, readings),
                ],
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

  // ------------------------------------------------------------------ cards
  Widget _latestCard(NovaColors c, List<HeartReading> readings) {
    if (readings.isEmpty) {
      return EmptyStateCard(
        icon: CupertinoIcons.heart,
        title: 'No heart rate yet',
        body: 'Add a reading by hand or import from a supported health platform.',
        actionLabel: 'Add a reading',
        onAction: _addReading,
      );
    }
    final latest = readings.first;
    final note = heartNote(latest.bpm, latest.context);
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Latest', style: NovaType.subhead.copyWith(color: c.textSecondary)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Semantics(
                label: '${latest.bpm} beats per minute',
                child: Text('${latest.bpm}', style: NovaType.number(56).copyWith(color: c.textPrimary)),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('bpm', style: NovaType.headline.copyWith(color: c.textSecondary)),
              ),
            ],
          ),
          Text(
            '${latest.contextLabel} · ${_ago(latest.at)} · ${latest.sourceLabel}',
            style: NovaType.subhead.copyWith(color: c.textSecondary),
          ),
          if (note != null) ...[
            const SizedBox(height: 10),
            Text(note, style: NovaType.footnote.copyWith(color: c.textPrimary)),
          ],
        ],
      ),
    );
  }

  Widget _trendCard(NovaColors c, List<HeartReading> readings) {
    final today = dayOf(DateTime.now());
    final days = [for (var i = 6; i >= 0; i--) calendarDay(today, -i)];
    final values = <double?>[];
    for (final day in days) {
      final list = [for (final r in readings) if (dayOf(r.at) == day) r.bpm];
      values.add(list.isEmpty ? null : list.reduce((a, b) => a + b) / list.length);
    }
    final all = [for (final r in readings) r.bpm];
    final avg = (all.reduce((a, b) => a + b) / all.length).round();
    final low = all.reduce((a, b) => a < b ? a : b);
    final high = all.reduce((a, b) => a > b ? a : b);

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('7-day trend', style: NovaType.headline.copyWith(color: c.textPrimary)),
          const SizedBox(height: 4),
          Text('Average $avg · Lowest $low · Highest $high bpm',
              style: NovaType.subhead.copyWith(color: c.textSecondary)),
          const SizedBox(height: 14),
          Semantics(
            label: 'Daily average heart rate for the last 7 days. Average $avg, lowest $low, highest $high beats per minute.',
            child: ExcludeSemantics(
              child: SizedBox(
                height: 110,
                width: double.infinity,
                child: CustomPaint(
                  painter: _TrendPainter(values: values, color: c.sos, grid: c.separator),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final d in days)
                Text(weekdayShort(d), style: NovaType.caption.copyWith(color: c.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _importCard(NovaColors c) {
    final sync = HeartSync.instance;
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(icon: ios ? Icons.watch_outlined : Icons.monitor_heart_outlined, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sync.supported ? sync.sourceName : 'Health app',
                        style: NovaType.headline.copyWith(color: c.textPrimary)),
                    Text(
                      _lastSync == null ? 'No prior import shown' : 'Last import ${_ago(_lastSync!)}',
                      style: NovaType.subhead.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            !sync.supported
                ? 'Heart rate import is available on supported iOS and Android devices. You can still add a reading by hand.'
                : 'Import heart-rate readings shared with ${sync.sourceName}. NOVA requests read access. '
                    'Check the health platform to see which devices share data.',
            style: NovaType.footnote.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 12),
          NovaButton(
            label: _syncing ? 'Importing…' : 'Import heart rate',
            kind: NovaButtonKind.secondary,
            icon: CupertinoIcons.arrow_2_circlepath,
            onPressed: (_syncing || !sync.supported) ? null : _sync,
          ),
          if (_syncMessage != null) ...[
            const SizedBox(height: 10),
            Text(_syncMessage!, style: NovaType.footnote.copyWith(color: c.textPrimary)),
          ],
        ],
      ),
    );
  }

  Widget _historyList(NovaColors c, List<HeartReading> readings) {
    final shown = readings.take(30).toList();
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
                      Icon(CupertinoIcons.heart_fill, size: 16, color: c.sos),
                      const SizedBox(width: 10),
                      Text('${shown[i].bpm} bpm', style: NovaType.headline.copyWith(color: c.textPrimary)),
                      const Spacer(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${formatDate(shown[i].at)}, ${_time(shown[i].at)}',
                              style: NovaType.footnote.copyWith(color: c.textSecondary)),
                          Text('${shown[i].contextLabel} · ${shown[i].sourceLabel}',
                              style: NovaType.caption.copyWith(color: c.textSecondary)),
                        ],
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
class _AddReadingSheet extends StatefulWidget {
  const _AddReadingSheet();

  @override
  State<_AddReadingSheet> createState() => _AddReadingSheetState();
}

class _AddReadingSheetState extends State<_AddReadingSheet> {
  final _bpm = TextEditingController();
  String _context = 'resting';
  String? _error;
  bool _saving = false;

  static const _contexts = {'resting': 'Resting', 'active': 'After activity', 'sleeping': 'Sleeping'};

  @override
  void dispose() {
    _bpm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final bpm = int.tryParse(_bpm.text.trim());
    if (bpm == null || bpm < 20 || bpm > 250) {
      setState(() => _error = 'Enter a heart rate between 20 and 250 bpm.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ProfileRepository.instance.addHeartRate(bpm: bpm, context: _context);
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
              Text('Add heart rate', style: NovaType.title2.copyWith(color: c.textPrimary)),
              const SizedBox(height: 4),
              Text('Count your pulse for 30 seconds and double it, or use a watch or finger sensor.',
                  style: NovaType.subhead.copyWith(color: c.textSecondary)),
              const SizedBox(height: 16),
              TextField(
                controller: _bpm,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                style: NovaType.body.copyWith(color: c.textPrimary),
                decoration: novaFieldDecoration(c, 'Beats per minute', icon: CupertinoIcons.heart),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _contexts.entries)
                    Pressable(
                      onTap: () => setState(() => _context = e.key),
                      semanticLabel: e.value,
                      selected: _context == e.key,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: _context == e.key ? c.primaryTint : c.fill,
                          borderRadius: BorderRadius.circular(NovaRadius.capsule),
                          border: Border.all(
                            color: _context == e.key ? c.primary : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Text(
                          e.value,
                          style: NovaType.subhead.copyWith(
                            color: _context == e.key ? c.primary : c.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: NovaType.footnote.copyWith(color: c.alert)),
              ],
              const SizedBox(height: 16),
              NovaButton(label: _saving ? 'Saving…' : 'Save', onPressed: _saving ? null : _save),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------- chart
class _TrendPainter extends CustomPainter {
  _TrendPainter({required this.values, required this.color, required this.grid});

  final List<double?> values; // one per day; null = no data
  final Color color;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final present = [for (final v in values) if (v != null) v];
    if (present.isEmpty) return;

    var lo = present.reduce((a, b) => a < b ? a : b) - 10;
    var hi = present.reduce((a, b) => a > b ? a : b) + 10;
    if (hi - lo < 30) {
      final mid = (hi + lo) / 2;
      lo = mid - 15;
      hi = mid + 15;
    }

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final step = values.length > 1 ? size.width / (values.length - 1) : 0.0;
    Offset pointFor(int i, double v) =>
        Offset(i * step, size.height - ((v - lo) / (hi - lo)) * size.height);

    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path? path;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final p = pointFor(i, v);
      if (path == null) {
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    if (path != null) canvas.drawPath(path, line);

    final dot = Paint()..color = color;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v != null) canvas.drawCircle(pointFor(i, v), 4, dot);
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.values != values || old.color != color || old.grid != grid;
}
