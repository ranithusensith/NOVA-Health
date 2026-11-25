import 'package:flutter/material.dart';

import '../data/wearable_daily.dart';
import '../services/health_sync.dart' show HealthSyncException;
import '../services/wearable_daily_sync.dart';
import '../widgets/content.dart';
import 'heart_rate_screen.dart';

void openWearableActivity(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => const WearableActivityScreen(),
  ));
}

class WearableActivityScreen extends StatefulWidget {
  const WearableActivityScreen({super.key, this.sync});
  final WearableDailySync? sync;

  @override
  State<WearableActivityScreen> createState() => _WearableActivityScreenState();
}

class _WearableActivityScreenState extends State<WearableActivityScreen> {
  WearableMetric? _busy;
  final _results = <WearableMetric, String>{};

  Future<void> _import(WearableMetric metric) async {
    if (_busy != null) return;
    setState(() {
      _busy = metric;
      _results.remove(metric);
    });
    String message;
    try {
      final result =
          await (widget.sync ?? WearableDailySync.instance).import(metric);
      message = switch (result.status) {
        WearableImportStatus.unavailable =>
          'The health-data source is unavailable or could not be read.',
        WearableImportStatus.denied =>
          'Read access was denied. Review this metric in Health Connect settings.',
        WearableImportStatus.accessUnconfirmed =>
          'Apple Health did not complete the access request.',
        WearableImportStatus.empty =>
          'No readable data in the last seven local days. Check your device sync and read access.',
        WearableImportStatus.imported when result.saved == 0 =>
          'The readable totals are already saved or a newer import exists.',
        WearableImportStatus.imported =>
          '${result.saved} daily totals saved to your NOVA account.',
      };
    } on HealthSyncException catch (error) {
      message = error.message;
    } catch (_) {
      message = 'Could not verify the import. Try again.';
    }
    if (!mounted) return;
    setState(() {
      _results[metric] = message;
      _busy = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Wearable activity')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
                'Import up to seven days from Apple Health or Health Connect. '
                'NOVA saves daily totals to this account and requests read access only for the metric you choose. '
                'The source identifies the health platform. Check that platform to see which devices share data.'),
            const SizedBox(height: 16),
            for (final metric in WearableMetric.values) ...[
              NovaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(metric.label),
                    const SizedBox(height: 8),
                    NovaButton(
                      label: _busy == metric
                          ? 'Importing…'
                          : 'Import ${metric.label.toLowerCase()}',
                      onPressed: _busy == null ? () => _import(metric) : null,
                    ),
                    if (_results[metric] case final result?)
                      Semantics(liveRegion: true, child: Text(result)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            NovaButton(
              label: 'Open heart rate',
              kind: NovaButtonKind.secondary,
              onPressed: _busy == null ? () => openHeartRate(context) : null,
            ),
          ],
        ),
      );
}
