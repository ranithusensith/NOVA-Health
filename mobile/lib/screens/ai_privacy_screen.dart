import 'package:flutter/material.dart';

import '../config.dart';
import '../services/api_client.dart';

const aiDisclosure =
    'Google Gemini, an external AI service, processes the health information '
    'you choose to share. For medical scans, NOVA reads the photo on its own '
    'server and sends only the text you review. For food scans, Gemini '
    'receives the reviewed photo after NOVA removes its metadata.\n\n'
    'The assistant shares your question. You can choose to include up to four earlier questions from '
    'this conversation or selected health records for '
    'a reply. NOVA removes common identifiers, but some may remain. Remove names, '
    'addresses, reference numbers and other identifying details before sharing.\n\n'
    'Google may retain requests and responses under its service terms. Turning '
    'off sharing blocks future AI requests. It cannot recall data already sent.';

Future<bool> ensureAiConsent(BuildContext context) async {
  if (AppConfig.useMockApi) return true;
  final api = ApiClient.instance;
  final owner = api.aiAccountId;
  final status = await api.aiPrivacyStatus();
  if (!context.mounted || owner == null || owner != api.aiAccountId) {
    return false;
  }
  if (status.allowed) return true;
  if (!status.providerAvailable) {
    throw ApiException('External AI is disabled on the server.');
  }
  if (!status.canReview) {
    throw ApiException('Update the app to review the current AI disclosure.');
  }
  final approved = await showDialog<bool>(
    context: context,
    builder: (_) => const AiConsentDialog(),
  );
  if (approved != true || !context.mounted || owner != api.aiAccountId) {
    return false;
  }
  await api.setAiConsent(true);
  return context.mounted && owner == api.aiAccountId;
}

class AiConsentDialog extends StatelessWidget {
  const AiConsentDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Share with Google Gemini?'),
        content: const SingleChildScrollView(child: Text(aiDisclosure)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep off')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable sharing')),
        ],
      );
}

class AiPrivacyScreen extends StatefulWidget {
  const AiPrivacyScreen({super.key});

  @override
  State<AiPrivacyScreen> createState() => _AiPrivacyScreenState();
}

class _AiPrivacyScreenState extends State<AiPrivacyScreen> {
  final _api = ApiClient.instance;
  AiPrivacyStatus? _status;
  bool _busy = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() => _do(() async {
        _status = await _api.aiPrivacyStatus();
      });

  Future<void> _do(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on ApiException catch (error) {
      _message = error.message;
    } catch (_) {
      _message = 'Could not verify this privacy setting. Try again.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setConsent(bool enabled) async {
    final owner = _api.aiAccountId;
    if (enabled &&
        await showDialog<bool>(
                context: context, builder: (_) => const AiConsentDialog()) !=
            true) {
      return;
    }
    if (!mounted || owner == null || owner != _api.aiAccountId) return;
    await _do(() async {
      await _api.setAiConsent(enabled);
      final previous = _status!;
      _status = AiPrivacyStatus(
          enabled: enabled,
          providerAvailable: previous.providerAvailable,
          version: previous.version);
      _message =
          enabled ? 'Gemini sharing is enabled.' : 'Gemini sharing is off.';
    });
  }

  Future<void> _deleteChats() async {
    final owner = _api.aiAccountId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete older chats?'),
        content: const Text(
          'This permanently removes the older chat records from your active NOVA account. '
          'Copies held by Google or in backups follow their separate retention policies.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete older chats')),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        owner == null ||
        owner != _api.aiAccountId) {
      return;
    }
    await _do(() async {
      final count = await _api.deleteLegacyAiChats();
      _message = count == 0
          ? 'No older chat records were found.'
          : 'Older chat records deleted from your active NOVA account.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy and consent')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('External AI processing',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(aiDisclosure),
          const SizedBox(height: 12),
          const Text(
            'Daily reports and prescription safety checks run in NOVA. '
            'NOVA keeps new assistant chats in this screen only. Use New conversation to clear it. '
            'Confirmed scan results are saved to your health records.',
          ),
          const SizedBox(height: 12),
          if (status != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow Google Gemini processing'),
              value: status.enabled,
              subtitle: Text(status.providerAvailable
                  ? (status.canReview
                      ? 'Optional for your account'
                      : 'App update required to enable sharing')
                  : 'External AI is disabled on the server'),
              onChanged: _busy || (!status.enabled && !status.canReview)
                  ? null
                  : _setConsent,
            )
          else if (!_busy)
            OutlinedButton(
                onPressed: _refresh,
                child: const Text('Retry loading AI settings')),
          if (!AppConfig.useMockApi)
            OutlinedButton(
                onPressed: _busy ? null : _deleteChats,
                child: const Text('Delete older NOVA chats')),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(liveRegion: true, child: Text(_message!)),
            ),
        ],
      ),
    );
  }
}

class AiChatShare {
  const AiChatShare(
      {this.includeEarlierQuestions = false, this.healthData = const []});

  final bool includeEarlierQuestions;
  final List<String> healthData;
}

class AiChatReview extends StatefulWidget {
  const AiChatReview({super.key});

  @override
  State<AiChatReview> createState() => _AiChatReviewState();
}

class _AiChatReviewState extends State<AiChatReview> {
  final _selected = <String>{};
  bool _includeEarlierQuestions = false;
  static const _categories = {
    'logs': 'Water, sleep, mood, meals and symptoms',
    'medications': 'Medications, allergies and safety warnings',
    'lab_results': 'Lab results',
    'profile': 'Health profile',
    'heart_rate': 'Heart rate',
    'cycle': 'Menstrual cycle',
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Share this question?'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Google Gemini will process your question. Go back to remove any identifying details before sharing.',
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              dense: true,
              value: _includeEarlierQuestions,
              contentPadding: EdgeInsets.zero,
              onChanged: (value) =>
                  setState(() => _includeEarlierQuestions = value == true),
              title: const Text('Include up to four earlier questions'),
            ),
            const Text('Optional health records for this reply'),
            for (final category in _categories.entries)
              CheckboxListTile(
                dense: true,
                value: _selected.contains(category.key),
                contentPadding: EdgeInsets.zero,
                onChanged: (value) => setState(() {
                  if (value == true) {
                    _selected.add(category.key);
                  } else {
                    _selected.remove(category.key);
                  }
                }),
                title: Text(category.value),
              ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go back')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              AiChatShare(
                  includeEarlierQuestions: _includeEarlierQuestions,
                  healthData: _selected.toList()),
            ),
            child: const Text('Share question'),
          ),
        ],
      );
}
