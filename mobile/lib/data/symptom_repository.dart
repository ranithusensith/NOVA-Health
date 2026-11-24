import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

enum SymptomSeverity {
  mild('Mild'),
  moderate('Moderate'),
  severe('Severe');

  const SymptomSeverity(this.label);
  final String label;
}

enum SymptomStatus {
  active('Active'),
  resolved('Resolved');

  const SymptomStatus(this.label);
  final String label;
}

class SymptomDraft {
  const SymptomDraft({
    required this.name,
    required this.onset,
    required this.status,
    this.severity,
    this.notes,
  });

  final String name;
  final DateTime onset;
  final SymptomStatus status;
  final SymptomSeverity? severity;
  final String? notes;

  bool needsSafetyCheck(DateTime now) =>
      status == SymptomStatus.active &&
      !onset.isAfter(now) &&
      !onset.isBefore(now.subtract(const Duration(hours: 24)));

  Map<String, dynamic> get safetyJson => {
        'name': name,
        'started_at': onset.toUtc().toIso8601String(),
        'status': status.name,
        'notes': notes,
      };

  Map<String, dynamic> get values =>
      {...safetyJson, 'severity': severity?.name};
}

class SymptomRecord {
  const SymptomRecord({
    required this.id,
    required this.revision,
    required this.name,
    this.onset,
    this.status,
    this.severity,
    this.notes,
  });

  factory SymptomRecord.fromJson(Map<String, dynamic> row) => SymptomRecord(
        id: row['id'] as String,
        revision: row['revision'] as String,
        name: (row['name'] as String?)?.trim() ?? '',
        onset: DateTime.tryParse(row['started_at'] as String? ?? ''),
        status: SymptomStatus.values
            .where((status) => status.name == row['status'])
            .firstOrNull,
        severity: SymptomSeverity.values
            .where((level) => level.name == row['severity'])
            .firstOrNull,
        notes: row['notes'] as String?,
      );

  final String id;
  final String revision;
  final String name;
  final DateTime? onset;
  final SymptomStatus? status;
  final SymptomSeverity? severity;
  final String? notes;

  bool matches(SymptomDraft draft) =>
      name == draft.name &&
      onset?.isAtSameMomentAs(draft.onset) == true &&
      status == draft.status &&
      severity == draft.severity &&
      notes == draft.notes;
}

abstract interface class SymptomStore {
  Future<List<SymptomRecord>> history({SymptomRecord? after});
  Future<void> save(SymptomDraft draft,
      {required String entryId, SymptomRecord? existing});
  Future<void> delete(SymptomRecord record);
}

class SymptomRepository implements SymptomStore {
  SymptomRepository(this._db, this._owner);

  static const pageSize = 30;
  static const _fields = 'id,revision,name,severity,status,started_at,notes';

  final SupabaseClient _db;
  final String _owner;

  void _checkAccount() {
    if (_db.auth.currentUser?.id != _owner) {
      throw const SymptomChangesException(
          'Open Symptoms again from your signed-in account.');
    }
  }

  @override
  Future<List<SymptomRecord>> history({SymptomRecord? after}) async {
    _checkAccount();
    var query = _db.from('symptom_logs').select(_fields).eq('user_id', _owner);
    if (after != null) {
      final instant = after.onset?.toUtc().toIso8601String();
      if (instant == null) {
        throw const SymptomChangesException(
            'Could not continue from this entry. Refresh symptom history.');
      }
      query = query.or(
          'started_at.lt.$instant,and(started_at.eq.$instant,id.lt.${after.id})');
    }
    final rows = await query
        .order('started_at', ascending: false)
        .order('id', ascending: false)
        .limit(pageSize);
    _checkAccount();
    return rows.map(SymptomRecord.fromJson).toList();
  }

  @override
  Future<void> save(SymptomDraft draft,
      {required String entryId, SymptomRecord? existing}) async {
    _checkAccount();
    if (existing == null) {
      try {
        await _db
            .from('symptom_logs')
            .insert({'id': entryId, 'user_id': _owner, ...draft.values});
      } on PostgrestException catch (error) {
        if (error.code != '23505') rethrow;
        _checkAccount();
        final row = await _db
            .from('symptom_logs')
            .select(_fields)
            .eq('user_id', _owner)
            .eq('id', entryId)
            .maybeSingle();
        if (row == null || !SymptomRecord.fromJson(row).matches(draft)) {
          throw const SymptomChangesException(
              'Could not verify the save. Check symptom history before trying again.');
        }
      }
    } else {
      final rows = await _db
          .from('symptom_logs')
          .update(draft.values)
          .eq('user_id', _owner)
          .eq('id', existing.id)
          .eq('revision', existing.revision)
          .select('id');
      if (rows.length != 1) {
        throw const SymptomChangesException(
            'This entry changed. Reopen it from symptom history.');
      }
    }
    _checkAccount();
  }

  @override
  Future<void> delete(SymptomRecord record) async {
    _checkAccount();
    final rows = await _db
        .from('symptom_logs')
        .delete()
        .eq('user_id', _owner)
        .eq('id', record.id)
        .eq('revision', record.revision)
        .select('id');
    if (rows.length != 1) {
      throw const SymptomChangesException(
          'This entry changed. Reopen it from symptom history.');
    }
    _checkAccount();
  }
}

class SymptomChangesException implements Exception {
  const SymptomChangesException(this.message);
  final String message;
}

String newSymptomId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
