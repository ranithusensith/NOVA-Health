import 'package:supabase_flutter/supabase_flutter.dart';

/// A saved lab result (medical record).
class LabRecord {
  const LabRecord({
    required this.id,
    required this.test,
    this.value,
    this.valueText,
    this.unit,
    this.refLow,
    this.refHigh,
    this.referenceText,
    this.reportedFlag,
    required this.flag,
    this.reportedOn,
    this.reportType,
  });

  final String id;
  final String test;
  final double? value;
  final String? valueText;
  final String? unit;
  final double? refLow;
  final double? refHigh;
  final String? referenceText;
  final String? reportedFlag;
  final String flag;
  final DateTime? reportedOn;
  final String? reportType;

  String get resultText {
    final text = valueText ?? (value == null ? '' : formatNumber(value!));
    return unit == null || unit!.isEmpty ? text : '$text $unit';
  }

  String get rangeText {
    if (referenceText case final text?) return text;
    if (refLow != null && refHigh != null) return '${formatNumber(refLow!)} to ${formatNumber(refHigh!)}';
    if (refHigh != null) return 'below ${formatNumber(refHigh!)}';
    if (refLow != null) return 'above ${formatNumber(refLow!)}';
    return '';
  }
}

/// 11.0 -> "11", 11.25 -> "11.25", 7400.0 -> "7400"
String formatNumber(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

class LabRepository {
  LabRepository._();
  static final LabRepository instance = LabRepository._();

  SupabaseClient get _db => Supabase.instance.client;
  String get _uid => _db.auth.currentUser!.id;

  Future<List<LabRecord>> list({int limit = 200}) async {
    final rows = await _db
        .from('lab_results')
        .select('id,test_name,value,value_text,unit,ref_low,ref_high,flag,report_type,reported_on,created_at,reference_text,reported_flag')
        .eq('user_id', _uid)
        .order('reported_on', ascending: false, nullsFirst: false)
        .order('created_at', ascending: false)
        .limit(limit);
    return [
      for (final r in rows)
        LabRecord(
          id: r['id'] as String,
          test: r['test_name'] as String,
          value: (r['value'] as num?)?.toDouble(),
          valueText: r['value_text'] as String?,
          unit: r['unit'] as String?,
          refLow: (r['ref_low'] as num?)?.toDouble(),
          refHigh: (r['ref_high'] as num?)?.toDouble(),
          referenceText: r['reference_text'] as String?,
          reportedFlag: r['reported_flag'] as String?,
          flag: (r['flag'] as String?) ?? 'unknown',
          reportedOn: DateTime.tryParse((r['reported_on'] as String?) ?? ''),
          reportType: r['report_type'] as String?,
        ),
    ];
  }

  Future<void> delete(String id) async {
    await _db.from('lab_results').delete().eq('id', id).eq('user_id', _uid);
  }
}
