import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  /// Builds today's snapshot for the Home screen from real data.
  Future<HealthSnapshot> loadToday() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOfDay = today.toUtc().toIso8601String();

    final water = await _db
        .from('water_logs')
        .select('amount_ml')
        .eq('user_id', _uid)
        .gte('logged_at', startOfDay);

    final sleep = await _db
        .from('sleep_logs')
        .select('hours')
        .eq('user_id', _uid)
        .gte('logged_at', startOfDay)
        .order('logged_at', ascending: false)
        .limit(1);

    final meds = await _db
        .from('medications')
        .select('name,dosage,times,start_date,end_date')
        .eq('user_id', _uid)
        .eq('status', 'confirmed');

    final profile =
        await _db.from('profiles').select('full_name').eq('id', _uid).maybeSingle();

    final waterMl = water.fold<int>(0, (sum, row) => sum + (row['amount_ml'] as num).toInt());
    final sleepMinutes = sleep.isEmpty ? 0 : ((sleep.first['hours'] as num) * 60).round();

    final fullName = ((profile?['full_name'] as String?) ?? '').trim();
    final firstName = fullName.isEmpty ? 'there' : fullName.split(' ').first;

    // ---- medication doses scheduled for today
    final doses = <_Dose>[];
    for (final m in meds) {
      final start = DateTime.tryParse((m['start_date'] as String?) ?? '');
      final end = DateTime.tryParse((m['end_date'] as String?) ?? '');
      if (start != null && start.isAfter(today)) continue;
      if (end != null && end.isBefore(today)) continue;
      for (final t in (m['times'] as List? ?? const [])) {
        final parts = (t as String).split(':');
        if (parts.length != 2) continue;
        final h = int.tryParse(parts[0]);
        final min = int.tryParse(parts[1]);
        if (h == null || min == null) continue;
        doses.add(_Dose(
          m['name'] as String,
          (m['dosage'] as String?) ?? '',
          DateTime(now.year, now.month, now.day, h, min),
        ));
      }
    }
    doses.sort((a, b) => a.at.compareTo(b.at));

    Medication? next;
    if (doses.isNotEmpty) {
      final upcoming = doses.where((d) => d.at.isAfter(now));
      final pick = upcoming.isNotEmpty ? upcoming.first : doses.first;
      next = Medication(name: pick.name, dose: pick.dose, time: formatClock(pick.at));
    } else if (meds.isNotEmpty) {
      next = Medication(
        name: meds.first['name'] as String,
        dose: (meds.first['dosage'] as String?) ?? '',
        time: 'no reminder set',
      );
    }

    return HealthSnapshot(
      firstName: firstName,
      isEmpty: waterMl == 0 && sleepMinutes == 0 && meds.isEmpty,
      waterL: waterMl / 1000,
      sleepMinutes: sleepMinutes,
      nextMedication: next,
      medsToday: doses.length,
    );
  }
}
