import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_client.dart';
import 'care_models.dart';
import 'daily_metrics.dart';
import 'scan_models.dart';
import 'wearable_daily.dart';
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
  static final medicationChanges = ValueNotifier<int>(0);

  static void notifyMedicationsChanged() {
    medicationChanges.value++;
    HealthRepository.notifyChanged();
  }

  final SupabaseClient? _client;
  SupabaseClient get _db => _client ?? Supabase.instance.client;
  String get _uid => _db.auth.currentUser!.id;

  String _utc(DateTime local) => local.toUtc().toIso8601String();

  // ------------------------------------------------------------ medications

  Future<List<MedicationRecord>> medications({bool includeEnded = false, String? accountId}) async {
    var query = _db
        .from('medications')
        .select('id,name,dosage,times,start_date,end_date,status,source,prescription_plan,reminders_enabled,review_revision')
        .eq('user_id', accountId ?? _uid);
    if (!includeEnded) query = query.neq('status', 'ended');
    final rows = await query.order('name');
    return [for (final r in rows) MedicationRecord.fromJson(r)];
  }

  Future<PrescriptionConfirmation> reviewMedication(Map<String, dynamic> draft) async {
    final result = await ApiClient.instance.confirmMedication(draft);
    if (result.activated) notifyMedicationsChanged();
    return result;
  }

  /// Stops a medicine: it stays in history but leaves the schedule.
  Future<void> stopMedication(String id, String? expectedAccountId) async {
    if (expectedAccountId == null || _uid != expectedAccountId) {
      throw ApiException('Use the account that opened this medication.');
    }
    final stopped = await _db
        .from('medications')
        .update({'status': 'ended', 'end_date': ymd(DateTime.now())})
        .eq('id', id)
        .eq('user_id', expectedAccountId)
        .eq('status', 'confirmed')
        .select('id')
        .maybeSingle();
    if (stopped == null) throw ApiException('This medication changed. Reopen it to see the current details.');
    notifyMedicationsChanged();
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
    return _history(from, days);
  }

  Future<List<DayStats>> _history(DateTime from, int days) async {
    final to = calendarDay(from, days);
    final owner = _uid;
    final water = bucketDailyRows(await dailyRows(_db, owner, 'water_logs', 'amount_ml', from, to));
    final sleep = bucketDailyRows(await dailyRows(_db, owner, 'sleep_logs', 'hours', from, to));
    final mood = bucketDailyRows(await dailyRows(_db, owner, 'mood_logs', 'mood', from, to));
    final meals = bucketDailyRows(await dailyRows(_db, owner, 'meal_logs', 'calories', from, to));
    final doses = await _doseLogs(owner, from, to);
    final meds = await medications(includeEnded: true, accountId: owner);
    final goals = DailyGoals.fromJson(await _db.from('profiles')
        .select('water_goal_ml,sleep_goal_hours').eq('id', owner).maybeSingle());

    int indexOf(String? iso) {
      final t = DateTime.tryParse(iso ?? '');
      return t == null ? -1 : calendarDaysBetween(from, t.toLocal());
    }

    final taken = List<int>.filled(days, 0);
    final unassigned = List<int>.filled(days, 0);
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
    final wearableDays = [for (var i = 0; i < days; i++) WearableDay(calendarDay(from, i))];
    final imported = await WearableDailyRepository(client: _db).read(wearableDays, owner);
    return [
      for (var i = 0; i < days; i++)
        _dayStats(calendarDay(from, i), water, sleep, mood, meals, goals, taken[i], unassigned[i], meds,
            imported[wearableDays[i].date]),
    ];
  }

  DayStats _dayStats(
    DateTime day,
    Map<DateTime, List<Map<String, dynamic>>>? water,
    Map<DateTime, List<Map<String, dynamic>>>? sleep,
    Map<DateTime, List<Map<String, dynamic>>>? mood,
    Map<DateTime, List<Map<String, dynamic>>>? meals,
    DailyGoals goals,
    int taken,
    int unassigned,
    List<MedicationRecord> meds,
    WearableDailyReadings? imported,
  ) => DayStats(
    day: day,
    waterMl: dailyTotal(water?[day], 'amount_ml'),
    waterGoalMl: goals.waterMl,
    sleepHours: sleep != null && sleep[day] == null ? imported?.sleepHours : dailySleep(sleep?[day]),
    sleepSource: sleep != null && sleep[day] == null ? imported?.sleep?.sourceLabel : null,
    wearableSleepHours: imported?.sleepHours,
    wearableSleepSource: imported?.sleep?.sourceLabel,
    steps: imported?.steps?.value,
    stepsSource: imported?.steps?.sourceLabel,
    sleepGoalHours: goals.sleepHours,
    moodLevel: dailyMood(mood?[day]),
    dosesTaken: taken,
    unassignedDoseLogs: unassigned,
    dosesScheduled: meds.fold(0, (sum, med) => sum + med.dosesOn(day, includeEnded: true).length),
    mealCount: meals == null ? null : meals[day]?.length ?? 0,
    calories: dailyTotal(meals?[day], 'calories'),
  );

  Future<DayStats> dayStats(DateTime day) async => (await _history(dayOf(day), 1)).single;

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
