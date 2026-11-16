import 'dart:io' show Platform;

import 'package:health/health.dart';

import '../data/profile_models.dart';
import '../data/profile_repository.dart';

class HealthSyncException implements Exception {
  HealthSyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

class SyncResult {
  const SyncResult({required this.found, required this.imported});

  /// Readings found in the health app (after thinning).
  final int found;

  /// Readings sent to NOVA (duplicates are ignored by the database).
  final int imported;
}

/// Reads heart rate from Apple Health (iPhone, including Apple Watch data) or
/// Health Connect (Android: Samsung Galaxy Watch, Fitbit, Garmin and others
/// that share data with Health Connect). Read only; NOVA never writes to it.
class HeartSync {
  HeartSync._();
  static final HeartSync instance = HeartSync._();

  final Health _health = Health();
  bool _configured = false;

  bool get supported => Platform.isIOS || Platform.isAndroid;
  String get sourceName => Platform.isIOS ? 'Apple Health' : 'Health Connect';
  String get device => Platform.isIOS ? 'apple_health' : 'health_connect';

  Future<SyncResult> importRecent({int days = 7}) async {
    if (!supported) {
      throw HealthSyncException('Heart rate sync works on iPhone and Android phones.');
    }

    const types = [HealthDataType.HEART_RATE];
    try {
      if (!_configured) {
        await _health.configure();
        _configured = true;
      }

      final granted = await _health.requestAuthorization(types, permissions: [HealthDataAccess.READ]);
      if (!granted) {
        throw HealthSyncException(
          'Heart rate access was not allowed. Allow it for NOVA Health in $sourceName and try again.',
        );
      }

      final now = DateTime.now();
      final points = await _health.getHealthDataFromTypes(
        types: types,
        startTime: now.subtract(Duration(days: days)),
        endTime: now,
      );

      // Watches record every few minutes. Keep one reading per 10 minutes, oldest first.
      points.sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
      final samples = <HeartSample>[];
      DateTime? lastKept;
      for (final p in points) {
        final value = p.value;
        if (value is! NumericHealthValue) continue;
        final bpm = value.numericValue.round();
        if (bpm < 20 || bpm > 250) continue; // not a believable heart rate
        if (lastKept != null && p.dateFrom.difference(lastKept).inMinutes < 10) continue;
        lastKept = p.dateFrom;
        samples.add(HeartSample(bpm: bpm, at: p.dateFrom));
      }
      // Keep the newest 1000 so one sync stays small.
      final recent = samples.length > 1000 ? samples.sublist(samples.length - 1000) : samples;

      final imported = await ProfileRepository.instance.importHeartSamples(recent, device: device);
      return SyncResult(found: recent.length, imported: imported);
    } on HealthSyncException {
      rethrow;
    } catch (e) {
      throw HealthSyncException(
        Platform.isAndroid
            ? 'Could not reach Health Connect. Make sure it is installed and up to date, then try again.'
            : 'Could not read Apple Health. Unlock the phone and allow Heart Rate for NOVA Health, then try again.',
      );
    }
  }
}
