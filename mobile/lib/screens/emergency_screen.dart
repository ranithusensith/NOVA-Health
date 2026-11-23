import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/care_models.dart';
import '../services/api_client.dart';
import '../services/emergency_service.dart';
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

enum _ComposerState { idle, opening, opened, failed }

/// Hold SOS to request an alert. Provider delivery and manual SMS stay separate.
class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key, this.service});

  final EmergencyService? service;

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> with SingleTickerProviderStateMixin {
  late final _service = widget.service ?? EmergencyService.instance;
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))..addStatusListener(_onHoldStatus);
  late final String? _owner = _service.accountId;
  late final StreamSubscription<String?> _accountSubscription;

  List<EmergencyContact>? _contacts;
  int _contactsLoad = 0;
  bool _contactsLoading = true;
  bool _usingSaved = false;
  bool _sessionChanged = false;
  bool _confirming = false;
  bool _sending = false;
  bool _checking = false;
  bool _statusUnavailable = false;
  EmergencyResult? _result;
  Timer? _poll;
  _ComposerState _composer = _ComposerState.idle;

  bool get _sameAccount => mounted && !_sessionChanged && _service.accountId == _owner;

  @override
  void initState() {
    super.initState();
    _accountSubscription = _service.accountChanges.listen((owner) {
      if (owner == _owner || !mounted) return;
      _poll?.cancel();
      setState(() {
        _sessionChanged = true;
        _contacts = null;
        _contactsLoading = false;
        _result = null;
        _sending = false;
        _composer = _ComposerState.idle;
      });
    }, onError: (Object _) {});
    _reloadContacts();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _accountSubscription.cancel();
    _hold.dispose();
    super.dispose();
  }

  Future<void> _reloadContacts() async {
    if (!_sameAccount) return;
    final load = ++_contactsLoad;
    setState(() => _contactsLoading = true);
    var online = false;
    unawaited(_service.cachedContacts().then((saved) {
      if (_sameAccount && load == _contactsLoad && !online && saved != null) {
        setState(() {
          _contacts ??= saved;
          _usingSaved = true;
        });
      }
    }).catchError((Object _) {}));
    try {
      final contacts = await _service.refreshContacts();
      if (!_sameAccount || load != _contactsLoad || contacts == null) return;
      online = true;
      setState(() {
        _contacts = contacts;
        _usingSaved = false;
      });
    } catch (_) {
      if (_sameAccount && load == _contactsLoad) setState(() => _usingSaved = _contacts != null);
    } finally {
      if (_sameAccount && load == _contactsLoad) setState(() => _contactsLoading = false);
    }
  }

  void _onHoldStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      HapticFeedback.heavyImpact();
      _hold.reset();
      _confirmAndSend();
    }
  }

  Future<void> _call(String phone) async {
    try {
      if (await _service.call(phone)) return;
    } catch (_) {
      // Keep the number on screen when the platform cannot launch its dialer.
    }
    if (mounted) showNovaToast(context, 'Could not open the dialer. Use your phone to call directly.');
  }

  Future<void> _confirmAndSend() async {
    if (!_sameAccount || _confirming || _sending) return;
    if (_contacts?.isEmpty == true && !_usingSaved && !_contactsLoading) {
      setState(() => _result = const EmergencyResult(status: SosDeliveryState.noContacts));
      return;
    }
    _confirming = true;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Send SOS?'),
        content: const Text('Request an alert for your emergency contacts. Call 1990 if you need urgent help.'),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Send SOS')),
        ],
      ),
    );
    _confirming = false;
    if (ok != true || !_sameAccount) return;
    _poll?.cancel();
    setState(() {
      _sending = true;
      _statusUnavailable = false;
      _composer = _ComposerState.idle;
    });
    try {
      final result = await _service.trigger();
      if (!_sameAccount) return;
      setState(() => _result = result);
      if (result.canRefresh && result.attemptId != null) {
        _poll = Timer.periodic(const Duration(seconds: 10), (timer) {
          if (timer.tick >= 12) timer.cancel();
          _checkStatus();
        });
      }
    } catch (_) {
      if (_sameAccount) setState(() => _result = const EmergencyResult(status: SosDeliveryState.unknown));
    } finally {
      if (_sameAccount) setState(() => _sending = false);
    }
  }

  Future<void> _checkStatus() async {
    final attempt = _result?.attemptId;
    if (!_sameAccount || attempt == null || _checking) return;
    setState(() => _checking = true);
    try {
      final result = await _service.checkStatus(attempt);
      if (!_sameAccount || _result?.attemptId != attempt) return;
      if (!result.canRefresh) _poll?.cancel();
      setState(() {
        _result = result;
        _statusUnavailable = result.statusCheckUnavailable;
      });
    } catch (_) {
      if (_sameAccount && _result?.attemptId == attempt) {
        setState(() => _statusUnavailable = true);
      }
    } finally {
      if (_sameAccount) setState(() => _checking = false);
    }
  }

  List<EmergencyContact> get _manualRecipients {
    if (_sending || _sessionChanged) return const [];
    final result = _result;
    final contacts = _contacts ?? const <EmergencyContact>[];
    if (result?.status == SosDeliveryState.noContacts) return const [];
    if (result == null || result.recipients.isEmpty) {
      return [
        for (final contact in contacts)
          if (EmergencyService.smsNumber(contact.phone) != null) contact,
      ];
    }
    return [
      for (final contact in contacts)
        if ((result.recipients[contact.id] == SosDeliveryState.manualRequired ||
                result.recipients[contact.id] == SosDeliveryState.failed ||
                result.recipients[contact.id] == SosDeliveryState.unknown) &&
            EmergencyService.smsNumber(contact.phone) != null)
          contact,
    ];
  }

  Future<void> _openMessages() async {
    if (!_sameAccount || _composer == _ComposerState.opening) return;
    final candidates = _manualRecipients;
    final duplicatePossible = _result?.status == SosDeliveryState.unknown ||
        candidates.any((contact) => _result?.recipients[contact.id] == SosDeliveryState.unknown);
    final contact = await showCupertinoModalPopup<EmergencyContact>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Choose a contact to text'),
        message: Text(duplicatePossible
            ? 'NOVA could not verify the earlier request. A duplicate alert is possible. The message still needs your approval.'
            : 'Your messaging app will ask you to send the text.'),
        actions: [
          for (final contact in candidates)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, contact),
              child: Text(contact.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (contact == null || !_sameAccount || !_manualRecipients.any((item) => item.id == contact.id)) return;
    setState(() => _composer = _ComposerState.opening);
    var opened = false;
    try {
      opened = await _service.openMessages(contact).timeout(const Duration(seconds: 5));
    } catch (_) {
      // An unavailable composer is displayed beside the call fallback.
    }
    if (_sameAccount) setState(() => _composer = opened ? _ComposerState.opened : _ComposerState.failed);
  }

  Future<void> _addContact() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ContactEditor(service: _service),
    );
    if (added == true && mounted) _reloadContacts();
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
      await _service.deleteContact(contact.id);
      if (!_sameAccount) return;
      setState(() => _contacts = _contacts?.where((item) => item.id != contact.id).toList());
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
                const SizedBox(height: 20),
                NovaButton(
                  label: 'Call 1990 ambulance',
                  kind: NovaButtonKind.destructive,
                  icon: CupertinoIcons.phone_fill,
                  onPressed: () => _call(ambulanceNumber),
                ),
                const SizedBox(height: 20),
                Center(child: _buildSos(context)),
                if (_manualRecipients.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  NovaButton(
                    label: _composer == _ComposerState.opening ? 'Opening Messages…' : 'Open Messages',
                    kind: NovaButtonKind.secondary,
                    onPressed: _composer == _ComposerState.opening ? null : _openMessages,
                  ),
                ],
                if (_composer == _ComposerState.opened || _composer == _ComposerState.failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _composer == _ComposerState.opened
                            ? 'Manual sending required. Press Send in your messaging app. NOVA cannot confirm delivery.'
                            : 'Could not open the SMS composer. Call 1990 or your contact directly.',
                        style: NovaType.subhead.copyWith(color: c.textPrimary),
                      ),
                    ),
                  ),
                SectionLabel(
                  'Emergency contacts',
                  trailing: _sessionChanged ? null : Pressable(
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
                _buildContacts(context),
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

  Widget _buildContacts(BuildContext context) {
    final c = context.nova;
    final contacts = _contacts;
    if (_sessionChanged) return const Text('Sign in again to access your emergency contacts.');
    if (contacts == null) {
      if (_contactsLoading) return const SkeletonCard(lines: 2);
      return ErrorCard(
        message: 'Contacts are unavailable and none are saved on this device. You can still call 1990.',
        onRetry: _reloadContacts,
      );
    }
    if (contacts.isEmpty) {
      return EmptyStateCard(
        icon: CupertinoIcons.person_2,
        title: _usingSaved ? 'No emergency contacts saved on this device' : 'No emergency contacts yet',
        body: _usingSaved
            ? 'Connect to load your contacts. You can still call 1990.'
            : 'Add a contact to use SOS messaging. You can still call 1990.',
        actionLabel: _usingSaved ? 'Retry' : 'Add a contact',
        onAction: _usingSaved ? _reloadContacts : _addContact,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_usingSaved) ...[
          Text('Showing emergency contacts saved on this device.', style: NovaType.subhead.copyWith(color: c.textSecondary)),
          const SizedBox(height: 8),
        ],
        NovaCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < contacts.length; i++) ...[
                if (i > 0) Divider(height: 0.5, thickness: 0.5, color: c.separator, indent: 64),
                _ContactRow(
                  contact: contacts[i],
                  delivery: _result?.recipients[contacts[i].id],
                  onCall: () => _call(contacts[i].phone),
                  onDelete: () => _deleteContact(contacts[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSos(BuildContext context) {
    final c = context.nova;
    if (_sending) {
      return const _SosStatus(
        icon: CupertinoActivityIndicator(radius: 16),
        title: 'Requesting SOS…',
        body: 'You can call 1990 while NOVA checks the request.',
      );
    }
    final result = _result;
    if (_sessionChanged) return const Text('Sign in again to request an SOS.');
    if (result == null) return _HoldButton(controller: _hold);

    final (title, description) = switch (result.status) {
      SosDeliveryState.simulated => ('Simulation mode', 'NOVA did not send a real SMS. Open Messages to send a text yourself.'),
      SosDeliveryState.manualRequired => ('Manual sending required', 'Open Messages and press Send yourself.'),
      SosDeliveryState.queued => ('SOS queued', 'The provider accepted or is processing the request. Delivery is unconfirmed.'),
      SosDeliveryState.sent => ('SOS sent to the carrier', 'The provider reports sending it. Delivery is unconfirmed.'),
      SosDeliveryState.delivered => ('SOS delivered', 'The provider confirmed delivery to every recipient.'),
      SosDeliveryState.partialFailure => ('Some SOS alerts failed', 'Check the recipient statuses. Call or manually text the contacts whose alerts failed.'),
      SosDeliveryState.failed => ('SOS failed', 'The automated alert failed. Call 1990 or contact someone directly.'),
      SosDeliveryState.noContacts => ('No emergency contacts', 'No contact was alerted. Call 1990 or add a contact.'),
      SosDeliveryState.unknown => ('SOS status unknown', 'NOVA could not verify the request. Call 1990 or contact someone directly.'),
    };
    final counts = [
      for (final (state, label) in [
        (SosDeliveryState.delivered, 'delivered'),
        (SosDeliveryState.sent, 'sent to carrier'),
        (SosDeliveryState.queued, 'queued'),
        (SosDeliveryState.failed, 'failed'),
        (SosDeliveryState.unknown, 'unverified'),
        (SosDeliveryState.manualRequired, 'manual sending required'),
      ])
        if (result.count(state) > 0) '${result.count(state)} $label',
    ];
    final delivered = result.status == SosDeliveryState.delivered;
    return Semantics(
      liveRegion: true,
      child: _SosStatus(
        icon: Icon(
          delivered ? CupertinoIcons.checkmark_seal_fill : CupertinoIcons.info_circle,
          size: 48,
          color: delivered ? c.success : c.alert,
        ),
        title: title,
        body: [
          description,
          if (counts.isNotEmpty) counts.join(' · '),
          if (_statusUnavailable) 'Delivery status could not be refreshed. The last known status is shown.',
        ].join('\n'),
        action: Column(
          children: [
            if (result.canRefresh && result.attemptId != null)
              NovaButton(
                label: _checking ? 'Checking delivery…' : 'Check delivery status',
                kind: NovaButtonKind.secondary,
                onPressed: _checking ? null : _checkStatus,
              ),
            NovaButton(
              label: 'Back to SOS',
              kind: NovaButtonKind.plain,
              onPressed: () {
                _poll?.cancel();
                setState(() {
                  _result = null;
                  _composer = _ComposerState.idle;
                });
              },
            ),
          ],
        ),
      ),
    );
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
  const _ContactRow({required this.contact, required this.delivery, required this.onCall, required this.onDelete});
  final EmergencyContact contact;
  final SosDeliveryState? delivery;
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
                if (delivery != null)
                  Text(
                    switch (delivery!) {
                      SosDeliveryState.delivered => 'Delivery confirmed',
                      SosDeliveryState.sent => 'Sent to carrier · delivery unconfirmed',
                      SosDeliveryState.queued => 'Queued',
                      SosDeliveryState.failed => 'Alert failed',
                      SosDeliveryState.manualRequired => 'Manual sending required',
                      _ => 'Status unverified',
                    },
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
  const _ContactEditor({required this.service});

  final EmergencyService service;

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
    if (name.isEmpty || EmergencyService.smsNumber(phone) == null) {
      setState(() => _error = 'Enter a name and a valid phone number.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await widget.service.addContact(name: name, phone: phone, relationship: _relationship.text.trim());
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
