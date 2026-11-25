import 'package:flutter/material.dart';

import '../data/outdoor_notice.dart';
import '../data/weather.dart';
import '../services/api_client.dart';
import '../services/outdoor_alerts.dart';
import 'weather_card.dart';

class OutdoorAlertsScreen extends StatefulWidget {
  const OutdoorAlertsScreen({super.key});

  @override
  State<OutdoorAlertsScreen> createState() => _OutdoorAlertsScreenState();
}

class _OutdoorAlertsScreenState extends State<OutdoorAlertsScreen> {
  final _alerts = OutdoorAlerts.instance;
  WeatherCity? _selection;
  bool _saving = false;

  Future<void> _save(String owner, WeatherCity? city) async {
    setState(() => _saving = true);
    try {
      if (!await _alerts.setCity(owner, city) && mounted) {
        final message = city == null
            ? 'Could not turn off notices. Try again.'
            : 'Could not enable notices. Check device notification permissions.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not save notice settings. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _status(OutdoorAlertCoordinator coordinator) {
    if (coordinator.permissionDenied) {
      return 'Notifications are disabled in device settings.';
    }
    final notice = coordinator.notice;
    return switch (notice?.statusAt(coordinator.clock())) {
      OutdoorNoticeStatus.eligible =>
        '${notice!.date} · Open-Meteo forecasts up to ${notice.chance}% chance of precipitation. Check conditions before going outdoors.',
      OutdoorNoticeStatus.belowThreshold =>
        '${notice!.date} · Open-Meteo forecasts up to ${notice.chance}% chance of precipitation. Below the notice threshold.',
      OutdoorNoticeStatus.stale =>
        'Forecast is stale. No notice is sent from it.',
      OutdoorNoticeStatus.missing =>
        'Today’s precipitation forecast is unknown.',
      OutdoorNoticeStatus.unavailable =>
        'Forecast or notice service unavailable. NOVA will check again while open.',
      null => 'Waiting for a forecast check.',
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Outdoor planning notices')),
        body: ListenableBuilder(
          listenable: _alerts.coordinator,
          builder: (context, _) {
            final owner = ApiClient.instance.aiAccountId;
            final current = owner == null ? null : _alerts.cityFor(owner);
            final selected = _selection ?? current;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                    'Allow NOVA to check Open-Meteo for a city you choose while the app is open. '
                    'A fresh forecast with a daily maximum precipitation chance of 60% or higher can trigger one generic notice per city date on this device. '
                    'Previews show no location or health details. These are planning notices. Check your local weather service for official warnings.'),
                const SizedBox(height: 12),
                if (current != null) ...[
                  Text('Enabled for ${current.label}'),
                  Text(_status(_alerts.coordinator)),
                  TextButton(
                    onPressed: _saving || owner == null
                        ? null
                        : () => _save(owner, null),
                    child: const Text('Turn off notices'),
                  ),
                ],
                TextButton(
                  onPressed: _saving || owner == null
                      ? null
                      : () async {
                          final choice = await chooseWeatherCity(context);
                          if (choice != null &&
                              mounted &&
                              ApiClient.instance.aiAccountId == owner) {
                            setState(() => _selection = choice);
                          }
                        },
                  child: const Text('Choose city'),
                ),
                if (selected != null && current?.id != selected.id)
                  FilledButton(
                    onPressed: _saving || owner == null
                        ? null
                        : () => _save(owner, selected),
                    child: Text('Enable notices for ${selected.label}'),
                  ),
              ],
            );
          },
        ),
      );
}
