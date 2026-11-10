import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'data/app_prefs.dart';
import 'data/care_models.dart';
import 'data/care_repository.dart';
import 'data/health_repository.dart';
import 'data/sample_data.dart';
import 'screens/assistant_screen.dart';
import 'screens/home_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/scan_camera_screen.dart';
import 'screens/track_screen.dart';
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

class _AppShellState extends State<AppShell> {
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

  @override
  void initState() {
    super.initState();
    HealthRepository.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    HealthRepository.changes.removeListener(_load);
    super.dispose();
  }

  /// Reloads today's data from Supabase (called after every log).
  Future<void> _load() async {
    final prefs = AppPrefs.instance;
    try {
      var data = await HealthRepository.instance.loadToday();
      data = data.copyWith(
        waterGoalL: prefs.waterGoalMl / 1000,
        sleepGoalMinutes: (prefs.sleepGoalHours * 60).round(),
      );
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
                    id: next.medication.id,
                    name: next.medication.name,
                    dose: next.medication.dosage ?? '',
                    time: formatClock(next.at),
                    overdue: next.state == DoseState.missed,
                  ),
            clearNextMedication: next == null,
          );
        }
      } catch (e) {
        debugPrint('Could not load today\'s doses: $e');
      }
      if (mounted) {
        setState(() {
          _snapshot = data;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      debugPrint('Could not load today\'s data: $e');
      if (mounted) {
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
