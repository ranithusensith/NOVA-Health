import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/reminder_service.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/states.dart';

void openReminders(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemindersScreen()));
}

/// Medicine reminders: on/off, lock-screen privacy, exact timing and a test button.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> with WidgetsBindingObserver {
  final _service = ReminderService.instance;
  bool _permission = false;
  bool _exact = false;
  int _pending = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from phone Settings: check the permissions again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final permission = await _service.permissionGranted();
    final exact = await _service.canScheduleExact();
    final pending = await _service.pendingCount();
    if (mounted) {
      setState(() {
        _permission = permission;
        _exact = exact;
        _pending = pending;
      });
    }
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    final now = await _service.setEnabled(value);
    if (value && !now && mounted) {
      showNovaToast(context, 'Notifications are blocked. Allow them for NOVA Health in your phone settings.');
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _test() async {
    final ok = await _service.sendTest();
    if (!mounted) return;
    showNovaToast(
      context,
      ok ? 'A test reminder will appear in about 5 seconds. You can leave the app to see it.' : 'Could not send a test. Check that notifications are allowed.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ListenableBuilder(
            listenable: _service,
            builder: (context, _) {
              final enabled = _service.enabled;
              return ListView(
                padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 40),
                children: [
                  Semantics(
                    header: true,
                    child: Text('Reminders', style: NovaType.largeTitle.copyWith(color: c.textPrimary)),
                  ),
                  const SizedBox(height: NovaSpace.gap),
                  NovaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            IconBadge(icon: CupertinoIcons.bell_fill, size: 44, foreground: c.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text('Medicine reminders',
                                  style: NovaType.headline.copyWith(color: c.textPrimary)),
                            ),
                            Semantics(
                              label: 'Medicine reminders',
                              toggled: enabled,
                              child: CupertinoSwitch(
                                value: enabled,
                                activeTrackColor: c.primary,
                                onChanged: _busy ? null : _toggle,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'NOVA schedules reminders within each medicine’s confirmed course dates. '
                          'Reminders are stored on this phone.',
                          style: NovaType.subhead.copyWith(color: c.textSecondary),
                        ),
                        if (enabled) ...[
                          const SizedBox(height: 10),
                          Text(
                            _permission
                                ? '$_pending ${_pending == 1 ? 'reminder is' : 'reminders are'} scheduled.'
                                : 'Notifications are blocked for NOVA Health. Turn them on in your phone Settings.',
                            style: NovaType.footnote.copyWith(color: _permission ? c.textPrimary : c.alert),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SectionLabel('Privacy'),
                  NovaCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Include medicine details',
                                  style: NovaType.headline.copyWith(color: c.textPrimary)),
                              const SizedBox(height: 2),
                              Text('Off by default. If enabled, names and doses may appear on your lock screen. '
                                  'Your phone controls notification previews.',
                                  style: NovaType.footnote.copyWith(color: c.textSecondary)),
                            ],
                          ),
                        ),
                        Semantics(
                          label: 'Include medicine names and doses in reminders',
                          toggled: _service.showNames,
                          child: CupertinoSwitch(
                            value: _service.showNames,
                            activeTrackColor: c.primary,
                            onChanged: (v) async {
                              await _service.setShowNames(v);
                              _refresh();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (Platform.isAndroid) ...[
                    const SectionLabel('Timing'),
                    NovaCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_exact ? 'Exact timing is on' : 'Timing may be a few minutes late',
                              style: NovaType.headline.copyWith(color: c.textPrimary)),
                          const SizedBox(height: 4),
                          Text(
                            _exact
                                ? 'Reminders arrive at the minute you set.'
                                : 'Android can delay reminders to save battery. Allow exact alarms for on-time reminders.',
                            style: NovaType.footnote.copyWith(color: c.textSecondary),
                          ),
                          if (!_exact) ...[
                            const SizedBox(height: 12),
                            NovaButton(
                              label: 'Allow exact alarms',
                              kind: NovaButtonKind.secondary,
                              onPressed: () async {
                                await _service.requestExactAlarms();
                                _refresh();
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: NovaSpace.gap),
                  NovaButton(
                    label: 'Send a test reminder',
                    kind: NovaButtonKind.secondary,
                    icon: CupertinoIcons.bell,
                    onPressed: _test,
                  ),
                  const SizedBox(height: NovaSpace.gap),
                  Text(
                    'NOVA schedules a limited number of reminders ahead. Open the app regularly and after '
                    'changing time zones to refresh them. Guidance, not medical advice.',
                    style: NovaType.footnote.copyWith(color: c.textSecondary),
                  ),
                ],
              );
            },
          ),
          Positioned(
            top: pad.top + 4,
            left: NovaSpace.margin,
            child: const GlassBackButton(label: 'Profile'),
          ),
        ],
      ),
    );
  }
}
