import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/outdoor_notice.dart';
import 'package:nova_health/data/weather.dart';
import 'package:nova_health/services/outdoor_alerts.dart';

const _city = WeatherCity(23, 'Synthetic City', '', '');
const _other = WeatherCity(24, 'Synthetic Other City', '', '');
final _now = DateTime.utc(2026, 11, 25, 8);

Map<String, dynamic> _evidence() => {
      'status': 'eligible',
      'city_id': _city.id,
      'source': 'Open-Meteo',
      'date': '2026-11-25',
      'precipitation_pct': 60,
      'fetched_at': _now.toIso8601String(),
      'valid_until': _now.add(const Duration(minutes: 10)).toIso8601String(),
    };

class _Harness {
  String? owner = 'synthetic-owner';
  WeatherCity? consent;
  bool active = true;
  bool permission = true;
  DateTime now = _now;
  var fetches = 0;
  final delivered = <String>[];
  final claimedDates = <String, String>{};
  Future<OutdoorNotice> Function()? respond;
  Future<bool> Function()? claimOverride;

  OutdoorAlertCoordinator start() {
    final coordinator = OutdoorAlertCoordinator(
      owner: () => owner,
      cityFor: (_) => consent,
      active: () => active,
      permission: () async => permission,
      clock: () => now,
      fetch: (account, id) async {
        fetches++;
        expect(id, consent?.id);
        if (respond case final stub?) return stub();
        return OutdoorNotice.fromJson({
          ..._evidence(),
          'fetched_at': now.toIso8601String(),
          'valid_until': now.add(const Duration(minutes: 10)).toIso8601String(),
        }, _city.id);
      },
      claim: (account, date) async {
        if (claimOverride case final stub?) return stub();
        if (claimedDates[account] case final previous?
            when previous.compareTo(date) >= 0) {
          return false;
        }
        claimedDates[account] = date;
        return true;
      },
      deliver: (account, current) async {
        if (current()) delivered.add(account);
      },
    );
    addTearDown(coordinator.dispose);
    return coordinator;
  }
}

void main() {
  test('only a live, matching forecast with bounded evidence is eligible', () {
    final valid = OutdoorNotice.fromJson(_evidence(), _city.id);
    expect(valid.statusAt(_now), OutdoorNoticeStatus.eligible);
    expect(valid.statusAt(_now.add(const Duration(minutes: 10))),
        OutdoorNoticeStatus.stale);
    expect(valid.statusAt(_now.subtract(const Duration(seconds: 1))),
        OutdoorNoticeStatus.stale);
    for (final patch in [
      {'city_id': _other.id},
      {'source': 'Synthetic other source'},
      {'date': '2026-02-31'},
      {'precipitation_pct': double.nan},
      {'precipitation_pct': 59},
      {'valid_until': null},
    ]) {
      expect(
          OutdoorNotice.fromJson({..._evidence(), ...patch}, _city.id).status,
          OutdoorNoticeStatus.unavailable);
    }
  });

  test(
      'no city consent, background, signed out, or denied permission means no forecast read',
      () async {
    final fixture = _Harness();
    final coordinator = fixture.start();
    await coordinator.refresh();
    fixture.consent = _city;
    fixture.active = false;
    await coordinator.refresh();
    fixture.active = true;
    fixture.owner = null;
    await coordinator.refresh();
    fixture.owner = 'synthetic-owner';
    fixture.permission = false;
    await coordinator.refresh();
    expect(fixture.fetches, 0);
    expect(coordinator.permissionDenied, isTrue);
    expect(fixture.delivered, isEmpty);
  });

  test('parallel checks and a restart still deliver only once for a date',
      () async {
    final fixture = _Harness()..consent = _city;
    final coordinator = fixture.start();
    await Future.wait([coordinator.refresh(), coordinator.refresh()]);
    expect(fixture.fetches, 1);
    await fixture.start().refresh();
    expect(fixture.fetches, 2);
    expect(fixture.delivered, ['synthetic-owner']);
  });

  test(
      'failed, missing and stale forecasts do not claim a date and can recover',
      () async {
    final fixture = _Harness()
      ..consent = _city
      ..respond = () async => throw StateError('Synthetic network failure');
    final coordinator = fixture.start();
    await coordinator.refresh();
    expect(coordinator.notice?.status, OutdoorNoticeStatus.unavailable);
    for (final status in [
      OutdoorNoticeStatus.missing,
      OutdoorNoticeStatus.stale
    ]) {
      fixture.now = fixture.now.add(const Duration(minutes: 30));
      fixture.respond = () async => OutdoorNotice(status);
      await coordinator.refresh();
      expect(coordinator.notice?.status, status);
    }
    expect(fixture.claimedDates, isEmpty);
    fixture.respond = null;
    fixture.now = fixture.now.add(const Duration(minutes: 30));
    await coordinator.refresh();
    expect(fixture.delivered, ['synthetic-owner']);
  });

  test(
      'revocation, city change and A-B-A account switches fence a late response',
      () async {
    final pending = Completer<OutdoorNotice>();
    final fixture = _Harness()
      ..consent = _city
      ..respond = () => pending.future;
    final coordinator = fixture.start();
    final inFlight = coordinator.refresh();
    await Future<void>.delayed(Duration.zero);
    fixture.consent = null;
    coordinator.invalidate();
    fixture.owner = 'synthetic-other';
    coordinator.invalidate();
    fixture.owner = 'synthetic-owner';
    fixture.consent = _other;
    coordinator.invalidate();
    pending.complete(OutdoorNotice.fromJson(_evidence(), _city.id));
    await inFlight;
    expect(fixture.claimedDates, isEmpty);
    expect(fixture.delivered, isEmpty);
    expect(coordinator.notice, isNull);
  });

  test('a forecast that expires during a claim cannot display', () async {
    final claim = Completer<bool>();
    final fixture = _Harness()
      ..consent = _city
      ..claimOverride = () => claim.future;
    final coordinator = fixture.start();
    final inFlight = coordinator.refresh();
    await Future<void>.delayed(Duration.zero);
    fixture.now = _now.add(const Duration(minutes: 10));
    claim.complete(true);
    await inFlight;
    expect(fixture.delivered, isEmpty);
  });
}
