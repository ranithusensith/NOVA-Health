import 'package:supabase_flutter/supabase_flutter.dart';

import 'care_models.dart';
import 'health_repository.dart';

/// Medications, dose logs, history and emergency contacts in Supabase.
/// Every query is scoped to the signed-in user; row-level security enforces it too.
///
/// Tables and columns used (keep in sync with the Supabase schema):
/// - medications: id, user_id, name, dosage, times (text[] "HH:MM"),
///   start_date, end_date, source, status ('confirmed' | 'ended')
/// - medication_logs: id, user_id, medication_id, taken_at
/// - emergency_contacts: id, user_id, name, phone, relationship
/// - water_logs / sleep_logs / mood_logs / meal_logs: read for history
/// - profiles: id, full_name
class CareRepository {
  CareRepository._();
  static final CareRepository instance = CareRepository._();

  SupabaseClient get _db => Supabase.instance.client;
  String get _uid => _db.auth.currentUser!.id;

  static const _moodByLevel = ['bad', 'low', 'ok', 'good', 'great'];

  String _utc(DateTime local) => local.toUtc().toIso8601String();

  // ------------------------------------------------------------ medications

  Future<List<MedicationRecord>> medications({bool includeEnded = false}) async {
    var query = _db
        .from('medications')
        .select('id,name,dosage,times,start_date,end_date,status,source')
        .eq('user_id', _uid);
    if (!includeEnded) query = query.neq('status', 'ended');
    final rows = await query.order('name');
    return [for (final r in rows) MedicationRecord.fromJson(r)];
  }

  Future<void> addMedication({
    required String name,
    String? dosage,
    required List<String> times,
    required DateTime startDate,
    DateTime? endDate,
  }) async {
    await _db.from('medications').insert({
      'user_id': _uid,
      'name': name,
      'dosage': (dosage == null || dosage.isEmpty) ? null : dosage,
      'times': times,
      'start_date': ymd(startDate),
      'end_date': endDate == null ? null : ymd(endDate),
      'source': 'manual',
      'status': 'confirmed',
    });
    HealthRepository.notifyChanged();
  }

  Future<void> updateMedication(
    String id, {
    required String name,
    String? dosage,
    required List<String> times,
    required DateTime startDate,
    DateTime? endDate,
  }) async {
    await _db.from('medications').update({
      'name': name,
      'dosage': (dosage == null || dosage.isEmpty) ? null : dosage,
      'times': times,
      'start_date': ymd(startDate),
      'end_date': endDate == null ? null : ymd(endDate),
    }).eq('id', id).eq('user_id', _uid);
    HealthRepository.notifyChanged();
  }

  /// Stops a medicine: it stays in history but leaves the schedule.
  Future<void> stopMedication(String id) async {
    await _db
        .from('medications')
        .update({'status': 'ended', 'end_date': ymd(DateTime.now())})
        .eq('id', id)
        .eq('user_id', _uid);
    HealthRepository.notifyChanged();
  }

  // ------------------------------------------------------------ dose logs

  Future<void> logDose(String medicationId) async {
    await _db.from('medication_logs').insert({
      'user_id': _uid,
      'medication_id': medicationId,
      'taken_at': _utc(DateTime.now()),
    });
    HealthRepository.notifyChanged();
  }

  /// Removes the most recent dose logged today for [medicationId] (Undo).
  Future<void> undoLastDose(String medicationId) async {
    final today = dayOf(DateTime.now());
    final rows = await _db
        .from('medication_logs')
        .select('id')
        .eq('user_id', _uid)
        .eq('medication_id', medicationId)
        .gte('taken_at', _utc(today))
        .order('taken_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return;
    await _db.from('medication_logs').delete().eq('id', rows.first['id']).eq('user_id', _uid);
    HealthRepository.notifyChanged();
  }

  Future<Map<String, int>> _takenCounts(DateTime from, DateTime to) async {
    final rows = await _db
        .from('medication_logs')
        .select('medication_id,taken_at')
        .eq('user_id', _uid)
        .gte('taken_at', _utc(from))
        .lt('taken_at', _utc(to));
    final counts = <String, int>{};
    for (final r in rows) {
      final id = r['medication_id'].toString();
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts;
  }

  /// Today's dose timeline built from active medications and today's logs.
  Future<List<DoseSlot>> todaySchedule() async {
    final now = DateTime.now();
    final today = dayOf(now);
    final meds = await medications();
    final counts = await _takenCounts(today, today.add(const Duration(days: 1)));
    return buildSchedule(meds, counts, now);
  }

  // ------------------------------------------------------------ history

  /// Per-day stats for the last [days] days, oldest first, today last.
  Future<List<DayStats>> history({int days = 7}) async {
    final today = dayOf(DateTime.now());
    final from = today.subtract(Duration(days: days - 1));
    final to = today.add(const Duration(days: 1));

    final water = await _db
        .from('water_logs')
        .select('amount_ml,logged_at')
        .eq('user_id', _uid)
        .gte('logged_at', _utc(from))
        .lt('logged_at', _utc(to));
    final sleep = await _db
        .from('sleep_logs')
        .select('hours,logged_at')
        .eq('user_id', _uid)
        .gte('logged_at', _utc(from))
        .lt('logged_at', _utc(to))
        .order('logged_at');
    final mood = await _db
        .from('mood_logs')
        .select('mood,logged_at')
        .eq('user_id', _uid)
        .gte('logged_at', _utc(from))
        .lt('logged_at', _utc(to))
        .order('logged_at');
    final doses = await _db
        .from('medication_logs')
        .select('taken_at')
        .eq('user_id', _uid)
        .gte('taken_at', _utc(from))
        .lt('taken_at', _utc(to));

    List<dynamic> meals = const [];
    try {
      meals = await _db
          .from('meal_logs')
          .select('calories,logged_at')
          .eq('user_id', _uid)
          .gte('logged_at', _utc(from))
          .lt('logged_at', _utc(to));
    } catch (_) {
      // Meals are optional for history; keep going without them.
    }

    final meds = await medications(includeEnded: true);

    int indexOf(String? iso) {
      final t = DateTime.tryParse(iso ?? '');
      if (t == null) return -1;
      return dayOf(t.toLocal()).difference(from).inDays;
    }

    final waterMl = List<int>.filled(days, 0);
    final sleepH = List<double?>.filled(days, null);
    final moodL = List<int?>.filled(days, null);
    final taken = List<int>.filled(days, 0);
    final kcal = List<int>.filled(days, 0);

    for (final r in water) {
      final i = indexOf(r['logged_at'] as String?);
      if (i >= 0 && i < days) waterMl[i] += (r['amount_ml'] as num).toInt();
    }
    for (final r in sleep) {
      final i = indexOf(r['logged_at'] as String?);
      if (i >= 0 && i < days) sleepH[i] = (r['hours'] as num).toDouble(); // latest wins
    }
    for (final r in mood) {
      final i = indexOf(r['logged_at'] as String?);
      final level = _moodByLevel.indexOf((r['mood'] as String?) ?? '');
      if (i >= 0 && i < days && level >= 0) moodL[i] = level; // latest wins
    }
    for (final r in doses) {
      final i = indexOf(r['taken_at'] as String?);
      if (i >= 0 && i < days) taken[i]++;
    }
    for (final r in meals) {
      final i = indexOf((r as Map)['logged_at'] as String?);
      if (i >= 0 && i < days) kcal[i] += ((r['calories'] as num?) ?? 0).toInt();
    }

    return [
      for (var i = 0; i < days; i++)
        DayStats(
          day: from.add(Duration(days: i)),
          waterMl: waterMl[i],
          sleepHours: sleepH[i],
          moodLevel: moodL[i],
          dosesTaken: taken[i],
          dosesScheduled: meds
              .where((m) => _wasActive(m, from.add(Duration(days: i))))
              .fold(0, (sum, m) => sum + m.times.length),
          calories: kcal[i],
        ),
    ];
  }

  /// An ended medicine still counts for the days before it was stopped.
  bool _wasActive(MedicationRecord m, DateTime day) {
    final d = dayOf(day);
    if (m.startDate != null && dayOf(m.startDate!).isAfter(d)) return false;
    if (m.endDate != null && dayOf(m.endDate!).isBefore(d)) return false;
    return true;
  }

  /// Stats for a single day (used by the daily report).
  Future<DayStats> dayStats(DateTime day) async {
    final today = dayOf(DateTime.now());
    final back = today.difference(dayOf(day)).inDays;
    if (back < 0) return DayStats(day: dayOf(day));
    final list = await history(days: back + 1);
    return list.first;
  }

  // ------------------------------------------------------------ emergency contacts

  Future<List<EmergencyContact>> emergencyContacts() async {
    final rows = await _db
        .from('emergency_contacts')
        .select('id,name,phone,relationship')
        .eq('user_id', _uid)
        .order('name');
    return [for (final r in rows) EmergencyContact.fromJson(r)];
  }

  Future<void> addEmergencyContact({required String name, required String phone, String? relationship}) async {
    await _db.from('emergency_contacts').insert({
      'user_id': _uid,
      'name': name,
      'phone': phone,
      'relationship': (relationship == null || relationship.isEmpty) ? null : relationship,
    });
  }

  Future<void> deleteEmergencyContact(String id) async {
    await _db.from('emergency_contacts').delete().eq('id', id).eq('user_id', _uid);
  }

  // ------------------------------------------------------------ profile

  Future<String> fullName() async {
    final row = await _db.from('profiles').select('full_name').eq('id', _uid).maybeSingle();
    return ((row?['full_name'] as String?) ?? '').trim();
  }

  Future<void> updateFullName(String name) async {
    await _db.from('profiles').update({'full_name': name}).eq('id', _uid);
    HealthRepository.notifyChanged();
  }
}
