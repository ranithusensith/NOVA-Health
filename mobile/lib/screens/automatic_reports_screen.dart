import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/automatic_report_notices.dart';

void openAutomaticReports(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AutomaticReportsScreen()),
    );

class AutomaticReportsScreen extends StatefulWidget {
  const AutomaticReportsScreen({super.key, this.api, this.deviceZone});

  final ApiClient? api;
  final Future<String?> Function()? deviceZone;

  @override
  State<AutomaticReportsScreen> createState() => _AutomaticReportsScreenState();
}

class _AutomaticReportsScreenState extends State<AutomaticReportsScreen> {
  ApiClient get _api => widget.api ?? ApiClient.instance;
  final _notices = AutomaticReportNotices.instance;
  late Future<Map<String, dynamic>> _settings = _api.automaticReports();
  bool _saving = false;

  void _reload() {
    final settings = _api.automaticReports();
    setState(() {
      _settings = settings;
    });
  }

  void _feedback(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _changeSchedule(bool enabled) async {
    final owner = _api.aiAccountId;
    if (owner == null || _saving) return;
    if (!enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Turn off automatic reports?'),
          content: const Text(
              'This deletes saved automatic reports. Your original logs are kept.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Turn off')),
          ],
        ),
      );
      if (confirmed != true || !mounted || _api.aiAccountId != owner) return;
    }
    setState(() => _saving = true);
    try {
      final zone = enabled
          ? await (widget.deviceZone ?? AutomaticReportNotices.deviceTimeZone)()
          : null;
      if (!mounted || _api.aiAccountId != owner) return;
      if (enabled && (zone == null || zone.isEmpty)) {
        _feedback('Could not read this device’s time zone.');
        return;
      }
      await _api.setAutomaticReports(owner, enabled: enabled, timeZone: zone);
      if (!mounted || _api.aiAccountId != owner) return;
      _reload();
      if (!enabled) await _notices.setEnabled(owner, false);
    } on ApiException catch (error) {
      if (mounted) _feedback(error.message);
    } catch (_) {
      if (mounted) {
        _feedback('Could not update the schedule. Refresh to verify it.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeNotices(bool enabled) async {
    final owner = _api.aiAccountId;
    if (owner == null || _saving) return;
    setState(() => _saving = true);
    try {
      final accepted = await _notices.setEnabled(owner, enabled);
      if (mounted && enabled && !accepted) {
        _feedback('Allow notifications in device settings.');
      }
    } catch (_) {
      if (mounted) _feedback('Could not update notification settings.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _openReport(String date, String zone) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _SavedReport(date: date, zone: zone, api: _api),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Automatic daily reports'),
          actions: [
            IconButton(
                onPressed: _saving ? null : _reload,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh')
          ],
        ),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _settings,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Center(
                  child: TextButton(
                      onPressed: _reload,
                      child: const Text('Reports unavailable. Retry')));
            }
            final zone = snapshot.data!['time_zone'] as String?;
            final reports = (snapshot.data!['reports'] as List? ?? const [])
                .whereType<Map<String, dynamic>>();
            final account = _api.aiAccountId;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'NOVA generates a report for each completed local day after 8:00 a.m. '
                  'Reports stay in your account for 30 days and can generate while you are signed out. '
                  'Generation uses your saved records and goals within NOVA.',
                ),
                SwitchListTile(
                  title: const Text('Generate daily reports'),
                  value: zone != null,
                  onChanged:
                      account == null || _saving ? null : _changeSchedule,
                ),
                if (zone != null) ...[
                  ListTile(
                    title: const Text('Report time zone'),
                    subtitle: Text(zone),
                    trailing: TextButton(
                      onPressed: _saving ? null : () => _changeSchedule(true),
                      child: const Text('Use device zone'),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Private alerts on this device'),
                    subtitle: const Text(
                        'Checked while NOVA is open and signed in. Alerts show no health details.'),
                    value: account != null && _notices.enabled(account),
                    onChanged:
                        account == null || _saving ? null : _changeNotices,
                  ),
                  const Divider(),
                  if (reports.isEmpty)
                    const ListTile(
                        title: Text('No automatic reports saved yet.')),
                  for (final report in reports)
                    if (report['local_date'] is String &&
                        report['time_zone'] is String)
                      ListTile(
                        title: Text(report['local_date'] as String),
                        subtitle: Text(report['time_zone'] as String),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openReport(report['local_date'] as String,
                            report['time_zone'] as String),
                      ),
                ],
              ],
            );
          },
        ),
      );
}

class _SavedReport extends StatefulWidget {
  const _SavedReport(
      {required this.date, required this.zone, required this.api});

  final String date;
  final String zone;
  final ApiClient api;

  @override
  State<_SavedReport> createState() => _SavedReportState();
}

class _SavedReportState extends State<_SavedReport> {
  late Future<String> _summary = widget.api.savedAutomaticReport(widget.date);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.date)),
        body: FutureBuilder<String>(
          future: _summary,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!snapshot.hasData) {
              return Center(
                  child: TextButton(
                onPressed: () {
                  final summary = widget.api.savedAutomaticReport(widget.date);
                  setState(() {
                    _summary = summary;
                  });
                },
                child: const Text('Saved report unavailable. Retry'),
              ));
            }
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(widget.zone),
                const SizedBox(height: 12),
                Text(snapshot.data!),
              ],
            );
          },
        ),
      );
}
