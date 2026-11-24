import 'package:supabase_flutter/supabase_flutter.dart';

import 'care_models.dart';
import 'health_repository.dart';

/// Medications, dose logs, history and emergency contacts in Supabase.
/// Every query is scoped to the signed-in user; row-level security enforces it too.
///
/// Tables and columns used (keep in sync with the Supabase schema):
/// - medications: id, user_id, name, dosage, times (text[] "HH:MM"),
///   start_date, end_date, source, status ('confirmed' | 'ended')
/// - medication_logs: id, user_id, medication_id, taken_at, scheduled_at,
///   scheduled_local_at, occurrence_key
/// - emergency_contacts: id, user_id, name, phone, relationship
/// - water_logs / sleep_logs / mood_logs / meal_logs: read for history
/// - profiles: id, full_name
class CareRepository {
  CareRepository({SupabaseClient? client}) : _client = client;
  static final CareRepository instance = CareRepository();

  final SupabaseClient? _client;
  SupabaseClient get _db => _client ?? Supabase.instance.client;
  String get _uid => _db.auth.currentUser!.id;

  static const _moodByLevel = ['bad', 'low', 'ok', 'good', 'great'];

  String _utc(DateTime local) => local.toUtc().toIso8601String();

  // ------------------------------------------------------------ medications

  Future<List<MedicationRecord>> medications({bool includeEnded = false, String? accountId}) async {
    var query = _db
        .from('medications')
        .select('id,name,dosage,times,start_date,end_date,status,source,prescription_plan,reminders_enabled')
        .eq('user_id', accountId ?? _uid);
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
    bool? remindersEnabled,
  }) async {
    await _db.from('medications').update({
      'name': name,
      'dosage': (dosage == null || dosage.isEmpty) ? null : dosage,
      'times': times,
      'start_date': ymd(startDate),
      'end_date': endDate == null ? null : ymd(endDate),
      if (remindersEnabled != null) 'reminders_enabled': remindersEnabled,
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

  /// Returns the new log ID, or null when this occurrence was already logged.
  Future<String?> logDose(DoseOccurrence occurrence) async {
    _checkDoseAccount(occurrence);
    final inserted = await _db
        .from('medication_logs')
        .upsert({
          'user_id': occurrence.accountId,
          'medication_id': occurrence.key.medicationId,
          'scheduled_at': _utc(occurrence.scheduledAt),
          'scheduled_local_at': occurrence.scheduledLocalAt,
          'status': 'taken',
        }, onConflict: 'user_id,medication_id,occurrence_key', ignoreDuplicates: true)
        .select('id');
    HealthRepository.notifyChanged();
    return inserted.isEmpty ? null : inserted.single['id'] as String;
  }

  /// Removes only this instance of the log, even if the dose was later re-logged.
  Future<void> undoDose(DoseOccurrence occurrence, String logId) async {
    _checkDoseAccount(occurrence);
    await _db
        .from('medication_logs')
        .delete()
        .eq('user_id', occurrence.accountId)
        .eq('medication_id', occurrence.key.medicationId)
        .eq('occurrence_key', occurrence.key.occurrenceKey)
        .eq('id', logId);
    HealthRepository.notifyChanged();
  }

  void _checkDoseAccount(DoseOccurrence occurrence) {
    if (_uid != occurrence.accountId) throw StateError('Sign in again to change this dose.');
  }

  Future<List<Map<String, dynamic>>> _doseLogs(String accountId, DateTime from, DateTime to) async {
    final start = _utc(from);
    final end = _utc(to);
    final startLocal = '${ymd(from)}T00:00:00';
    final endLocal = '${ymd(to)}T00:00:00';
    final rows = <Map<String, dynamic>>[];
    const pageSize = 250;
    while (true) {
      var query = _db
          .from('medication_logs')
          .select('id,medication_id,occurrence_key,scheduled_at,scheduled_local_at,taken_at')
          .eq('user_id', accountId)
          .eq('status', 'taken')
          .or('and(scheduled_local_at.gte.$startLocal,scheduled_local_at.lt.$endLocal),'
              'and(scheduled_local_at.is.null,scheduled_at.gte.$start,scheduled_at.lt.$end),'
              'and(scheduled_at.is.null,taken_at.gte.$start,taken_at.lt.$end)');
      if (rows.isNotEmpty) query = query.gt('id', rows.last['id'] as String);
      final page = await query.order('id', ascending: true).limit(pageSize);
      rows.addAll(page);
      if (page.length < pageSize) return rows;
    }
  }

  /// Today's schedule and the logs that explicitly identify those slots.
  Future<List<DoseSlot>> todaySchedule() async {
    final accountId = _uid;
    final now = DateTime.now();
    final meds = await medications(accountId: accountId);
    final logs = await _doseLogs(accountId, dayOf(now), calendarDay(now, 1));
    return buildSchedule(
      meds,
      {
        for (final row in logs)
          if (row['occurrence_key'] case final String key)
            (medicationId: row['medication_id'] as String, occurrenceKey: key): row['id'] as String,
      },
      now,
      accountId: accountId,
      unassignedMedicationIds: {
        for (final row in logs)
          if (row['occurrence_key'] == null) row['medication_id'] as String,
      },
    );
  }

  // ------------------------------------------------------------ history

  /// Per-day stats for the last [days] days, oldest first, today last.
  Future<List<DayStats>> history({int days = 7}) async {
    final today = dayOf(DateTime.now());
    final from = calendarDay(today, 1 - days);
    final to = calendarDay(today, 1);

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
    final doses = await _doseLogs(_uid, from, to);

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
      return calendarDaysBetween(from, t.toLocal());
    }

    final waterMl = List<int>.filled(days, 0);
    final sleepH = List<double?>.filled(days, null);
    final moodL = List<int?>.filled(days, null);
    final taken = List<int>.filled(days, 0);
    final unassigned = List<int>.filled(days, 0);
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
      final wallTime = r['scheduled_local_at'] as String?;
      final i = wallTime == null
          ? indexOf((r['scheduled_at'] ?? r['taken_at']) as String?)
          : calendarDaysBetween(from, DateTime.parse('${wallTime.substring(0, 10)}T00:00:00Z'));
      if (i >= 0 && i < days) {
        if (r['occurrence_key'] == null) {
          unassigned[i]++;
        } else {
          taken[i]++;
        }
      }
    }
    for (final r in meals) {
      final i = indexOf((r as Map)['logged_at'] as String?);
      if (i >= 0 && i < days) kcal[i] += ((r['calories'] as num?) ?? 0).toInt();
    }

    return [
      for (var i = 0; i < days; i++)
        DayStats(
          day: calendarDay(from, i),
          waterMl: waterMl[i],
          sleepHours: sleepH[i],
          moodLevel: moodL[i],
          dosesTaken: taken[i],
          unassignedDoseLogs: unassigned[i],
          dosesScheduled: meds.fold(
            0,
            (sum, m) => sum + m.dosesOn(calendarDay(from, i), includeEnded: true).length,
          ),
          calories: kcal[i],
        ),
    ];
  }

  /// Stats for a single day (used by the daily report).
  Future<DayStats> dayStats(DateTime day) async {
    final today = dayOf(DateTime.now());
    final back = calendarDaysBetween(day, today);
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

  Future<EmergencyContact> addEmergencyContact({required String name, required String phone, String? relationship}) async {
    final row = await _db.from('emergency_contacts').insert({
      'user_id': _uid,
      'name': name,
      'phone': phone,
      'relationship': (relationship == null || relationship.isEmpty) ? null : relationship,
    }).select('id,name,phone,relationship').single();
    return EmergencyContact.fromJson(row);
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
