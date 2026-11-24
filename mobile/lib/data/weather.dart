import 'dart:async';

import 'package:flutter/foundation.dart';

enum WeatherStatus {
  live('Live weather'),
  stale('Stale weather'),
  unavailable('Weather unavailable'),
  demo('Demonstration weather');

  const WeatherStatus(this.label);
  final String label;
}

class WeatherCity {
  const WeatherCity(this.id, this.name, this.region, this.country);

  factory WeatherCity.fromJson(Map<String, dynamic> data) => WeatherCity(
        data['id'] as int,
        data['name'] as String,
        data['region'] as String? ?? '',
        data['country'] as String? ?? '',
      );

  final int id;
  final String name;
  final String region;
  final String country;

  String get label =>
      {name, region, country}.where((part) => part.isNotEmpty).join(', ');
}

class WeatherConditions {
  const WeatherConditions(
      {this.temperature, this.feelsLike, this.humidity, this.condition});

  factory WeatherConditions.fromJson(Map<String, dynamic> data) =>
      WeatherConditions(
        temperature: data['temperature_c'] as num?,
        feelsLike: data['feels_like_c'] as num?,
        humidity: data['humidity_pct'] as num?,
        condition: data['condition'] as String?,
      );

  final num? temperature;
  final num? feelsLike;
  final num? humidity;
  final String? condition;
}

class WeatherDay {
  const WeatherDay(this.date,
      {this.low, this.high, this.precipitation, this.condition});

  factory WeatherDay.fromJson(Map<String, dynamic> data) => WeatherDay(
        data['date'] as String,
        low: data['low_c'] as num?,
        high: data['high_c'] as num?,
        precipitation: data['precipitation_pct'] as num?,
        condition: data['condition'] as String?,
      );

  final String date;
  final num? low;
  final num? high;
  final num? precipitation;
  final String? condition;
}

class WeatherSnapshot {
  const WeatherSnapshot({
    required this.status,
    this.current,
    this.forecast = const [],
    this.observedAt,
    this.fetchedAt,
    this.freshUntil,
    this.expiresAt,
    this.wellness,
  });

  factory WeatherSnapshot.fromJson(Map<String, dynamic> data) {
    final status = switch (data['status']) {
      'live' => WeatherStatus.live,
      'stale' => WeatherStatus.stale,
      _ => WeatherStatus.unavailable,
    };
    if (status == WeatherStatus.unavailable) {
      return const WeatherSnapshot(status: WeatherStatus.unavailable);
    }
    DateTime? instant(String key) =>
        DateTime.tryParse(data[key] as String? ?? '');
    final current = data['current'];
    return WeatherSnapshot(
      status: status,
      observedAt: instant('observed_at'),
      fetchedAt: instant('fetched_at'),
      freshUntil: instant('fresh_until'),
      expiresAt: instant('expires_at'),
      current: current is Map<String, dynamic>
          ? WeatherConditions.fromJson(current)
          : null,
      forecast: (data['forecast'] as List)
          .cast<Map<String, dynamic>>()
          .map(WeatherDay.fromJson)
          .toList(),
      wellness: data['wellness'] as String?,
    );
  }

  final WeatherStatus status;
  final WeatherConditions? current;
  final List<WeatherDay> forecast;
  final DateTime? observedAt;
  final DateTime? fetchedAt;
  final DateTime? freshUntil;
  final DateTime? expiresAt;
  final String? wellness;

  WeatherStatus statusAt(DateTime now) {
    if (status == WeatherStatus.demo || status == WeatherStatus.unavailable) {
      return status;
    }
    if (expiresAt == null || !now.isBefore(expiresAt!)) {
      return WeatherStatus.unavailable;
    }
    return status == WeatherStatus.stale ||
            freshUntil == null ||
            !now.isBefore(freshUntil!)
        ? WeatherStatus.stale
        : WeatherStatus.live;
  }
}

/// In-memory city and forecast, owned by one signed-in AppShell.
class WeatherSession extends ChangeNotifier {
  WeatherSession(this._fetch, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  final Future<WeatherSnapshot> Function(int) _fetch;
  final DateTime Function() clock;
  WeatherCity? city;
  WeatherSnapshot? snapshot;
  int _request = 0;
  Timer? _ticker;
  bool loading = false;
  bool _failed = false;

  WeatherStatus get status {
    final current = snapshot?.statusAt(clock()) ?? WeatherStatus.unavailable;
    return _failed && current == WeatherStatus.live
        ? WeatherStatus.stale
        : current;
  }

  Future<void> select(WeatherCity selection) async {
    if (city?.id != selection.id) {
      city = selection;
      snapshot = null;
      _failed = false;
    }
    _ticker ??=
        Timer.periodic(const Duration(minutes: 1), (_) => notifyListeners());
    await refresh();
  }

  Future<void> refresh() async {
    final selection = city;
    if (selection == null) return;
    final request = ++_request;
    loading = true;
    notifyListeners();
    try {
      final result = await _fetch(selection.id);
      if (request != _request) return;
      _failed = result.statusAt(clock()) == WeatherStatus.unavailable;
      if (!_failed) snapshot = result;
    } catch (_) {
      if (request != _request) return;
      _failed = true;
    } finally {
      if (request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _request++;
    _ticker?.cancel();
    super.dispose();
  }
}
