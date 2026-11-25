import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/weather.dart';
import '../services/api_client.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';

class WeatherCredit extends StatelessWidget {
  const WeatherCredit({super.key, this.geocoding = false});

  final bool geocoding;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: () => launchUrl(
          Uri.parse(geocoding
              ? 'https://www.geonames.org/'
              : 'https://open-meteo.com/'),
          mode: LaunchMode.externalApplication,
        ),
        child:
            Text(geocoding ? 'City data by GeoNames' : 'Weather by Open-Meteo'),
      );
}

Future<WeatherCity?> chooseWeatherCity(BuildContext context,
    {Future<List<WeatherCity>> Function(String)? search}) =>
    showDialog<WeatherCity>(
      context: context,
      builder: (_) => _CityPicker(search: search ?? ApiClient.instance.searchWeatherCities),
    );

class WeatherCard extends StatelessWidget {
  const WeatherCard({super.key, required this.session, this.search});

  final WeatherSession session;
  final Future<List<WeatherCity>> Function(String)? search;

  Future<void> _choose(BuildContext context) async {
    final city = await chooseWeatherCity(context, search: search);
    if (city != null && context.mounted) await session.select(city);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final city = session.city;
          final snapshot = session.snapshot;
          final status = session.status;
          return NovaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const IconBadge(icon: Icons.cloud_outlined, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text('Weather',
                          style: NovaType.headline
                              .copyWith(color: context.nova.textPrimary))),
                  if (city != null)
                    IconButton(
                      tooltip: 'Refresh weather',
                      onPressed: session.loading ? null : session.refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                ]),
                if (city == null)
                  const Text('Choose a city to see its weather.')
                else ...[
                  const SizedBox(height: 6),
                  Text(city.label),
                  if (session.loading && snapshot == null)
                    const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator())
                  else if (snapshot != null &&
                      status != WeatherStatus.unavailable)
                    WeatherDetails(snapshot: snapshot, status: status)
                  else
                    const Text('Weather unavailable. Try refreshing.'),
                ],
                TextButton(
                  onPressed: () => _choose(context),
                  child: Text(city == null ? 'Choose city' : 'Change city'),
                ),
              ],
            ),
          );
        },
      );
}

class WeatherDetails extends StatelessWidget {
  const WeatherDetails(
      {super.key, required this.snapshot, required this.status});

  final WeatherSnapshot snapshot;
  final WeatherStatus status;

  String _degrees(num? value) =>
      value == null ? 'Unknown' : '${value.toStringAsFixed(1)} °C';

  @override
  Widget build(BuildContext context) {
    final conditions = snapshot.current;
    final observed = snapshot.observedAt;
    final fetched = snapshot.fetchedAt;
    final locale = MaterialLocalizations.of(context);

    String stamp(DateTime value) =>
        '${locale.formatCompactDate(value.toLocal())} '
        '${locale.formatTimeOfDay(TimeOfDay.fromDateTime(value.toLocal()))}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status.label,
            style: NovaType.headline.copyWith(color: context.nova.textPrimary)),
        if (status == WeatherStatus.stale)
          const Text(
              'Showing a previous forecast. Refresh before relying on it.'),
        if (conditions == null)
          const Text('Current conditions unknown')
        else ...[
          Text(
              '${conditions.condition ?? 'Conditions unknown'} · ${_degrees(conditions.temperature)}'),
          Text('Feels like ${_degrees(conditions.feelsLike)}'),
          Text(
              'Humidity ${conditions.humidity == null ? 'unknown' : '${conditions.humidity}%'}'),
          if (observed != null)
            Text('Model conditions at ${stamp(observed)} (device time)'),
        ],
        if (fetched != null) Text('Retrieved ${stamp(fetched)}'),
        if (snapshot.forecast.isEmpty)
          const Text('Forecast unavailable')
        else ...[
          const SizedBox(height: 8),
          const Text('Forecast by city date'),
          for (final day in snapshot.forecast)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  '${day.date} · ${day.condition ?? 'Conditions unknown'}\n'
                  'Low ${_degrees(day.low)} · High ${_degrees(day.high)} · '
                  'Precipitation chance ${day.precipitation == null ? 'unknown' : 'up to ${day.precipitation}%'}'),
            ),
        ],
        if (status == WeatherStatus.live && snapshot.wellness != null) ...[
          const SizedBox(height: 8),
          Text(snapshot.wellness!),
        ],
        if (status != WeatherStatus.demo) const WeatherCredit(),
      ],
    );
  }
}

class _CityPicker extends StatefulWidget {
  const _CityPicker({required this.search});
  final Future<List<WeatherCity>> Function(String) search;

  @override
  State<_CityPicker> createState() => _CityPickerState();
}

class _CityPickerState extends State<_CityPicker> {
  final _input = TextEditingController();
  List<WeatherCity> _results = const [];
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_busy) return;
    final query = _input.text.trim();
    if (query.length < 2) {
      setState(() => _message = 'Enter a city name.');
      return;
    }
    setState(() {
      _busy = true;
      _results = const [];
      _message = null;
    });
    try {
      final cities = await widget.search(query);
      if (!mounted) return;
      setState(() {
        _results = cities;
        if (cities.isEmpty) {
          _message = 'No cities found. Try adding a region or country.';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = error is ApiException
            ? error.message
            : 'City search unavailable. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Choose a weather city'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'NOVA sends this search to Open-Meteo. Enter just a city and optional region or country.'),
            TextField(
              controller: _input,
              maxLength: 80,
              readOnly: _busy,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(labelText: 'City name'),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_message != null) Text(_message!),
            for (final city in _results)
              ListTile(
                  title: Text(city.label),
                  onTap: () => Navigator.pop(context, city)),
            const WeatherCredit(geocoding: true),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _busy ? null : _search, child: const Text('Search')),
        ],
      );
}
