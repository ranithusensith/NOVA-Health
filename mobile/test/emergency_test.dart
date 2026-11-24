import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_health/data/care_models.dart';
import 'package:nova_health/main.dart';
import 'package:nova_health/screens/emergency_screen.dart';
import 'package:nova_health/services/api_client.dart';
import 'package:nova_health/services/emergency_service.dart';
import 'package:nova_health/widgets/content.dart';

// Reserved synthetic fiction numbers. Platform calls are always mocked.
const _contactA = EmergencyContact(
    id: 'a', name: 'Synthetic Contact A', phone: '+12025550101');
const _contactB = EmergencyContact(
    id: 'b', name: 'Synthetic Contact B', phone: '+12025550102');

class _FakeEmergencyService implements EmergencyService {
  List<EmergencyContact>? saved;
  List<EmergencyContact> online = [_contactA];
  Future<List<EmergencyContact>?>? refreshOverride;
  bool offline = false;
  bool composerOpened = true;
  bool composerThrows = false;
  int triggers = 0;
  final opened = <EmergencyContact>[];
  final calls = <String>[];
  EmergencyResult result =
      const EmergencyResult(status: SosDeliveryState.simulated);
  EmergencyResult? refreshed;

  @override
  String? get accountId => 'synthetic-owner';

  @override
  Stream<String?> get accountChanges => const Stream.empty();

  @override
  void attach() {}

  @override
  Future<List<EmergencyContact>?> cachedContacts() async => saved;

  @override
  Future<List<EmergencyContact>?> refreshContacts() async {
    final pending = refreshOverride;
    if (pending != null) return pending;
    if (offline) throw StateError('Synthetic offline test');
    return online;
  }

  @override
  Future<EmergencyResult> trigger() async {
    triggers++;
    if (offline) throw Exception('Synthetic request failed');
    return result;
  }

  @override
  Future<EmergencyResult> checkStatus(String attemptId) async =>
      refreshed ?? result;

  @override
  Future<bool> openMessages(EmergencyContact contact) async {
    opened.add(contact);
    if (composerThrows) throw MissingPluginException();
    return composerOpened;
  }

  @override
  Future<bool> call(String phone) async {
    calls.add(phone);
    return true;
  }

  @override
  Future<void> addContact(
      {required String name,
      required String phone,
      String? relationship}) async {}

  @override
  Future<void> deleteContact(String contactId) async {}
}

Finder _button(String label) => find.widgetWithText(NovaButton, label);

Future<void> _show(WidgetTester tester, _FakeEmergencyService service) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(850, 1250);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(NovaApp(home: EmergencyScreen(service: service)));
  await tester.pumpAndSettle();
}

Future<void> _hold(WidgetTester tester) async {
  final target = find.text('SOS');
  await tester.ensureVisible(target);
  final gesture = await tester.startGesture(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 16));
  expect(find.text('Keep holding…'), findsOneWidget);
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await _hold(tester);
  await tester.tap(find.text('Send SOS'));
  await tester.pumpAndSettle();
}

Future<void> _compose(WidgetTester tester, EmergencyContact contact) async {
  await tester.tap(_button('Open Messages'));
  await tester.pumpAndSettle();
  final action = find.text(contact.name).last;
  await tester.tap(action);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy HTTP success and acceptance flags do not become delivered', () {
    final result = EmergencyResult.fromJson(
        {'status': 'triggered', 'delivered': true, 'contacts_notified': 1});
    expect(result.status, SosDeliveryState.unknown);
    final inconsistent = EmergencyResult.fromJson({
      'status': 'delivered',
      'contacts_total': 1,
      'recipients': [
        {'contact_id': 'a', 'status': 'sent'}
      ],
    });
    expect(inconsistent.status, SosDeliveryState.unknown);
  });

  test(
      'offline cache survives a restart for the owner and is cleared on sign-out',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final cache = EmergencyContactCache()..setAccount('account-a');
    await cache.replace('account-a', [_contactA, _contactB]);

    final restored = EmergencyContactCache()..setAccount('account-a');
    expect((await restored.read('account-a'))!.map((c) => c.id), ['a', 'b']);
    expect(await restored.read('account-b'), isNull);
    await restored.update(
        'account-a', (contacts) => contacts.where((c) => c.id != 'a').toList());
    expect((await restored.read('account-a'))!.single.id, 'b');

    restored.setAccount(null);
    expect(await restored.read('account-a'), isNull);
    final signedBackIn = EmergencyContactCache()..setAccount('account-a');
    expect(await signedBackIn.read('account-a'), isNull);
  });

  test('account changes cannot expose another account’s cached contacts',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final first = EmergencyContactCache()..setAccount('account-a');
    await first.replace('account-a', [_contactA]);
    final second = EmergencyContactCache()..setAccount('account-b');
    expect(await second.read('account-b'), isNull);
    await second.replace('account-b', [_contactB]);
    expect((await second.read('account-b'))!.single.id, 'b');
    expect(await first.read('account-a'), isNull);
  });

  test(
      'composer adapter uses the system response and rejects invalid recipients',
      () async {
    const channel = MethodChannel('nova_health/emergency');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var invocations = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      invocations++;
      expect(call.method, 'openSms');
      expect(call.arguments['phone'], _contactA.phone);
      return false;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await EmergencyService.instance.openMessages(_contactA), isFalse);
    expect(
        await EmergencyService.instance.openMessages(
          const EmergencyContact(id: 'bad', name: 'Invalid', phone: 'invalid'),
        ),
        isFalse);
    expect(invocations, 1);
  });

  testWidgets('simulation is explicit and does not launch or send a message',
      (tester) async {
    final service = _FakeEmergencyService()
      ..result = const EmergencyResult(
        status: SosDeliveryState.simulated,
        recipients: {'a': SosDeliveryState.manualRequired},
      );
    await _show(tester, service);
    await _submit(tester);
    expect(find.text('Simulation mode'), findsOneWidget);
    expect(find.textContaining('NOVA did not send a real SMS'), findsOneWidget);
    expect(find.text('SOS delivered'), findsNothing);
    expect(service.opened, isEmpty);
    await _compose(tester, _contactA);
    expect(service.opened, [_contactA]);
    expect(find.textContaining('Press Send in your messaging app'),
        findsOneWidget);
    expect(find.text('SOS delivered'), findsNothing);
  });

  testWidgets('zero contacts keeps the call fallback and never opens Messages',
      (tester) async {
    final service = _FakeEmergencyService()..online = [];
    await _show(tester, service);
    await _hold(tester);
    expect(find.text('No emergency contacts'), findsOneWidget);
    expect(_button('Open Messages'), findsNothing);
    expect(service.triggers, 0);
    await tester.tap(_button('Call 1990 ambulance'));
    expect(service.calls, [ambulanceNumber]);
  });

  testWidgets(
      'saved contacts can open the composer before an online fetch returns',
      (tester) async {
    final pending = Completer<List<EmergencyContact>?>();
    final service = _FakeEmergencyService()
      ..saved = [_contactA]
      ..refreshOverride = pending.future;
    await _show(tester, service);
    expect(
        find.textContaining('Showing emergency contacts saved on this device'),
        findsOneWidget);
    await _compose(tester, _contactA);
    expect(service.opened, [_contactA]);
    expect(service.triggers, 0);
    pending.completeError(StateError('Synthetic offline test'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'offline SOS leaves delivery unknown and supplies a manual fallback',
      (tester) async {
    final service = _FakeEmergencyService()
      ..saved = [_contactA]
      ..offline = true;
    await _show(tester, service);
    await _submit(tester);
    expect(find.text('SOS status unknown'), findsOneWidget);
    expect(_button('Call 1990 ambulance'), findsOneWidget);
    expect(_button('Open Messages'), findsOneWidget);
    expect(service.opened, isEmpty);
  });

  testWidgets('an unverified provider request warns before a manual retry', (tester) async {
    final service = _FakeEmergencyService()
      ..result = const EmergencyResult(
        status: SosDeliveryState.unknown,
        recipients: {'a': SosDeliveryState.unknown},
      );
    await _show(tester, service);
    await _submit(tester);
    await tester.tap(_button('Open Messages'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A duplicate alert is possible'), findsOneWidget);
    expect(service.opened, isEmpty);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(service.opened, isEmpty);
  });

  for (final throws in [false, true]) {
    testWidgets('SMS composer failure is visible (platform exception: $throws)',
        (tester) async {
      final service = _FakeEmergencyService()
        ..composerOpened = false
        ..composerThrows = throws
        ..result = const EmergencyResult(
          status: SosDeliveryState.failed,
          recipients: {'a': SosDeliveryState.failed},
        );
      await _show(tester, service);
      await _submit(tester);
      expect(find.text('SOS failed'), findsOneWidget);
      await _compose(tester, _contactA);
      expect(find.textContaining('Could not open the SMS composer'),
          findsOneWidget);
      expect(find.textContaining('Press Send in your messaging app'),
          findsNothing);
      expect(_button('Call 1990 ambulance'), findsOneWidget);
    });
  }

  testWidgets(
      'partial failure identifies failed contacts and only offers those for manual SMS',
      (tester) async {
    final service = _FakeEmergencyService()
      ..online = [_contactA, _contactB]
      ..result = const EmergencyResult(
        status: SosDeliveryState.partialFailure,
        recipients: {
          'a': SosDeliveryState.delivered,
          'b': SosDeliveryState.failed
        },
      );
    await _show(tester, service);
    await _submit(tester);
    expect(find.text('Some SOS alerts failed'), findsOneWidget);
    expect(find.textContaining('1 delivered · 1 failed'), findsOneWidget);
    expect(find.text('SOS delivered'), findsNothing);
    await _compose(tester, _contactB);
    expect(service.opened, [_contactB]);
  });

  testWidgets('queued and sent remain unconfirmed until a refreshed receipt',
      (tester) async {
    final service = _FakeEmergencyService()
      ..result = const EmergencyResult(
        status: SosDeliveryState.queued,
        attemptId: 'attempt',
        canRefresh: true,
        recipients: {'a': SosDeliveryState.queued},
      )
      ..refreshed = const EmergencyResult(
        status: SosDeliveryState.sent,
        attemptId: 'attempt',
        canRefresh: true,
        recipients: {'a': SosDeliveryState.sent},
      );
    await _show(tester, service);
    await _submit(tester);
    expect(find.text('SOS queued'), findsOneWidget);
    expect(find.text('SOS delivered'), findsNothing);
    await tester.tap(_button('Check delivery status'));
    await tester.pumpAndSettle();
    expect(find.text('SOS sent to the carrier'), findsOneWidget);
    expect(find.text('SOS delivered'), findsNothing);

    service.refreshed = const EmergencyResult(
      status: SosDeliveryState.delivered,
      attemptId: 'attempt',
      recipients: {'a': SosDeliveryState.delivered},
    );
    await tester.tap(_button('Check delivery status'));
    await tester.pumpAndSettle();
    expect(find.text('SOS delivered'), findsOneWidget);
  });
}
