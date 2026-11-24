import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/emergency_service.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/floating_tab_bar.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import 'ai_privacy_screen.dart';
import 'emergency_screen.dart';

enum ChatKind { user, ai, error, typing }

class ChatItem {
  const ChatItem._(this.kind, [this.text = '', this.sources = const [], this.callForHelp = false]);
  factory ChatItem.user(String t) => ChatItem._(ChatKind.user, t);
  factory ChatItem.ai(String t, {List<String> sources = const [], bool callForHelp = false}) =>
      ChatItem._(ChatKind.ai, t, sources, callForHelp);
  factory ChatItem.error(String t) => ChatItem._(ChatKind.error, t);
  static const typing = ChatItem._(ChatKind.typing);

  final ChatKind kind;
  final String text;
  final List<String> sources;
  final bool callForHelp;
}

/// 06 AI Assistant — iMessage-style chat with suggestion chips and a floating
/// glass input bar. Replies come from POST /api/v1/assistant/chat
/// using ApiClient.chat.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, this.api, this.callNumber});

  final ApiClient? api;
  final Future<bool> Function(String)? callNumber;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  static const _greeting = 'Ask me to summarize the health records you choose to share.';
  static const _suggestions = ['Show my recent meal logs', 'How much water did I log today?', 'Summarise my sleep'];
  static const _transcriptLimit = 100;
  static const _preflightUnavailable =
      'NOVA could not check this message for an emergency. If anyone may be in immediate danger, call emergency services now.';

  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  late final _api = widget.api ?? ApiClient.instance;

  /// Increments on "New conversation" so late replies from an old chat are dropped.
  int _conversation = 0;
  bool _waiting = false;

  late List<ChatItem> _items = [ChatItem.ai(_greeting)];

  @override
  void initState() {
    super.initState();
    _api.aiConsentRevocations.addListener(_reset);
  }

  @override
  void dispose() {
    _api.aiConsentRevocations.removeListener(_reset);
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _waiting) return;
    final conversation = _conversation;
    final api = _api;
    final owner = api.aiAccountId;
    if (owner == null) return;
    bool current() => mounted && conversation == _conversation &&
        api.aiAccountId == owner;
    setState(() => _waiting = true);
    ChatItem? reply;
    try {
      final String? emergency;
      try {
        emergency = await api.checkAssistantEmergency(text);
      } catch (_) {
        // The user can get help without a network connection or AI consent.
        reply = ChatItem.ai(_preflightUnavailable, callForHelp: true);
        return;
      }
      if (!mounted || !current()) return;
      if (emergency != null) {
        _input.clear();
        setState(() => _items = [..._items, ChatItem.user(text)]);
        reply = ChatItem.ai(emergency, callForHelp: true);
        return;
      }
      if (!await ensureAiConsent(context, client: api) || !mounted || !current()) return;
      final sharing = await showDialog<AiChatShare>(
        context: context,
        builder: (_) => const AiChatReview(),
      );
      if (sharing == null || !current()) return;
      final previous = _items.where((item) => item.kind == ChatKind.user).toList();
      final recent = sharing.includeEarlierQuestions
          ? previous.skip(previous.length > 4 ? previous.length - 4 : 0)
              .map((item) => String.fromCharCodes(item.text.runes.take(400))).toList()
          : <String>[];
      _input.clear();
      setState(() {
        _items = [..._items, ChatItem.user(text), ChatItem.typing];
      });
      _scrollToEnd();
      final response = await api.chat(text, healthData: sharing.healthData, recentQuestions: recent);
      final replyText = response.text.trim();
      if (response.emergency) {
        reply = ChatItem.ai(replyText.isEmpty ? _preflightUnavailable : replyText,
            sources: response.sources, callForHelp: true);
      } else {
        reply = replyText.isEmpty
            ? ChatItem.error('No reply came back. Please try again.')
            : ChatItem.ai(replyText, sources: response.sources);
      }
    } on ApiException catch (e) {
      reply = ChatItem.error(e.message);
    } catch (_) {
      reply = ChatItem.error('Could not process this question. Please try again.');
    } finally {
      if (current()) {
        setState(() {
          _waiting = false;
          final items = [..._items.where((item) => item.kind != ChatKind.typing), if (reply != null) reply];
          _items = items.length > _transcriptLimit
              ? items.sublist(items.length - _transcriptLimit)
              : items;
        });
        if (reply != null) _scrollToEnd();
      }
    }
  }

  Future<void> _callAmbulance() async {
    final call = widget.callNumber ?? EmergencyService.instance.call;
    try {
      if (await call(ambulanceNumber)) return;
    } catch (_) {
      // Leave the dialable number visible when the phone cannot launch a dialer.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the dialer. Dial 1990 on a phone in Sri Lanka.')),
      );
    }
  }

  void _reset() {
    _input.clear();
    setState(() {
      _conversation++;
      _waiting = false;
      _items = [ChatItem.ai(_greeting)];
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final inputBottom = keyboard > 0 ? keyboard + 8 : novaTabBarBottom(context) + kNovaTabBarHeight + 12;
    const inputHeight = 52.0;
    const chipsHeight = 36.0;

    return ColoredBox(
      color: c.background,
      child: Stack(
        children: [
          ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 8, NovaSpace.margin, inputBottom + inputHeight + chipsHeight + 28),
            itemCount: _items.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(right: 60, bottom: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(header: true, child: Text('Assistant', style: NovaType.largeTitle.copyWith(color: c.textPrimary))),
                      const SizedBox(height: 2),
                      const DisclaimerNote(icon: true),
                      Text('NOVA checks for emergencies first. Google Gemini uses shared questions to choose which records to check.',
                          style: NovaType.caption.copyWith(color: c.textSecondary)),
                      TextButton(
                        onPressed: () => openEmergency(context),
                        child: const Text('Emergency help'),
                      ),
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _Bubble(item: _items[i - 1], onCall: _callAmbulance),
              );
            },
          ),
          // Scroll-edge fades instead of solid bars.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: pad.top + 12,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [c.background, c.background.withValues(alpha: 0)],
                    stops: const [0.55, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: inputBottom + inputHeight + chipsHeight + 60,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [c.background, c.background.withValues(alpha: 0)],
                    stops: const [0.4, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: pad.top + 4,
            right: NovaSpace.margin,
            child: GlassIconButton(icon: CupertinoIcons.plus, label: 'New conversation', iconSize: 22, onTap: _reset),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: inputBottom + inputHeight + 10,
            height: chipsHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: NovaSpace.margin),
              itemCount: _suggestions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => SuggestionChip(label: _suggestions[i], onTap: () => _send(_suggestions[i])),
            ),
          ),
          Positioned(
            left: NovaSpace.margin,
            right: NovaSpace.margin,
            bottom: inputBottom,
            child: Glass(
              height: inputHeight,
              padding: const EdgeInsets.fromLTRB(18, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      textInputAction: TextInputAction.send,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      onSubmitted: _send,
                      style: NovaType.body.copyWith(color: c.textPrimary),
                      cursorColor: c.primary,
                      decoration: InputDecoration.collapsed(
                        hintText: 'Ask about your health',
                        hintStyle: NovaType.body.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ),
                  Pressable(
                    onTap: () {},
                    semanticLabel: 'Dictate',
                    child: SizedBox(width: 44, height: 44, child: Icon(CupertinoIcons.mic, size: 22, color: c.textPrimary)),
                  ),
                  Pressable(
                    onTap: () => _send(_input.text),
                    semanticLabel: 'Send',
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: c.primary, shape: BoxShape.circle),
                      child: Icon(CupertinoIcons.arrow_up, size: 20, color: c.onPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.item, required this.onCall});
  final ChatItem item;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final fromUser = item.kind == ChatKind.user;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(22),
      topRight: const Radius.circular(22),
      bottomLeft: Radius.circular(fromUser ? 22 : 8),
      bottomRight: Radius.circular(fromUser ? 8 : 22),
    );

    final Widget content = switch (item.kind) {
      ChatKind.user => Text(item.text, style: NovaType.body.copyWith(color: c.onPrimary)),
      ChatKind.ai => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(item.text, style: NovaType.body.copyWith(color: c.textPrimary)),
          if (item.sources.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Sources: ${item.sources.join(', ')}',
                style: NovaType.caption.copyWith(color: c.textSecondary)),
          ],
          if (item.callForHelp) ...[
            const SizedBox(height: 8),
            FilledButton(onPressed: onCall, child: const Text('Call 1990 (Sri Lanka)')),
            Text('Outside Sri Lanka, call your local emergency number.',
                style: NovaType.caption.copyWith(color: c.textSecondary)),
          ],
        ],
      ),
      ChatKind.error => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(CupertinoIcons.exclamationmark_circle, size: 18, color: c.alert),
          const SizedBox(width: 8),
          Flexible(child: Text(item.text, style: NovaType.body.copyWith(color: c.textPrimary))),
        ],
      ),
      ChatKind.typing => const _TypingDots(),
    };

    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: fromUser ? 280 : 300),
        child: Semantics(
          label: fromUser ? 'You' : 'Assistant',
          child: Container(
            padding: item.kind == ChatKind.typing
                ? const EdgeInsets.symmetric(horizontal: 18, vertical: 14)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: fromUser ? c.primary : c.bubbleAi, borderRadius: radius),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.nova.textSecondary;
    return Semantics(
      label: 'Assistant is typing',
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_c.value - i * 0.2) % 1.0;
            final o = 0.35 + 0.65 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Opacity(
                opacity: o,
                child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              ),
            );
          }),
        ),
      ),
    );
  }
}
