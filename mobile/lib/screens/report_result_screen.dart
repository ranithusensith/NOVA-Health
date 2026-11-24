import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/health_repository.dart';
import '../data/profile_models.dart';
import '../data/scan_models.dart';
import '../services/api_client.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import 'scan_camera_screen.dart';

/// Review what was printed before any lab result is saved.
class ReportResultScreen extends StatefulWidget {
  const ReportResultScreen({
    super.key,
    required this.scan,
    required this.onConfirm,
    this.imageBytes,
  });

  final ReportScan scan;
  final Uint8List? imageBytes;
  final Future<int> Function(DateTime?, List<LabResultDraft>) onConfirm;

  @override
  State<ReportResultScreen> createState() => _ReportResultScreenState();
}

class _ReportResultScreenState extends State<ReportResultScreen> {
  late final List<LabResultDraft> _rows = List.of(widget.scan.results);
  late DateTime? _reportDate = widget.scan.reportDate;
  bool _saving = false;
  bool _reviewed = false;

  int get _selected => _rows.where((row) => row.include).length;

  Future<void> _confirm() async {
    if (_saving || !_reviewed) return;
    final rows = _rows.where((row) => row.include).toList();
    if (rows.isEmpty || rows.any((row) => row.valueText == null)) {
      _message('Enter a result for each included row, or leave that row out.');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await widget.onConfirm(_reportDate, rows);
      if (!mounted) return;
      if (saved > 0) HealthRepository.notifyChanged();
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).popUntil((route) => route.isFirst);
      messenger.showSnackBar(SnackBar(
          content: Text(saved == 0
              ? 'Demo review finished.'
              : '$saved ${saved == 1 ? 'result' : 'results'} saved to Medical records')));
    } on ApiException catch (error) {
      if (mounted) _message(error.message);
    } catch (_) {
      if (mounted) {
        _message(
            'Could not verify the save. Check Medical records before trying again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _edit(int index) async {
    final updated = await showDialog<LabResultDraft>(
      context: context,
      builder: (_) => _EditLabResult(row: _rows[index]),
    );
    if (updated == null || !mounted) return;
    setState(() {
      _rows[index] = updated;
      _reviewed = false;
    });
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _reportDate ?? today,
      firstDate: DateTime(1900),
      lastDate: today.isBefore(_reportDate ?? today) ? _reportDate! : today,
    );
    if (date == null || !mounted) return;
    setState(() {
      _reportDate = date;
      _reviewed = false;
    });
  }

  void _retake() {
    if (_saving) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const ScanCameraScreen(initialMode: ScanMode.report),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final date = _reportDate;
    final image = widget.imageBytes;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Review lab results')),
      body: ListView(
        padding: const EdgeInsets.all(NovaSpace.margin),
        children: [
          if (widget.scan.reportType case final type?)
            Text(type, style: NovaType.headline.copyWith(color: c.textPrimary)),
          Text(widget.scan.confidence < 0.7
              ? 'Some text was hard to read. Compare each row with the report and correct any errors.'
              : 'Compare each row with the report. Keep any comparison signs, units, ranges, and flags as printed.'),
          if (image != null)
            ExpansionTile(
              title: const Text('View report photo'),
              children: [
                SizedBox(
                  height: 300,
                  child: InteractiveViewer(
                      maxScale: 5, child: Image.memory(image)),
                ),
              ],
            ),
          ListTile(
            title: const Text('Report date'),
            subtitle: Text(date == null ? 'Unknown' : formatDate(date)),
            onTap: _saving ? null : _pickDate,
            trailing: date == null
                ? const Icon(Icons.edit_outlined)
                : IconButton(
                    tooltip: 'Clear report date',
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                              _reportDate = null;
                              _reviewed = false;
                            }),
                    icon: const Icon(Icons.clear),
                  ),
          ),
          NovaCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var index = 0; index < _rows.length; index++)
                  _resultRow(index),
              ],
            ),
          ),
          CheckboxListTile(
            title:
                const Text('I checked the selected results against my report.'),
            value: _reviewed,
            onChanged: _saving
                ? null
                : (value) => setState(() => _reviewed = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          const DisclaimerNote(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(NovaSpace.margin),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NovaButton(
              label: _saving
                  ? 'Saving…'
                  : 'Save $_selected ${_selected == 1 ? 'result' : 'results'}',
              onPressed:
                  _saving || !_reviewed || _selected == 0 ? null : _confirm,
            ),
            NovaButton(
                label: 'Retake photo',
                kind: NovaButtonKind.plain,
                onPressed: _saving ? null : _retake),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(int index) {
    final row = _rows[index];
    final detail = [
      if (row.valueText == null)
        'Result needs review'
      else
        [row.valueText, row.unit].nonNulls.join(' '),
      if (row.referenceText case final range?) 'Reference $range',
      if (row.reportedFlag case final flag?) 'Printed flag $flag',
    ];
    return ListTile(
      leading: Checkbox(
        semanticLabel: 'Include ${row.test}',
        value: row.include,
        onChanged: _saving
            ? null
            : (value) => setState(() {
                  row.include = value ?? false;
                  _reviewed = false;
                }),
      ),
      title: Text(row.test),
      subtitle: Text(detail.join(' · ')),
      trailing: IconButton(
        tooltip: 'Edit ${row.test}',
        onPressed: _saving ? null : () => _edit(index),
        icon: const Icon(Icons.edit_outlined),
      ),
    );
  }
}

class _EditLabResult extends StatefulWidget {
  const _EditLabResult({required this.row});

  final LabResultDraft row;

  @override
  State<_EditLabResult> createState() => _EditLabResultState();
}

class _EditLabResultState extends State<_EditLabResult> {
  final _form = GlobalKey<FormState>();
  late String _test = widget.row.test;
  late String? _result = widget.row.valueText;
  late String? _unit = widget.row.unit;
  late String? _reference = widget.row.referenceText;
  late String? _flag = widget.row.reportedFlag;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit lab result'),
        scrollable: true,
        content: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field('Test name', _test, 80, (value) => _test = value!,
                  isRequired: true),
              _field('Printed result', _result, 160, (value) => _result = value,
                  isRequired: true,
                  validate: (value) => RegExp(r'^[<>=≤≥\s]+$').hasMatch(value)
                      ? 'Enter the complete result.'
                      : null),
              _field('Unit', _unit, 40, (value) => _unit = value),
              _field('Reference range', _reference, 240,
                  (value) => _reference = value),
              _field('Printed flag', _flag, 40, (value) => _flag = value),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!_form.currentState!.validate()) return;
              _form.currentState!.save();
              Navigator.pop(
                  context,
                  LabResultDraft(
                    test: _test,
                    valueText: _result,
                    extractedValueText: widget.row.extractedValueText,
                    unit: _unit,
                    referenceText: _reference,
                    reportedFlag: _flag,
                  )..include = widget.row.include);
            },
            child: const Text('Apply correction'),
          ),
        ],
      );

  Widget _field(
    String label,
    String? initial,
    int limit,
    ValueChanged<String?> save, {
    bool isRequired = false,
    String? Function(String)? validate,
  }) =>
      TextFormField(
        decoration: InputDecoration(labelText: label, counterText: ''),
        initialValue: initial,
        maxLength: limit,
        validator: (input) {
          final value = input?.trim() ?? '';
          if (isRequired && value.isEmpty) {
            return 'Enter ${label.toLowerCase()}.';
          }
          return validate?.call(value);
        },
        onSaved: (input) {
          final value = input?.trim() ?? '';
          save(value.isEmpty ? null : value);
        },
      );
}
