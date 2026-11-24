import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'care_models.dart';
import 'daily_metrics.dart';
import 'sample_data.dart';

class _Dose {
  _Dose(this.name, this.dose, this.at);
  final String name;
  final String dose;
  final DateTime at;
}

/// Reads and writes the signed-in user's health data in Supabase.
/// Row-level security makes sure each user only ever touches their own rows.
class HealthRepository {
  HealthRepository._();
  static final HealthRepository instance = HealthRepository._();

  /// Bumped after every successful write. The app shell listens and reloads Home.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static void notifyChanged() => changes.value++;

  SupabaseClient get _db => Supabase.instance.client;
  String get _uid => _db.auth.currentUser!.id;

  /// Mood level 0 (awful) to 4 (great) -> value allowed by the mood_logs table.
  static const _moodByLevel = ['bad', 'low', 'ok', 'good', 'great'];

  Future<void> logWater(int ml) async {
    await _db.from('water_logs').insert({'user_id': _uid, 'amount_ml': ml});
    notifyChanged();
  }

  Future<void> logSleep(double hours) async {
    await _db.from('sleep_logs').insert({'user_id': _uid, 'hours': hours});
    notifyChanged();
  }

  Future<void> logMood(int level) async {
    await _db.from('mood_logs').insert({'user_id': _uid, 'mood': _moodByLevel[level]});
    notifyChanged();
  }

  Future<DailyGoals> loadDailyGoals() async {
    final profile = await _db.from('profiles')
        .select('water_goal_ml,sleep_goal_hours').eq('id', _uid).single();
    return DailyGoals.fromJson(profile);
  }

  Future<DailyGoals> saveDailyGoal({required String accountId, required bool water, required num? value}) async {
    if (_db.auth.currentUser?.id != accountId) throw StateError('Account changed');
    final profile = await _db.from('profiles')
        .update({water ? 'water_goal_ml' : 'sleep_goal_hours': value})
        .eq('id', accountId).select('water_goal_ml,sleep_goal_hours').single();
    if (_db.auth.currentUser?.id != accountId) throw StateError('Account changed');
    notifyChanged();
    return DailyGoals.fromJson(profile);
  }

  /// Builds today's snapshot for the Home screen from real data.
  Future<HealthSnapshot> loadToday() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final owner = _uid;
    final window = dailyWindow(today);
    final water = await dailyRows(_db, owner, 'water_logs', 'amount_ml', window.start, window.end);
    final sleep = await dailyRows(_db, owner, 'sleep_logs', 'hours', window.start, window.end);

    final meds = await _db
        .from('medications')
        .select('name,dosage,times,start_date,end_date,prescription_plan')
        .eq('user_id', owner)
        .eq('status', 'confirmed');

    final profile =
        await _db.from('profiles').select('full_name,water_goal_ml,sleep_goal_hours').eq('id', owner).maybeSingle();

    final waterMl = dailyTotal(water, 'amount_ml');
    final sleepHours = dailySleep(sleep);
    final goals = DailyGoals.fromJson(profile);

    final fullName = ((profile?['full_name'] as String?) ?? '').trim();
    final firstName = fullName.isEmpty ? 'there' : fullName.split(' ').first;

    // ---- medication doses scheduled for today
    final doses = <_Dose>[];
    for (final m in meds) {
      final medicine = MedicationRecord.fromJson(m);
      for (final at in medicine.dosesOn(today)) {
        doses.add(_Dose(medicine.name, medicine.dosage ?? '', at));
      }
    }
    doses.sort((a, b) => a.at.compareTo(b.at));

    Medication? next;
    if (doses.isNotEmpty) {
      final upcoming = doses.where((d) => d.at.isAfter(now));
      final pick = upcoming.isNotEmpty ? upcoming.first : doses.first;
      next = Medication(name: pick.name, dose: pick.dose, time: formatClock(pick.at));
    } else if (meds.isNotEmpty) {
      final medicine = MedicationRecord.fromJson(meds.first);
      next = Medication(
        name: medicine.name,
        dose: medicine.dosage ?? '',
        time: medicine.prescriptionPlan?.timing == PrescriptionTiming.asNeeded ? 'As needed' : 'No dose time set',
      );
    }

    return HealthSnapshot(
      firstName: firstName,
      isEmpty: waterMl == null && sleepHours == null && meds.isEmpty,
      waterL: waterMl == null ? null : waterMl / 1000,
      waterGoalL: goals.waterMl == null ? null : goals.waterMl! / 1000,
      sleepMinutes: sleepHours == null ? null : (sleepHours * 60).round(),
      sleepGoalMinutes: goals.sleepHours == null ? null : (goals.sleepHours! * 60).round(),
      nextMedication: next,
      medsToday: doses.length,
    );
  }
}
