import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/symptom_repository.dart';
import '../services/api_client.dart';
import '../services/emergency_service.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/states.dart';
import 'emergency_screen.dart' show ambulanceNumber;

void openSymptoms(BuildContext context) {
  final db = Supabase.instance.client;
  final owner = db.auth.currentUser?.id;
  if (owner == null) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => SymptomsScreen(
      store: SymptomRepository(db, owner),
      checkEmergency: (draft) =>
          ApiClient.instance.checkSymptomEmergency(draft, owner),
      callAmbulance: () => EmergencyService.instance.call(ambulanceNumber),
    ),
  ));
}

class SymptomsScreen extends StatefulWidget {
  const SymptomsScreen({
    super.key,
    required this.store,
    required this.checkEmergency,
    required this.callAmbulance,
  });

  final SymptomStore store;
  final Future<String?> Function(SymptomDraft) checkEmergency;
  final Future<bool> Function() callAmbulance;

  @override
  State<SymptomsScreen> createState() => _SymptomsScreenState();
}

class _SymptomsScreenState extends State<SymptomsScreen> {
  final _records = <SymptomRecord>[];
  SymptomRecord? _cursor;
  int _request = 0;
  bool _loading = true;
  bool _hasMore = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = false;
      if (reset) {
        _records.clear();
        _cursor = null;
        _hasMore = false;
      }
    });
    try {
      final page = await widget.store.history(after: _cursor);
      if (!mounted || request != _request) return;
      setState(() {
        final known = _records.map((record) => record.id).toSet();
        _records.addAll(page.where((record) => known.add(record.id)));
        if (page.isNotEmpty) _cursor = page.last;
        _hasMore = page.length == SymptomRepository.pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<void> _openEditor([SymptomRecord? existing]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _SymptomEditor(
        existing: existing,
        store: widget.store,
        checkEmergency: widget.checkEmergency,
        callAmbulance: widget.callAmbulance,
      ),
    ));
    if (mounted && changed == true) await _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Symptoms'),
        actions: [
          IconButton(
            tooltip: 'Refresh symptom history',
            onPressed: _loading ? null : () => _load(reset: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          NovaButton(
              label: 'Log symptom', icon: Icons.add, onPressed: _openEditor),
          const SectionLabel('Symptom history'),
          if (_loading && _records.isEmpty) const SkeletonCard(lines: 3),
          if (!_loading && !_error && _records.isEmpty)
            const Text('No symptoms recorded yet.'),
          for (final record in _records)
            NovaCard(
              child: Material(
                type: MaterialType.transparency,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(record.name.isEmpty
                      ? 'Symptom type unknown'
                      : record.name),
                  subtitle: Text(
                      [
                        _formatOnset(context, record.onset),
                        '${record.severity?.label ?? 'Severity unknown'} · ${record.status?.label ?? 'Status unknown'}',
                        if (record.notes?.trim().isNotEmpty == true)
                          record.notes!,
                      ].join('\n'),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openEditor(record),
                ),
              ),
            ),
          if (_error)
            ErrorCard(
                message: 'Could not load symptom history.', onRetry: _load)
          else if (_hasMore)
            NovaButton(
              label: _loading ? 'Loading…' : 'Load older entries',
              kind: NovaButtonKind.secondary,
              onPressed: _loading ? null : _load,
            ),
        ],
      ),
    );
  }
}

String _formatOnset(BuildContext context, DateTime? onset) {
  if (onset == null) return 'Onset unknown';
  final time = onset.toLocal();
  final local = MaterialLocalizations.of(context);
  return '${local.formatCompactDate(time)} · ${local.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
}

class _SymptomEditor extends StatefulWidget {
  const _SymptomEditor({
    this.existing,
    required this.store,
    required this.checkEmergency,
    required this.callAmbulance,
  });

  final SymptomRecord? existing;
  final SymptomStore store;
  final Future<String?> Function(SymptomDraft) checkEmergency;
  final Future<bool> Function() callAmbulance;

  @override
  State<_SymptomEditor> createState() => _SymptomEditorState();
}

class _SymptomEditorState extends State<_SymptomEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late final _id = widget.existing?.id ?? newSymptomId();
  late DateTime? _onset = widget.existing == null
      ? DateTime.now()
      : widget.existing?.onset?.toLocal();
  late SymptomSeverity? _severity = widget.existing?.severity;
  late SymptomStatus? _status =
      widget.existing == null ? SymptomStatus.active : widget.existing?.status;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _chooseOnset() async {
    final now = DateTime.now();
    final previous = _onset ?? now;
    final first = DateTime(1900);
    final selectedDate = await showDatePicker(
      context: context,
      firstDate: previous.isBefore(first) ? previous : first,
      lastDate: now,
      initialDate: previous.isAfter(now) ? now : previous,
    );
    if (!mounted || selectedDate == null) return;
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(previous),
    );
    if (!mounted || selectedTime == null) return;
    final picked = DateTime(selectedDate.year, selectedDate.month,
        selectedDate.day, selectedTime.hour, selectedTime.minute);
    if (picked.hour != selectedTime.hour ||
        picked.minute != selectedTime.minute) {
      setState(() => _error =
          'That time is unavailable on this date. Choose another time.');
      return;
    }
    setState(() {
      _onset = picked;
      _error = null;
    });
  }

  Future<void> _call() async {
    try {
      if (await widget.callAmbulance()) return;
    } catch (_) {
      // Leave the emergency number visible if a dialer cannot open.
    }
    if (mounted) {
      showNovaToast(
          context, 'Could not open the dialer. Dial 1990 in Sri Lanka.');
    }
  }

  Future<bool> _review(SymptomDraft draft) async {
    if (!draft.needsSafetyCheck(DateTime.now())) return true;
    String? warning;
    try {
      warning = await widget.checkEmergency(draft);
    } catch (_) {
      warning =
          'NOVA could not check this entry. If this may be an emergency or you are unsure, call 1990 in Sri Lanka now.';
    }
    if (!mounted) return false;
    if (warning == null) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Symptom safety'),
            content: SingleChildScrollView(
                child: Text(
                    '$warning\n\nOutside Sri Lanka, call your local emergency number.')),
            actions: [
              FilledButton(
                  onPressed: _call, child: const Text('Call 1990 (Sri Lanka)')),
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Back')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Continue to save')),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    if (_busy) return;
    final name = _name.text.trim();
    final notes = _notes.text.trim();
    final onset = _onset;
    final status = _status;
    if (name.isEmpty ||
        name.runes.length > 120 ||
        notes.runes.length > 1000 ||
        onset == null ||
        onset.isAfter(DateTime.now()) ||
        status == null) {
      setState(() => _error =
          'Enter a symptom type, a past or current onset, and a status. Check the note length.');
      return;
    }
    final draft = SymptomDraft(
        name: name,
        notes: notes.isEmpty ? null : notes,
        onset: onset,
        severity: _severity,
        status: status);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _review(draft) || !mounted) return;
      await widget.store.save(draft, entryId: _id, existing: widget.existing);
      if (mounted) Navigator.pop(context, true);
    } on SymptomChangesException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not verify the save. Check symptom history or try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this symptom entry?'),
        content: const Text('This removes the entry from symptom history.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete entry')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.delete(widget.existing!);
      if (mounted) Navigator.pop(context, true);
    } on SymptomChangesException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Could not verify deletion. Check symptom history.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Scaffold(
      appBar: AppBar(
          title:
              Text(widget.existing == null ? 'Log symptom' : 'Edit symptom')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            readOnly: _busy,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Symptom type'),
          ),
          const Text('Severity'),
          DropdownButton<SymptomSeverity>(
            value: _severity,
            isExpanded: true,
            hint: const Text('Severity unknown'),
            items: [
              const DropdownMenuItem(child: Text('Severity unknown')),
              for (final severity in SymptomSeverity.values)
                DropdownMenuItem(value: severity, child: Text(severity.label)),
            ],
            onChanged:
                _busy ? null : (value) => setState(() => _severity = value),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Onset date and time'),
            subtitle: Text(_formatOnset(context, _onset)),
            trailing: const Icon(Icons.event_outlined),
            onTap: _busy ? null : _chooseOnset,
          ),
          const Text('Resolution status'),
          DropdownButton<SymptomStatus>(
            value: _status,
            hint: const Text('Choose status'),
            isExpanded: true,
            items: [
              for (final status in SymptomStatus.values)
                DropdownMenuItem(value: status, child: Text(status.label)),
            ],
            onChanged:
                _busy ? null : (value) => setState(() => _status = value),
          ),
          TextField(
            controller: _notes,
            readOnly: _busy,
            maxLength: 1000,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text(_error!, style: NovaType.body.copyWith(color: c.alert)),
          NovaButton(
              label: _busy ? 'Working…' : 'Save symptom',
              onPressed: _busy ? null : _save),
          if (widget.existing != null)
            NovaButton(
                label: 'Delete symptom',
                kind: NovaButtonKind.destructive,
                onPressed: _busy ? null : _delete),
          const SizedBox(height: 16),
          const Text(
              'If you need urgent help, call your local emergency number.'),
          TextButton(
              onPressed: _call, child: const Text('Call 1990 (Sri Lanka)')),
        ],
      ),
    );
  }
}
