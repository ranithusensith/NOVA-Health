import 'package:supabase_flutter/supabase_flutter.dart';

import 'scan_models.dart';

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
  final String flag;
  final DateTime? reportedOn;
  final String? reportType;

  String get resultText {
    final v = value;
    final text = v == null ? (valueText ?? '') : formatNumber(v);
    return unit == null || unit!.isEmpty ? text : '$text $unit';
  }

  String get rangeText {
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

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Saves the rows the user kept ticked. Returns how many were saved.
  Future<int> save(ReportScan scan) async {
    final date = scan.reportDate ?? DateTime.now();
    final rows = [
      for (final r in scan.results)
        if (r.include && r.test.trim().isNotEmpty)
          {
            'user_id': _uid,
            'test_name': r.test.trim(),
            'value': r.value,
            'value_text': r.valueText,
            'unit': r.unit,
            'ref_low': r.refLow,
            'ref_high': r.refHigh,
            'flag': r.flag,
            'report_type': scan.reportType,
            'reported_on': _ymd(date),
            'source': 'scan',
          },
    ];
    if (rows.isEmpty) return 0;
    await _db.from('lab_results').insert(rows);
    return rows.length;
  }

  Future<List<LabRecord>> list({int limit = 200}) async {
    final rows = await _db
        .from('lab_results')
        .select('id,test_name,value,value_text,unit,ref_low,ref_high,flag,report_type,reported_on,created_at')
        .eq('user_id', _uid)
        .order('reported_on', ascending: false)
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
