import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'health_repository.dart';
import 'profile_models.dart';

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Health profile, allergies, heart rate and cycle data in Supabase.
/// Row-level security keeps every query limited to the signed-in user.
class ProfileRepository {
  ProfileRepository({SupabaseClient? client}) : _client = client;
  static final ProfileRepository instance = ProfileRepository();

  final SupabaseClient? _client;
  SupabaseClient get _db => _client ?? Supabase.instance.client;
  String get _uid => _db.auth.currentUser!.id;

  // ------------------------------------------------------------ profile
  /// True until the user has finished (or skipped) the first-login questions.
  Future<bool> needsOnboarding() async {
    final row = await _db.from('profiles').select('onboarding_done').eq('id', _uid).maybeSingle();
    if (row == null) return false; // no profile row: nothing to fill in
    return row['onboarding_done'] != true;
  }

  Future<HealthProfile> load({String? accountId}) async {
    final row = await _db
        .from('profiles')
        .select('full_name,birth_date,sex,blood_type,height_cm,weight_kg,conditions,medical_notes,onboarding_done')
        .eq('id', accountId ?? _uid)
        .maybeSingle();
    if (row == null) return const HealthProfile();
    return HealthProfile.fromRow(row);
  }

  Future<void> save(
    HealthProfile profile, {
    required String accountId,
    required List<String> allergies,
  }) async {
    final fields = profile.toRow()..remove('onboarding_done');
    await _db.rpc<void>('save_health_profile', params: {
      'p_expected_user_id': accountId,
      for (final field in fields.entries) 'p_${field.key}': field.value,
      'p_allergies': List<String>.of(allergies),
    });
    HealthRepository.notifyChanged();
  }

  Future<void> skipOnboarding(String fullName, {required String accountId}) async {
    final name = fullName.trim();
    final updated = await _db.from('profiles').update({
      'full_name': name.isEmpty ? null : name,
      'onboarding_done': true,
    }).eq('id', accountId).select('id');
    if (updated.isEmpty) throw Exception('Profile not found. Sign out and sign in again.');
    HealthRepository.notifyChanged();
  }

  // ------------------------------------------------------------ allergies
  Future<List<AllergyRecord>> allergies({String? accountId}) async {
    final rows = await _db
        .from('allergies')
        .select('id,name')
        .eq('user_id', accountId ?? _uid)
        .eq('status', 'confirmed')
        .order('name');
    return [for (final r in rows) AllergyRecord(id: r['id'] as String, name: r['name'] as String)];
  }

  // ------------------------------------------------------------ heart rate
  Future<List<HeartReading>> heartReadings({int days = 7, int limit = 300}) async {
    final since = DateTime.now().subtract(Duration(days: days)).toUtc().toIso8601String();
    final rows = await _db
        .from('wearable_samples')
        .select('id,value,recorded_at,context,device')
        .eq('user_id', _uid)
        .eq('metric', 'heart_rate')
        .gte('recorded_at', since)
        .order('recorded_at', ascending: false)
        .limit(limit);
    return [
      for (final r in rows)
        HeartReading(
          id: r['id'] as String,
          bpm: (r['value'] as num).round(),
          at: DateTime.parse(r['recorded_at'] as String).toLocal(),
          context: (r['context'] as String?) ?? 'unknown',
          source: (r['device'] as String?) ?? 'manual',
        ),
    ];
  }

  Future<void> addHeartRate({required int bpm, required String context, DateTime? at}) async {
    await _db.from('wearable_samples').insert({
      'user_id': _uid,
      'metric': 'heart_rate',
      'value': bpm,
      'recorded_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'device': 'manual',
      'context': context,
    });
    HealthRepository.notifyChanged();
  }

  Future<void> deleteHeartReading(String id) async {
    await _db.from('wearable_samples').delete().eq('id', id).eq('user_id', _uid);
  }

  /// Saves readings from Apple Health or Health Connect. Duplicates are ignored,
  /// so syncing twice is safe. Returns how many readings were sent.
  Future<int> importHeartSamples(List<HeartSample> samples, {required String device}) async {
    if (samples.isEmpty) return 0;
    final rows = [
      for (final s in samples)
        {
          'user_id': _uid,
          'metric': 'heart_rate',
          'value': s.bpm,
          'recorded_at': s.at.toUtc().toIso8601String(),
          'device': device,
          'context': 'unknown',
        },
    ];
    for (var i = 0; i < rows.length; i += 200) {
      final chunk = rows.sublist(i, math.min(i + 200, rows.length));
      await _db
          .from('wearable_samples')
          .upsert(chunk, onConflict: 'user_id,metric,device,recorded_at', ignoreDuplicates: true);
    }
    HealthRepository.notifyChanged();
    return rows.length;
  }

  // ------------------------------------------------------------ cycle
  Future<List<PeriodRecord>> periods({int limit = 24}) async {
    final rows = await _db
        .from('period_logs')
        .select('id,start_date,end_date,flow,note')
        .eq('user_id', _uid)
        .order('start_date', ascending: false)
        .limit(limit);
    return [
      for (final r in rows)
        PeriodRecord(
          id: r['id'] as String,
          start: DateTime.parse(r['start_date'] as String),
          end: DateTime.tryParse((r['end_date'] as String?) ?? ''),
          flow: r['flow'] as String?,
          note: r['note'] as String?,
        ),
    ];
  }

  Future<void> startPeriod({required DateTime start, String? flow, String? note}) async {
    await _db.from('period_logs').insert({
      'user_id': _uid,
      'start_date': _ymd(start),
      'flow': flow,
      'note': (note == null || note.trim().isEmpty) ? null : note.trim(),
    });
  }

  Future<void> endPeriod(String id, DateTime end) async {
    await _db.from('period_logs').update({'end_date': _ymd(end)}).eq('id', id).eq('user_id', _uid);
  }

  Future<void> deletePeriod(String id) async {
    await _db.from('period_logs').delete().eq('id', id).eq('user_id', _uid);
  }
}
