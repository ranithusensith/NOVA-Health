import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/weather.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/ai_privacy_screen.dart';
import 'package:nova_health/screens/weather_card.dart';
import 'package:nova_health/services/api_client.dart';

const _city =
    WeatherCity(42, 'Synthetic City', 'Synthetic Region', 'Synthetic Country');
const _other = WeatherCity(43, 'Other Synthetic City', '', '');
final _now = DateTime.utc(2026, 11, 25, 6);

WeatherSnapshot _forecast() => WeatherSnapshot(
      status: WeatherStatus.live,
      current: const WeatherConditions(temperature: 30.5, condition: 'Rain'),
      forecast: const [WeatherDay('2026-11-25', high: 31, precipitation: 60)],
      observedAt: _now,
      fetchedAt: _now,
      freshUntil: _now.add(const Duration(minutes: 15)),
      expiresAt: _now.add(const Duration(hours: 3)),
      wellness: 'Synthetic outdoor planning information.',
    );

void main() {
  test('missing fields are unknown and demo cannot arrive through the live API',
      () {
    final data = WeatherSnapshot.fromJson({
      'status': 'live',
      'fetched_at': _now.toIso8601String(),
      'fresh_until': _now.add(const Duration(minutes: 15)).toIso8601String(),
      'expires_at': _now.add(const Duration(hours: 3)).toIso8601String(),
      'current': {'temperature_c': 0},
      'forecast': [
        {'date': '2026-11-25', 'precipitation_pct': 0}
      ],
    });
    expect(data.current?.temperature, 0);
    expect(data.current?.humidity, isNull);
    expect(data.forecast.single.precipitation, 0);
    expect(data.forecast.single.low, isNull);
    expect(data.statusAt(_now), WeatherStatus.live);
    expect(data.statusAt(_now.add(const Duration(minutes: 15))),
        WeatherStatus.stale);
    expect(data.statusAt(_now.add(const Duration(hours: 3))),
        WeatherStatus.unavailable);
    expect(WeatherSnapshot.fromJson({'status': 'demo'}).status,
        WeatherStatus.unavailable);
    expect(
        AssistantReply.fromJson({
          'sources': ['weather']
        }).sources,
        ['Open-Meteo weather']);
  });

  test(
      'late requests cannot replace the selected city or update disposed sessions',
      () async {
    final first = Completer<WeatherSnapshot>();
    final second = Completer<WeatherSnapshot>();
    final session = WeatherSession(
        (id) => id == _city.id ? first.future : second.future,
        clock: () => _now);
    final firstLoad = session.select(_city);
    final secondLoad = session.select(_other);
    first.complete(_forecast());
    await firstLoad;
    expect(session.city, _other);
    expect(session.snapshot, isNull);
    session.dispose();
    second.complete(_forecast());
    await secondLoad;
    expect(session.snapshot, isNull);
  });

  testWidgets(
      'city search displays empty results then live, stale and unavailable weather',
      (tester) async {
    var now = _now;
    var outage = false;
    final session = WeatherSession((id) async {
      expect(id, _city.id);
      if (outage) throw StateError('Synthetic outage');
      return _forecast();
    }, clock: () => now);
    await tester.pumpWidget(NovaApp(
        home: Scaffold(
      body: WeatherCard(
          session: session,
          search: (query) async => query == 'Synthetic City' ? [_city] : []),
    )));
    await tester.tap(find.text('Choose city'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Synthetic missing');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No cities found'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Synthetic City');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_city.label));
    await tester.pumpAndSettle();
    expect(find.text('Live weather'), findsOneWidget);
    expect(find.text('Rain · 30.5 °C'), findsOneWidget);
    expect(find.text('Humidity unknown'), findsOneWidget);
    expect(find.textContaining('up to 60%'), findsOneWidget);
    expect(find.text('Weather by Open-Meteo'), findsOneWidget);

    outage = true;
    await tester.tap(find.byTooltip('Refresh weather'));
    await tester.pumpAndSettle();
    expect(find.text('Stale weather'), findsOneWidget);
    expect(find.text('Synthetic outdoor planning information.'), findsNothing);
    now = _now.add(const Duration(hours: 3));
    await tester.pump(const Duration(minutes: 1));
    expect(find.textContaining('Weather unavailable'), findsOneWidget);
    expect(find.text('Rain · 30.5 °C'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('weather sharing is unchecked for each reply', (tester) async {
    AiChatShare? selection;
    await tester.pumpWidget(NovaApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => TextButton(
        child: const Text('Review'),
        onPressed: () async => selection = await showDialog<AiChatShare>(
            context: context,
            builder: (_) => const AiChatReview(weatherCity: _city)),
      ),
    ))));

    Future<void> open() async {
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
    }

    await open();
    final option = find.widgetWithText(
        CheckboxListTile, 'Include weather for ${_city.label} in this reply');
    expect(tester.widget<CheckboxListTile>(option).value, isFalse);
    await tester.tap(find.text('Share question'));
    await tester.pumpAndSettle();
    expect(selection?.weatherCityId, isNull);

    await open();
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(option).value, isTrue);
    await tester.tap(find.text('Share question'));
    await tester.pumpAndSettle();
    expect(selection?.weatherCityId, _city.id);

    await open();
    expect(tester.widget<CheckboxListTile>(option).value, isFalse);
  });

  testWidgets('demonstration data is labelled and carries no live attribution',
      (tester) async {
    await tester.pumpWidget(const NovaApp(
        home: Scaffold(
            body: WeatherDetails(
      status: WeatherStatus.demo,
      snapshot: WeatherSnapshot(
          status: WeatherStatus.demo,
          current: WeatherConditions(temperature: 27)),
    ))));
    expect(find.text('Demonstration weather'), findsOneWidget);
    expect(find.text('Weather by Open-Meteo'), findsNothing);
  });
}
