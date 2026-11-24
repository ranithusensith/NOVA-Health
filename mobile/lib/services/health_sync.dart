import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  /// Readable samples found after filtering and thinning.
  final int found;

  /// New readings saved to NOVA. Existing readings are ignored by the database.
  final int imported;
}

/// Imports heart rate from Apple Health or Health Connect when the user asks.
class HeartSync {
  HeartSync({
    Health? health,
    ProfileRepository? repository,
    TargetPlatform? platform,
    DateTime Function()? now,
  })  : _health = health ?? Health(),
        _repository = repository ?? ProfileRepository.instance,
        _platform = platform ?? defaultTargetPlatform,
        _now = now ?? DateTime.now;

  static final HeartSync instance = HeartSync();
  static const _healthKit = MethodChannel('nova_health/healthkit');
  static const _healthConnect = MethodChannel('nova_health/health_connect');
  static const _types = [HealthDataType.HEART_RATE];
  static const _access = [HealthDataAccess.READ];

  final Health _health;
  final ProfileRepository _repository;
  final TargetPlatform _platform;
  final DateTime Function() _now;
  bool _configured = false;

  bool get _isAppleHealth => _platform == TargetPlatform.iOS;
  bool get supported =>
      !kIsWeb && (_isAppleHealth || _platform == TargetPlatform.android);
  String get sourceName => _isAppleHealth ? 'Apple Health' : 'Health Connect';
  String get _device => _isAppleHealth ? 'apple_health' : 'health_connect';

  Future<SyncResult> importRecent({int days = 7}) async {
    if (!supported) {
      throw HealthSyncException(
          'Heart rate import is available on supported iOS and Android devices. You can still add a reading by hand.');
    }
    final accountId = _repository.currentAccountId;
    if (accountId == null) {
      throw HealthSyncException(
          'Sign in to NOVA Health before importing readings.');
    }

    final end = _now();
    final start = end.subtract(Duration(days: days));
    final points = await _read(start, end, accountId);
    _requireSameAccount(accountId);
    final samples = _selectSamples(points, start, end);
    if (samples.isEmpty) return const SyncResult(found: 0, imported: 0);

    final int imported;
    try {
      imported = await _repository.importHeartSamples(samples,
          device: _device, accountId: accountId);
    } catch (_) {
      _requireSameAccount(accountId);
      throw HealthSyncException(
          'Could not finish saving readings to your NOVA account. Check your saved readings before trying again.');
    }
    _requireSameAccount(accountId);
    return SyncResult(found: samples.length, imported: imported);
  }

  Future<List<HeartSample>> _read(
      DateTime start, DateTime end, String accountId) async {
    try {
      final available = _isAppleHealth
          ? await _healthKit.invokeMethod<bool>('isHealthDataAvailable') == true
          : await _health.isHealthConnectAvailable();
      if (!available) {
        throw HealthSyncException(
            '$sourceName is unavailable on this device. You can still add a reading by hand.');
      }
      if (!_configured) {
        await _health.configure();
        _configured = true;
      }
      _requireSameAccount(accountId);

      // HealthKit does not disclose read permission. Its authorization result
      // only confirms the request completed. The query may still return no data.
      final alreadyAllowed = !_isAppleHealth &&
          await _health.hasPermissions(_types, permissions: _access) == true;
      if (!alreadyAllowed &&
          !await _health.requestAuthorization(_types, permissions: _access)) {
        throw HealthSyncException(_isAppleHealth
            ? 'Could not complete the Apple Health access request. Unlock your device and check NOVA Health’s Heart Rate access in the Health app.'
            : 'Heart rate access was not allowed. Allow it for NOVA Health in Health Connect and try again.');
      }
      _requireSameAccount(accountId);
      if (!_isAppleHealth) {
        final rows =
            await _healthConnect.invokeListMethod<Map>('readHeartRate', {
          'start': start.millisecondsSinceEpoch,
          'end': end.millisecondsSinceEpoch,
        });
        if (rows == null) {
          throw const FormatException('Missing heart rate data.');
        }
        return [
          for (final row in rows)
            HeartSample(
              at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
              bpm: row['bpm'] as int,
            ),
        ];
      }
      final points = await _health.getHealthDataFromTypes(
          types: _types, startTime: start, endTime: end);
      return [
        for (final point in points)
          if (point
              case HealthDataPoint(
                type: HealthDataType.HEART_RATE,
                unit: HealthDataUnit.BEATS_PER_MINUTE,
                value: NumericHealthValue(:final numericValue),
              ) when numericValue.isFinite)
            HeartSample(bpm: numericValue.round(), at: point.dateFrom),
      ];
    } on HealthSyncException {
      rethrow;
    } catch (_) {
      _requireSameAccount(accountId);
      throw HealthSyncException(_isAppleHealth
          ? 'Could not read Apple Health. Unlock your device and check NOVA Health’s Heart Rate access, or add a reading by hand.'
          : 'Could not read Health Connect. Make sure it is installed and up to date, then try again.');
    }
  }

  void _requireSameAccount(String accountId) {
    if (_repository.currentAccountId != accountId) {
      throw HealthSyncException(
          'Your NOVA account changed. Start a new import from the account that should receive the readings.');
    }
  }

  List<HeartSample> _selectSamples(
      List<HeartSample> points, DateTime start, DateTime end) {
    final sorted = [...points]..sort((a, b) => a.at.compareTo(b.at));
    final samples = <HeartSample>[];
    DateTime? lastKept;
    // Preserve the existing one-reading-per-ten-minute and 1000-reading limits.
    for (final point in sorted) {
      if (point.at.isBefore(start) || point.at.isAfter(end)) continue;
      if (point.bpm < 20 || point.bpm > 250) continue;
      if (lastKept != null && point.at.difference(lastKept).inMinutes < 10) {
        continue;
      }
      lastKept = point.at;
      samples.add(point);
    }
    return samples.length > 1000
        ? samples.sublist(samples.length - 1000)
        : samples;
  }
}
