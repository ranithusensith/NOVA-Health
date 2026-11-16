import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/care_models.dart';
import '../data/care_repository.dart';
import '../data/sample_data.dart';
import '../services/api_client.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import '../widgets/scroll_edge_fade.dart';
import '../widgets/states.dart';

void openEmergency(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EmergencyScreen()));
}

/// Sri Lanka's free 24-hour ambulance service (Suwa Seriya).
const ambulanceNumber = '1990';

Future<void> callNumber(BuildContext context, String phone) async {
  final cleaned = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  final ok = await launchUrl(Uri(scheme: 'tel', path: cleaned));
  if (!ok && context.mounted) showNovaToast(context, 'Calling is not available on this device.');
}

enum _SosPhase { idle, sending, sent, failed }

/// 08 Emergency — hold the SOS button for 3 seconds, confirm, and NOVA alerts
/// your emergency contacts (POST /api/v1/emergency/trigger).
class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))..addStatusListener(_onHoldStatus);
  late Future<List<EmergencyContact>> _contacts = CareRepository.instance.emergencyContacts();

  _SosPhase _phase = _SosPhase.idle;
  DateTime? _sentAt;
  int _notified = 0;
  String? _failure;

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _reloadContacts() => setState(() => _contacts = CareRepository.instance.emergencyContacts());

  void _onHoldStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      HapticFeedback.heavyImpact();
      _hold.reset();
      _confirmAndSend();
    }
  }

  Future<void> _confirmAndSend() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Send SOS?'),
        content: const Text('NOVA will alert your emergency contacts now. In a life-threatening emergency, also call 1990.'),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Send SOS')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _phase = _SosPhase.sending;
      _failure = null;
    });
    try {
      final count = await ApiClient.instance.triggerEmergency();
      if (!mounted) return;
      setState(() {
        _phase = _SosPhase.sent;
        _sentAt = DateTime.now();
        _notified = count;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _SosPhase.failed;
        _failure = e is ApiException ? e.message : friendlyError(e);
      });
    }
  }

  Future<void> _addContact() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ContactEditor(),
    );
    if (added == true) _reloadContacts();
  }

  Future<void> _deleteContact(EmergencyContact contact) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Remove ${contact.name}?'),
        content: const Text('They will no longer be alerted when you send an SOS.'),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CareRepository.instance.deleteEmergencyContact(contact.id);
      _reloadContacts();
    } catch (e) {
      if (mounted) showNovaToast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ScrollEdgeFade(
            child: ListView(
              padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 40),
              children: [
                Semantics(header: true, child: Text('Emergency', style: NovaType.largeTitle.copyWith(color: c.textPrimary))),
                const SizedBox(height: 2),
                Text('Hold the button for 3 seconds to alert your contacts.', style: NovaType.subhead.copyWith(color: c.textSecondary)),
                const SizedBox(height: 28),
                Center(child: _buildSos(context)),
                const SizedBox(height: 28),
                NovaButton(
                  label: 'Call 1990 ambulance',
                  kind: NovaButtonKind.destructive,
                  icon: CupertinoIcons.phone_fill,
                  onPressed: () => callNumber(context, ambulanceNumber),
                ),
                SectionLabel(
                  'Emergency contacts',
                  trailing: Pressable(
                    onTap: _addContact,
                    semanticLabel: 'Add emergency contact',
                    child: SizedBox(
                      height: 44,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(CupertinoIcons.plus, size: 18, color: c.primary),
                        const SizedBox(width: 4),
                        Text('Add', style: NovaType.headline.copyWith(color: c.primary)),
                      ]),
                    ),
                  ),
                ),
                FutureBuilder<List<EmergencyContact>>(
                  future: _contacts,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) return const SkeletonCard(lines: 2);
                    if (snap.hasError) return ErrorCard(message: friendlyError(snap.error!), onRetry: _reloadContacts);
                    final contacts = snap.data!;
                    if (contacts.isEmpty) {
                      return EmptyStateCard(
                        icon: CupertinoIcons.person_2,
                        title: 'No emergency contacts yet',
                        body: 'Add a family member or friend. They are the people NOVA alerts when you send an SOS.',
                        actionLabel: 'Add a contact',
                        onAction: _addContact,
                      );
                    }
                    return NovaCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < contacts.length; i++) ...[
                            if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator, indent: 64),
                            _ContactRow(
                              contact: contacts[i],
                              onCall: () => callNumber(context, contacts[i].phone),
                              onDelete: () => _deleteContact(contacts[i]),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: NovaSpace.gap),
                Text(
                  'NOVA is not an emergency service. If you are in danger, call 1990 (ambulance) or 119 (police) straight away.',
                  textAlign: TextAlign.center,
                  style: NovaType.footnote.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          Positioned(top: pad.top + 4, left: NovaSpace.margin, child: const GlassBackButton(label: 'Back')),
        ],
      ),
    );
  }

  Widget _buildSos(BuildContext context) {
    final c = context.nova;
    switch (_phase) {
      case _SosPhase.sending:
        return _SosStatus(
          icon: const CupertinoActivityIndicator(radius: 16),
          title: 'Sending SOS…',
          body: 'Alerting your emergency contacts.',
        );
      case _SosPhase.sent:
        return _SosStatus(
          icon: Icon(CupertinoIcons.checkmark_seal_fill, size: 56, color: c.success),
          title: 'SOS sent',
          body: '${_notified == 0 ? 'Your request was received' : '$_notified contact${_notified == 1 ? '' : 's'} notified'}'
              ' at ${formatClock(_sentAt!)}.\nStay where you are if it is safe.',
          action: NovaButton(
            label: 'I\'m safe now',
            kind: NovaButtonKind.secondary,
            onPressed: () => setState(() => _phase = _SosPhase.idle),
          ),
        );
      case _SosPhase.failed:
        return _SosStatus(
          icon: Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 52, color: c.alert),
          title: 'SOS could not be sent',
          body: '${_failure ?? 'Something went wrong.'}\nCall 1990 or one of your contacts directly.',
          action: NovaButton(label: 'Try again', onPressed: _confirmAndSend),
        );
      case _SosPhase.idle:
        return _HoldButton(controller: _hold);
    }
  }
}

/// Large, solid (not glass) SOS button with a progress ring that fills while held.
class _HoldButton extends StatelessWidget {
  const _HoldButton({required this.controller});
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Semantics(
      button: true,
      label: 'SOS. Press and hold for 3 seconds to alert your emergency contacts.',
      onLongPress: controller.forward,
      child: GestureDetector(
        onTapDown: (_) => controller.forward(),
        onTapUp: (_) {
          if (controller.status != AnimationStatus.completed) controller.reverse();
        },
        onTapCancel: () {
          if (controller.status != AnimationStatus.completed) controller.reverse();
        },
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, __) => SizedBox(
            width: 220,
            height: 220,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 220,
                  height: 220,
                  child: CircularProgressIndicator(
                    value: controller.value,
                    strokeWidth: 8,
                    color: c.sos,
                    backgroundColor: c.sos.withValues(alpha: 0.15),
                    strokeCap: StrokeCap.round,
                  ),
                ),
                Container(
                  width: 184,
                  height: 184,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.sos,
                    boxShadow: [BoxShadow(color: c.sos.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 10))],
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('SOS', style: TextStyle(fontSize: 44, fontWeight: FontWeight.w800, letterSpacing: 2, color: Colors.white)),
                      const SizedBox(height: 4),
                      Text(
                        controller.value == 0 ? 'Hold for 3 seconds' : 'Keep holding…',
                        style: NovaType.footnote.copyWith(fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SosStatus extends StatelessWidget {
  const _SosStatus({required this.icon, required this.title, required this.body, this.action});
  final Widget icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    return Semantics(
      liveRegion: true,
      child: NovaCard(
        child: Column(
          children: [
            const SizedBox(height: 8),
            icon,
            const SizedBox(height: 12),
            Text(title, style: NovaType.title2.copyWith(color: c.textPrimary)),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center, style: NovaType.subhead.copyWith(color: c.textSecondary)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.contact, required this.onCall, required this.onDelete});
  final EmergencyContact contact;
  final VoidCallback onCall;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final initial = contact.name.isEmpty ? '?' : contact.name.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.primaryTint, shape: BoxShape.circle),
            child: Text(initial, style: NovaType.headline.copyWith(color: c.primary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.name, style: NovaType.headline.copyWith(color: c.textPrimary)),
                Text(
                  [if (contact.relationship != null) contact.relationship!, contact.phone].join(' · '),
                  style: NovaType.footnote.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onDelete,
            tooltip: 'Remove ${contact.name}',
            icon: Icon(CupertinoIcons.trash, size: 20, color: c.textSecondary),
          ),
          IconButton.filledTonal(
            onPressed: onCall,
            tooltip: 'Call ${contact.name}',
            style: IconButton.styleFrom(backgroundColor: c.primaryTint, foregroundColor: c.primary),
            icon: const Icon(CupertinoIcons.phone_fill, size: 20),
          ),
        ],
      ),
    );
  }
}

class _ContactEditor extends StatefulWidget {
  const _ContactEditor();

  @override
  State<_ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<_ContactEditor> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _relationship = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relationship.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty || phone.replaceAll(RegExp(r'[^0-9]'), '').length < 7) {
      setState(() => _error = 'Enter a name and a valid phone number.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await CareRepository.instance.addEmergencyContact(name: name, phone: phone, relationship: _relationship.text.trim());
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final style = NovaType.body.copyWith(color: c.textPrimary);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 8, keyboard + 8),
      child: Glass(
        radius: NovaRadius.sheet,
        fillOpacity: 0.94,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(color: c.textSecondary.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 14),
            Text('Add emergency contact', style: NovaType.title2.copyWith(color: c.textPrimary)),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: style,
              decoration: novaFieldDecoration(c, 'Name', icon: CupertinoIcons.person),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              style: style,
              decoration: novaFieldDecoration(c, 'Phone number', icon: CupertinoIcons.phone),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _relationship,
              textCapitalization: TextCapitalization.sentences,
              style: style,
              decoration: novaFieldDecoration(c, 'Relationship (optional)', icon: CupertinoIcons.heart),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: NovaType.footnote.copyWith(color: c.alert)),
            ],
            const SizedBox(height: 18),
            NovaButton(label: _saving ? 'Saving…' : 'Save contact', onPressed: _saving ? null : _save),
          ],
        ),
      ),
    );
  }
}
