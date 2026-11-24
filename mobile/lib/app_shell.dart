import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'data/care_models.dart';
import 'data/care_repository.dart';
import 'data/health_repository.dart';
import 'data/sample_data.dart';
import 'screens/assistant_screen.dart';
import 'screens/home_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/scan_camera_screen.dart';
import 'screens/track_screen.dart';
import 'services/privacy_diagnostics.dart';
import 'theme/nova_theme.dart';
import 'widgets/floating_tab_bar.dart';
import 'widgets/states.dart';

/// Shown on Home until real data has loaded.
const _loadingSnapshot = HealthSnapshot(firstName: 'there', isEmpty: true);

/// Root shell: 4 tabs (Home, Track, Assistant, Profile) on a floating glass
/// tab bar, plus the separate tinted Scan button.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const _tabs = [
    NovaTab('Home', CupertinoIcons.house, CupertinoIcons.house_fill),
    NovaTab('Track', CupertinoIcons.chart_bar, CupertinoIcons.chart_bar_fill),
    NovaTab('Assistant', Icons.auto_awesome_outlined, Icons.auto_awesome),
    NovaTab('Profile', CupertinoIcons.person, CupertinoIcons.person_fill),
  ];

  int _index = 0;
  bool _minimised = false;
  HealthSnapshot _snapshot = _loadingSnapshot;
  bool _loading = true;
  String? _error;
  int _loadVersion = 0;
  late final Timer _doseCalendarTimer;
  late ({String day, Duration offset}) _doseDay;

  ({String day, Duration offset}) _localDoseDay() {
    final now = DateTime.now();
    return (day: ymd(now), offset: now.timeZoneOffset);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HealthRepository.changes.addListener(_load);
    _doseDay = _localDoseDay();
    _doseCalendarTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final current = _localDoseDay();
      if (current == _doseDay) return;
      _doseDay = current;
      HealthRepository.notifyChanged();
    });
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _doseCalendarTimer.cancel();
    HealthRepository.changes.removeListener(_load);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _doseDay = _localDoseDay();
      _load();
    }
  }

  /// Reloads today's data from Supabase (called after every log).
  Future<void> _load() async {
    final version = ++_loadVersion;
    try {
      var data = await HealthRepository.instance.loadToday();
      // Today's dose timeline (taken / due / missed) from medication_logs.
      try {
        final slots = await CareRepository.instance.todaySchedule();
        if (slots.isNotEmpty) {
          final next = nextDose(slots);
          data = data.copyWith(
            medsToday: slots.length,
            medsTakenToday: slots.where((s) => s.state == DoseState.taken).length,
            nextMedication: next == null
                ? null
                : Medication(
                    occurrence: next.occurrence,
                    name: next.medication.name,
                    dose: next.medication.dosage ?? '',
                    time: formatDoseClock(next),
                    overdue: next.state == DoseState.missed,
                  ),
            clearNextMedication: next == null,
          );
        }
      } catch (_) {
        logAppEvent('Could not load today\'s doses');
      }
      if (mounted && version == _loadVersion) {
        setState(() {
          _snapshot = data;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      logAppEvent('Could not load today\'s data');
      if (mounted && version == _loadVersion) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  void _select(int i) {
    setState(() {
      _index = i;
      _minimised = false;
    });
    if (i == 0) _load();
  }

  void _openScan() {
    Navigator.of(context).push(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ScanCameraScreen()),
    );
  }

  bool _onScroll(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.direction == ScrollDirection.reverse && !_minimised) {
      setState(() => _minimised = true);
    } else if (n.direction == ScrollDirection.forward && _minimised) {
      setState(() => _minimised = false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      backgroundColor: context.nova.background,
      resizeToAvoidBottomInset: false,
      body: NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          children: [
            IndexedStack(
              index: _index,
              children: [
                HomeScreen(
                  data: _snapshot,
                  loading: _loading,
                  error: _error,
                  onRetry: () {
                    setState(() => _loading = _error != null);
                    _load();
                  },
                  onOpenTrack: () => _select(1),
                ),
                TrackScreen(onLogged: _load),
                const AssistantScreen(),
                const ProfileScreen(),
              ],
            ),
            if (!keyboardOpen)
              Positioned(
                left: NovaSpace.margin,
                right: NovaSpace.margin,
                bottom: novaTabBarBottom(context),
                child: Row(
                  children: [
                    FloatingTabBar(
                      tabs: _tabs,
                      index: _index,
                      minimised: _minimised,
                      onSelect: _select,
                      onExpand: () => setState(() => _minimised = false),
                    ),
                    const Spacer(),
                    ScanButton(onTap: _openScan),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
