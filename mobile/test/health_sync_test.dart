import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_health/data/profile_models.dart';
import 'package:nova_health/data/profile_repository.dart';
import 'package:nova_health/services/health_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _alice = '00000000-0000-0000-0000-000000000901';
const _bob = '00000000-0000-0000-0000-000000000902';
const _availability = MethodChannel('nova_health/healthkit');
const _androidRead = MethodChannel('nova_health/health_connect');
final _now = DateTime.utc(2026, 11, 24, 8);

HealthDataPoint _point(
  int minutesAgo,
  num bpm, {
  HealthDataType type = HealthDataType.HEART_RATE,
  HealthDataUnit unit = HealthDataUnit.BEATS_PER_MINUTE,
}) {
  final at = _now.subtract(Duration(minutes: minutesAgo));
  return HealthDataPoint(
    uuid: 'synthetic-$minutesAgo',
    value: NumericHealthValue(numericValue: bpm),
    type: type,
    unit: unit,
    dateFrom: at,
    dateTo: at,
    sourcePlatform: HealthPlatformType.appleHealth,
    sourceDeviceId: 'synthetic-device',
    sourceId: 'synthetic-source',
    sourceName: 'Synthetic source',
  );
}

class _Health implements Health {
  final events = <String>[];
  bool authorized = true;
  bool androidAuthorized = false;
  List<HealthDataPoint> points = const [];
  VoidCallback? duringRequest;
  VoidCallback? duringRead;
  Object? readError;

  @override
  Future<void> configure() async => events.add('configure');

  @override
  Future<bool> isHealthConnectAvailable() async {
    events.add('health-connect-availability');
    return true;
  }

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types,
      {List<HealthDataAccess>? permissions}) async {
    events.add('has-permissions');
    expect(types, [HealthDataType.HEART_RATE]);
    expect(permissions, [HealthDataAccess.READ]);
    return androidAuthorized;
  }

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types,
      {List<HealthDataAccess>? permissions}) async {
    events.add('request-authorization');
    expect(types, [HealthDataType.HEART_RATE]);
    expect(permissions, [HealthDataAccess.READ]);
    duringRequest?.call();
    return authorized;
  }

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
    List<RecordingMethod> recordingMethodsToFilter = const [],
  }) async {
    events.add('read');
    expect(types, [HealthDataType.HEART_RATE]);
    expect(startTime, _now.subtract(const Duration(days: 7)));
    expect(endTime, _now);
    duringRead?.call();
    if (readError case final error?) throw error;
    return points;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository extends ProfileRepository {
  String? owner = _alice;
  List<HeartSample>? samples;
  int newlySaved = 0;
  String? source;
  bool fail = false;

  @override
  String? get currentAccountId => owner;

  @override
  Future<int> importHeartSamples(List<HeartSample> samples,
      {required String device, required String accountId}) async {
    expect(accountId, _alice);
    this.samples = samples;
    source = device;
    if (fail) throw StateError('Synthetic private database detail');
    return newlySaved;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Health health;
  late _Repository repository;
  late bool available;
  late HeartSync sync;

  setUp(() {
    health = _Health();
    repository = _Repository();
    available = true;
    sync = HeartSync(
        health: health,
        repository: repository,
        platform: TargetPlatform.iOS,
        now: () => _now);
    messenger.setMockMethodCallHandler(_availability, (call) async {
      expect(call.method, 'isHealthDataAvailable');
      expect(call.arguments, isNull);
      health.events.add('apple-health-availability');
      return available;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(_availability, null);
    messenger.setMockMethodCallHandler(_androidRead, null);
  });

  test(
      'no Apple Health availability skips configuration, authorization, reads, and writes',
      () async {
    available = false;
    await expectLater(
        sync.importRecent(),
        throwsA(isA<HealthSyncException>().having((error) => error.message,
            'message', contains('unavailable on this device'))));
    expect(health.events, ['apple-health-availability']);
    expect(repository.samples, isNull);
  });

  test('unsupported platforms and signed-out users do not request Health data',
      () async {
    final other = HeartSync(
        health: health, repository: repository, platform: TargetPlatform.macOS);
    expect(other.supported, isFalse);
    await expectLater(
        other.importRecent(), throwsA(isA<HealthSyncException>()));
    repository.owner = null;
    await expectLater(sync.importRecent(), throwsA(isA<HealthSyncException>()));
    expect(health.events, isEmpty);
    expect(repository.samples, isNull);
  });

  test('failed Apple Health authorization is reported without claiming denial',
      () async {
    health.authorized = false;
    await expectLater(
        sync.importRecent(),
        throwsA(isA<HealthSyncException>().having((error) => error.message,
            'message', contains('Could not complete'))));
    expect(health.events,
        ['apple-health-availability', 'configure', 'request-authorization']);
    expect(repository.samples, isNull);
  });

  test('completed iOS authorization with no readable data makes no write',
      () async {
    final result = await sync.importRecent();
    expect((result.found, result.imported), (0, 0));
    expect(health.events, [
      'apple-health-availability',
      'configure',
      'request-authorization',
      'read'
    ]);
    expect(repository.samples, isNull);
  });

  test('only finite heart rate in bpm in the requested window is submitted',
      () async {
    health.points = List.unmodifiable([
      _point(10, 80),
      _point(30, 72),
      _point(25, 75),
      _point(70, double.nan),
      _point(60, double.infinity),
      _point(55, 280),
      _point(50, 60, type: HealthDataType.STEPS),
      _point(45, 60, unit: HealthDataUnit.UNKNOWN_UNIT),
      _point(10_090, 60),
      _point(-1, 60),
    ]);
    repository.newlySaved = 1;
    final result = await sync.importRecent();
    expect(repository.source, 'apple_health');
    expect(repository.samples!.map((sample) => sample.bpm), [72, 80]);
    expect((result.found, result.imported), (2, 1));
  });

  test('switching accounts during authorization skips the query', () async {
    health.duringRequest = () => repository.owner = _bob;
    await expectLater(
        sync.importRecent(),
        throwsA(isA<HealthSyncException>().having(
            (error) => error.message, 'message', contains('account changed'))));
    expect(health.events, isNot(contains('read')));
    expect(repository.samples, isNull);
  });

  test('switching accounts during the read skips upload', () async {
    health.points = [_point(5, 75)];
    health.duringRead = () => repository.owner = _bob;
    await expectLater(sync.importRecent(), throwsA(isA<HealthSyncException>()));
    expect(repository.samples, isNull);
  });

  test('read and upload failures have distinct safe messages', () async {
    health.readError = PlatformException(
        code: 'synthetic', message: 'Synthetic private HealthKit detail');
    await expectLater(
        sync.importRecent(),
        throwsA(isA<HealthSyncException>().having((error) => error.message,
            'message', allOf(contains('Unlock'), isNot(contains('private'))))));
    expect(repository.samples, isNull);
    health.readError = null;
    health.points = [_point(5, 75)];
    repository.fail = true;
    await expectLater(
        sync.importRecent(),
        throwsA(isA<HealthSyncException>().having(
            (error) => error.message,
            'message',
            allOf(contains('saving readings'), isNot(contains('private'))))));
  });

  test(
      'Android uses Health Connect and skips a redundant authorization request',
      () async {
    health.androidAuthorized = true;
    messenger.setMockMethodCallHandler(_androidRead, (call) async {
      expect(call.method, 'readHeartRate');
      expect(call.arguments, {
        'start': _now.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
        'end': _now.millisecondsSinceEpoch,
      });
      health.events.add('native-heart-read');
      return [
        {
          'at':
              _now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
          'bpm': 75
        },
      ];
    });
    final android = HeartSync(
        health: health,
        repository: repository,
        platform: TargetPlatform.android,
        now: () => _now);
    expect((await android.importRecent()).found, 1);
    expect(repository.source, 'health_connect');
    expect(health.events, [
      'health-connect-availability',
      'configure',
      'has-permissions',
      'native-heart-read'
    ]);
  });

  test('Android native query failure exposes no raw details and writes nothing',
      () async {
    health.androidAuthorized = true;
    messenger.setMockMethodCallHandler(_androidRead, (_) async {
      throw PlatformException(
          code: 'HEART_RATE_UNAVAILABLE', details: 'synthetic private details');
    });
    final android = HeartSync(
        health: health,
        repository: repository,
        platform: TargetPlatform.android,
        now: () => _now);
    await expectLater(
        android.importRecent(),
        throwsA(isA<HealthSyncException>().having((error) => error.message,
            'message', startsWith('Could not read Health Connect'))));
    expect(repository.samples, isNull);
  });

  group('heart-rate storage', () {
    late SupabaseClient client;
    late ProfileRepository profile;
    late List<http.Request> writes;
    late String signingInAs;
    late bool switchAfterFirstChunk;

    Future<void> signIn() => client.auth.signInWithPassword(
        email: 'synthetic@example.test', password: 'synthetic');

    setUp(() async {
      signingInAs = _alice;
      switchAfterFirstChunk = false;
      writes = [];
      final expires =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
              1000;
      final token = base64Url
          .encode(utf8.encode(jsonEncode({'exp': expires})))
          .replaceAll('=', '');
      client = SupabaseClient(
        'https://supabase.invalid',
        'sb_publishable_synthetic',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/v1/token') {
            return http.Response(
                jsonEncode({
                  'access_token': 'e30.$token.synthetic',
                  'token_type': 'bearer',
                  'user': {
                    'id': signingInAs,
                    'aud': 'authenticated',
                    'created_at': '2026-11-01T00:00:00Z'
                  },
                }),
                200,
                request: request,
                headers: {'content-type': 'application/json'});
          }
          expect(request.url.path, '/rest/v1/wearable_samples');
          writes.add(request);
          if (switchAfterFirstChunk) {
            switchAfterFirstChunk = false;
            signingInAs = _bob;
            await signIn();
          }
          return http.Response('[{"id":"synthetic-inserted"}]', 201,
              request: request);
        }),
      );
      addTearDown(client.dispose);
      await signIn();
      profile = ProfileRepository(client: client);
    });

    test('upserts only owner-scoped heart samples and counts returned inserts',
        () async {
      final samples = [
        HeartSample(bpm: 72, at: _now),
        HeartSample(bpm: 74, at: _now.subtract(const Duration(minutes: 10)))
      ];
      expect(
          await profile.importHeartSamples(samples,
              device: 'apple_health', accountId: _alice),
          1);
      final request = writes.single;
      expect(request.url.queryParameters['on_conflict'],
          'user_id,metric,device,recorded_at');
      expect(request.url.queryParameters['select'], 'id');
      expect(
          request.headers['Prefer'], contains('resolution=ignore-duplicates'));
      expect((jsonDecode(request.body) as List).first, {
        'user_id': _alice,
        'metric': 'heart_rate',
        'value': 72,
        'recorded_at': _now.toIso8601String(),
        'device': 'apple_health',
        'context': 'unknown',
      });
    });

    test('an account change stops the remaining chunks', () async {
      switchAfterFirstChunk = true;
      final samples = List.generate(
          201, (i) => HeartSample(bpm: 70, at: _now.add(Duration(minutes: i))));
      await expectLater(
          profile.importHeartSamples(samples,
              device: 'apple_health', accountId: _alice),
          throwsStateError);
      expect(profile.currentAccountId, _bob);
      expect(writes, hasLength(1));
      final written = jsonDecode(writes.single.body) as List;
      expect(written, hasLength(200));
      expect(written.map((row) => row['user_id']).toSet(), {_alice});
    });
  });
}
