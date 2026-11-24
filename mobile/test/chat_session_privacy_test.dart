import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/auth_gate.dart';
import 'package:nova_health/data/app_prefs.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/assistant_screen.dart';
import 'package:nova_health/services/api_client.dart';
import 'package:nova_health/services/privacy_diagnostics.dart';
import 'package:nova_health/theme/nova_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ChatApi implements ApiClient {
  @override
  String? aiAccountId = 'synthetic-first-account';
  @override
  final ValueNotifier<int> aiConsentRevocations = ValueNotifier<int>(0);
  final history = <List<String>>[];
  Completer<AssistantReply>? pending;
  AssistantReply reply = const AssistantReply('Synthetic reply');
  Object? preflightFailure;
  String? preflightReply;
  int consentChecks = 0;

  @override
  Future<String?> checkAssistantEmergency(String message) async {
    if (preflightFailure case final failure?) throw failure;
    return preflightReply;
  }

  @override
  Future<AiPrivacyStatus> aiPrivacyStatus() async {
    consentChecks++;
    return const AiPrivacyStatus(
      enabled: true,
      providerAvailable: true,
      version: AiPrivacyStatus.disclosureVersion,
    );
  }

  @override
  Future<AssistantReply> chat(String message,
      {List<String> healthData = const [],
      List<String> recentQuestions = const []}) async {
    history.add(recentQuestions);
    return pending == null ? reply : pending!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _submit(WidgetTester tester, String question,
    {bool history = false}) async {
  await tester.enterText(find.byType(TextField), question);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pumpAndSettle();
  expect(find.text('Share this question?'), findsOneWidget);
  if (history) {
    await tester.tap(find.text('Include up to four earlier questions'));
    await tester.pump();
  }
  await tester.tap(find.text('Share question'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('failed preflight offers a manual call and never requests AI consent', (tester) async {
    final api = _ChatApi()..preflightFailure = ApiException('Synthetic transport failure');
    final calls = <String>[];
    await tester.pumpWidget(NovaApp(home: Scaffold(body: AssistantScreen(
      api: api,
      callNumber: (number) async {
        calls.add(number);
        return false;
      },
    ))));
    await tester.enterText(find.byType(TextField), 'Synthetic urgent message');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.textContaining('could not check this message for an emergency'), findsOneWidget);
    expect(api.consentChecks, 0);
    expect(api.history, isEmpty);
    expect(calls, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Synthetic urgent message');
    await tester.tap(find.widgetWithText(FilledButton, 'Call 1990 (Sri Lanka)'));
    await tester.pumpAndSettle();
    expect(calls, ['1990']);
    expect(find.textContaining('Could not open the dialer'), findsOneWidget);
  });

  testWidgets('urgent preflight and saved-symptom replies expose a call action', (tester) async {
    final api = _ChatApi()..preflightReply = 'Synthetic emergency guidance';
    await tester.pumpWidget(NovaApp(home: Scaffold(body: AssistantScreen(api: api))));
    await tester.enterText(find.byType(TextField), 'Synthetic urgent text');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('Synthetic emergency guidance'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Call 1990 (Sri Lanka)'), findsOneWidget);
    expect(api.consentChecks, 0);
    expect(api.history, isEmpty);

    await tester.tap(find.bySemanticsLabel('New conversation'));
    await tester.pumpAndSettle();
    api.preflightReply = null;
    api.reply = const AssistantReply('Synthetic recent symptom notice',
        emergency: true, sources: ['Symptom logs']);
    await _submit(tester, 'Synthetic saved symptoms');
    await tester.pumpAndSettle();
    expect(find.text('Sources: Symptom logs'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Call 1990 (Sri Lanka)'), findsOneWidget);
  });

  testWidgets('new conversation clears the draft and excludes prior questions',
      (tester) async {
    final api = _ChatApi();
    await tester
        .pumpWidget(NovaApp(home: Scaffold(body: AssistantScreen(api: api))));
    await _submit(tester, 'Synthetic earlier question');
    await _submit(tester, 'Synthetic follow-up', history: true);
    expect(api.history, [
      [],
      ['Synthetic earlier question']
    ]);

    await tester.enterText(find.byType(TextField), 'Synthetic unsent draft');
    await tester.tap(find.bySemanticsLabel('New conversation'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.text('Synthetic earlier question'), findsNothing);
    await _submit(tester, 'Synthetic new question', history: true);
    expect(api.history.last, isEmpty);
  });

  testWidgets('new conversation drops a reply already in flight',
      (tester) async {
    final api = _ChatApi()..pending = Completer<AssistantReply>();
    await tester
        .pumpWidget(NovaApp(home: Scaffold(body: AssistantScreen(api: api))));
    await _submit(tester, 'Synthetic pending question');
    expect(api.history, hasLength(1));

    await tester.tap(find.bySemanticsLabel('New conversation'));
    await tester.pump();
    api.pending!.complete(
      const AssistantReply('Synthetic late reply', sources: ['Sleep logs']),
    );
    await tester.pumpAndSettle();
    expect(find.text('Synthetic late reply'), findsNothing);
    expect(find.text('Synthetic pending question'), findsNothing);
    expect(find.text('Sources: Sleep logs'), findsNothing);
  });

  testWidgets('verified sources are shown with the assistant reply', (tester) async {
    final api = _ChatApi()
      ..reply = AssistantReply.fromJson({
        'reply': 'Synthetic observation',
        'sources': ['sleep', 'invalid source', 'sleep', 'water', 17],
      });
    await tester
        .pumpWidget(NovaApp(home: Scaffold(body: AssistantScreen(api: api))));
    await _submit(tester, 'Synthetic question');
    expect(find.text('Synthetic observation'), findsOneWidget);
    expect(find.text('Sources: Sleep logs, Water logs'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('New conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Sources: Sleep logs, Water logs'), findsNothing);
  });

  testWidgets('confirmed consent revocation discards the active conversation',
      (tester) async {
    final api = _ChatApi();
    await tester
        .pumpWidget(NovaApp(home: Scaffold(body: AssistantScreen(api: api))));
    await _submit(tester, 'Synthetic private question');
    api.aiConsentRevocations.value++;
    await tester.pumpAndSettle();
    expect(find.text('Synthetic private question'), findsNothing);
    await _submit(tester, 'Synthetic question after opting in', history: true);
    expect(api.history.last, isEmpty);
  });

  testWidgets(
      'account switches dispose chat and review routes, including a switch back in one frame',
      (tester) async {
    final api = _ChatApi();
    final owners = StreamController<String?>(sync: true);
    addTearDown(owners.close);
    await tester.pumpWidget(AccountNavigation(
      initialOwner: api.aiAccountId,
      owners: owners.stream,
      builder: (navigator) => MaterialApp(
        key: ObjectKey(navigator),
        navigatorKey: navigator,
        theme: NovaTheme.light(),
        home: Scaffold(body: AssistantScreen(api: api)),
      ),
    ));
    await _submit(tester, 'Synthetic first account question');

    await tester.enterText(find.byType(TextField), 'Synthetic second draft');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('Share this question?'), findsOneWidget);

    final firstOwner = api.aiAccountId;
    api.aiAccountId = 'synthetic-other-account';
    owners.add(api.aiAccountId);
    api.aiAccountId = firstOwner;
    owners.add(firstOwner);
    await tester.pumpAndSettle();
    expect(find.text('Share this question?'), findsNothing);
    expect(find.text('Synthetic first account question'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(api.history, hasLength(1));

    api.aiAccountId = 'synthetic-other-account';
    owners.add(api.aiAccountId);
    await tester.pumpAndSettle();
    await _submit(tester, 'Synthetic other account question', history: true);
    expect(api.history.last, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test('daily goals do not carry over to a different or signed-out account',
      () async {
    SharedPreferences.setMockInitialValues({
      'goals.waterMl': 3300,
      'goals.sleepHours': 9.5,
    });
    final prefs = AppPrefs.instance;
    await prefs.load();
    addTearDown(() => prefs.selectAccount(null));
    prefs.selectAccount('synthetic-first-account');
    expect((prefs.waterGoalMl, prefs.sleepGoalHours), (2500, 7));
    await prefs.setWaterGoalMl(3200);
    await prefs.setSleepGoalHours(8.5);
    prefs.selectAccount('synthetic-other-account');
    expect((prefs.waterGoalMl, prefs.sleepGoalHours), (2500, 7));
    prefs.selectAccount(null);
    expect((prefs.waterGoalMl, prefs.sleepGoalHours), (2500, 7));
    prefs.selectAccount('synthetic-first-account');
    expect((prefs.waterGoalMl, prefs.sleepGoalHours), (3200, 8.5));
  });

  test('framework and asynchronous exception reporting emits fixed text', () {
    final dispatcher = PlatformDispatcher.instance;
    final oldFramework = FlutterError.onError;
    final oldPlatform = dispatcher.onError;
    final oldWidget = ErrorWidget.builder;
    final oldPrint = debugPrint;
    addTearDown(() {
      FlutterError.onError = oldFramework;
      dispatcher.onError = oldPlatform;
      ErrorWidget.builder = oldWidget;
      debugPrint = oldPrint;
    });
    final events = <String>[];
    debugPrint = (message, {wrapWidth}) => events.add(message!);
    installPrivacyDiagnostics(dispatcher, report: events.add);
    final error = StateError('Synthetic private message +12025550110');
    final stack =
        StackTrace.fromString('Synthetic private prescription details');
    final details = FlutterErrorDetails(exception: error, stack: stack);
    FlutterError.onError!(details);
    expect(dispatcher.onError!(error, stack), isTrue);
    debugPrint(error.toString());
    final fallback = ErrorWidget.builder(details) as Center;
    expect(
        (fallback.child as Text).data, 'This screen could not be displayed.');
    expect(
        events, ['Flutter framework error.', 'Unhandled application error.']);
  });

  test('API errors use local text even when the server sends private fields',
      () {
    const private = 'Synthetic private contact +12025550110';
    final known = ApiException.fromResponse(
        503,
        {'code': 'CHAT_DELETION_UNVERIFIED', 'message': private},
        '/api/v1/privacy/ai/chats');
    final unknown = ApiException.fromResponse(
        500, {'code': private, 'message': private}, '/path');
    expect(known.message,
        'Could not verify older chat deletion. Try again later.');
    expect(unknown.message, 'NOVA could not process this request. Try again.');
  });
}
