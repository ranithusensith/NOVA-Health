import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/scan_models.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Calls the NOVA FastAPI backend with the signed-in user's Supabase token.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  Map<String, String> get _authHeaders {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) throw ApiException('Please sign in again.');
    return {'Authorization': 'Bearer $token'};
  }

  String? get aiAccountId => Supabase.instance.client.auth.currentUser?.id;

  Uri _uri(String path) {
    final uri = Uri.parse('${AppConfig.apiUrl}$path');
    if (path.startsWith('/api/v1/assistant/') ||
        path.startsWith('/api/v1/privacy/') ||
        (path.startsWith('/api/v1/scan/') && !path.endsWith('/confirm'))) {
      const release = bool.fromEnvironment('dart.vm.product');
      const loopback = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
      if (uri.scheme != 'https' && (release || uri.scheme != 'http' || !loopback.contains(uri.host))) {
        throw ApiException('External AI requests require a secure connection to NOVA.');
      }
    }
    return uri;
  }

  Future<Map<String, dynamic>> _sendImage(String path, XFile file, {bool reviewed = false}) async {
    final request = http.MultipartRequest('POST', _uri(path))
      ..followRedirects = false
      ..headers.addAll(_authHeaders)
      ..files.add(http.MultipartFile.fromBytes(
        'image',
        await file.readAsBytes(),
        filename: 'scan',
      ));
    if (reviewed) request.fields['reviewed'] = 'true';

    final http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(seconds: 90));
    } catch (_) {
      throw ApiException('Cannot reach the server. Is the backend running?');
    }

    final body = await streamed.stream.bytesToString();
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('Unexpected server response (${streamed.statusCode}).');
    }

    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return (json['data'] as Map).cast<String, dynamic>();
    }
    final message = (json['error'] as Map?)?['message'] as String?;
    throw ApiException(message ?? 'Request failed (${streamed.statusCode}).');
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final request = http.Request(method, _uri(path))
      ..followRedirects = false
      ..headers.addAll(_authHeaders);
    if (payload != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(payload);
    }
    final http.Response res;
    try {
      res = await request.send().then(http.Response.fromStream).timeout(timeout);
    } catch (_) {
      throw ApiException('Cannot reach the server. Is the backend running?');
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('Unexpected server response (${res.statusCode}).');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return (json['data'] as Map).cast<String, dynamic>();
    }
    final message = (json['error'] as Map?)?['message'] as String?;
    throw ApiException(message ?? 'Request failed (${res.statusCode}).');
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 60),
  }) => _requestJson('POST', path, payload: payload, timeout: timeout);

  Future<AiPrivacyStatus> aiPrivacyStatus() async {
    if (AppConfig.useMockApi) {
      return const AiPrivacyStatus(enabled: false, providerAvailable: false, version: '');
    }
    return AiPrivacyStatus.fromJson(await _getJson('/api/v1/privacy/ai'));
  }

  Future<void> setAiConsent(bool enabled) async {
    await _postJson('/api/v1/privacy/ai', {
      'enabled': enabled,
      if (enabled) 'disclosure_version': AiPrivacyStatus.disclosureVersion,
    });
  }

  Future<int> deleteLegacyAiChats() async {
    final result = await _requestJson('DELETE', '/api/v1/privacy/ai/chats');
    return result['deleted'] as int;
  }

  Future<String> extractMedicalText(XFile file) async {
    final result = await _sendImage('/api/v1/scan/medical-text', file);
    return (result['text'] as String?) ?? '';
  }

  // ---------------------------------------------------------------- public API
  // With USE_MOCK_API=true these return sample data, so the UI can be built
  // and tested without the backend or an AI key.

  Future<PrescriptionScan> scanPrescription(String reviewedText) async {
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      return const PrescriptionScan(
        medications: [
          ScanMedication(name: 'Cetirizine', dosage: '10 mg', frequency: 'once a day', durationDays: 5),
          ScanMedication(name: 'Paracetamol', dosage: '500 mg', frequency: 'every 8 hours', durationDays: 3),
        ],
        confidence: 0.9,
      );
    }
    return PrescriptionScan.fromJson(await _postJson('/api/v1/scan/prescription', {'text': reviewedText, 'reviewed': true}));
  }

  Future<PrescriptionConfirmation> confirmPrescription(
    String scanId,
    List<Map<String, dynamic>> medications,
    String? reviewToken,
  ) async {
    final data = await _postJson('/api/v1/scan/prescription/confirm', {
      'scan_id': scanId,
      'medications': medications,
      if (reviewToken != null) 'review_token': reviewToken,
    });
    return PrescriptionConfirmation.fromJson(data);
  }

  Future<ReportScan> scanReport(String reviewedText) async {
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      return ReportScan(
        reportType: 'Full blood count',
        reportDate: DateTime.now(),
        confidence: 0.9,
        results: [
          LabResultDraft(test: 'Haemoglobin', value: 11.2, unit: 'g/dL', refLow: 13, refHigh: 17, flag: 'low'),
          LabResultDraft(test: 'White blood cells', value: 7400, unit: '/uL', refLow: 4000, refHigh: 11000, flag: 'normal'),
          LabResultDraft(test: 'Platelets', value: 390, unit: '10^3/uL', refLow: 150, refHigh: 450, flag: 'normal'),
        ],
      );
    }
    return ReportScan.fromJson(await _postJson('/api/v1/scan/report', {'text': reviewedText, 'reviewed': true}));
  }

  Future<FoodScan> scanFood(XFile file) async {
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      return const FoodScan(
        description: 'Rice and chicken curry',
        calories: 650,
        proteinG: 28,
        carbsG: 90,
        fatG: 18,
        confidence: 0.8,
      );
    }
    return FoodScan.fromJson(await _sendImage('/api/v1/scan/food', file, reviewed: true));
  }

  /// Sends a message to the AI assistant and returns its reply text.
  Future<String> chat(String message, {List<String> healthData = const [], List<String> recentQuestions = const []}) async {
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return 'Sample reply: your sleep was short and water was low this week. '
          'Try an earlier bedtime and a glass of water now.\n\nGuidance, not medical advice.';
    }
    final data = await _postJson('/api/v1/assistant/chat', {
      'message': message,
      'reviewed': true,
      'health_data': healthData,
      'recent_questions': recentQuestions,
    });
    return (data['reply'] as String?) ?? '';
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Duration timeout = const Duration(seconds: 60),
  }) => _requestJson('GET', path, timeout: timeout);

  /// GET /api/v1/reports/daily?date=YYYY-MM-DD → the NOVA summary text for that day.
  Future<String> dailyReport(DateTime day) async {
    final date = '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return 'Sample report for $date: sleep was a little short and water was below goal. '
          'Try a glass of water with each meal and a wind-down routine 30 minutes before bed.\n\n'
          'Guidance, not medical advice.';
    }
    final data = await _getJson('/api/v1/reports/daily?date=$date');
    return (data['report'] as String?) ?? '';
  }

  Future<EmergencyResult> triggerEmergencyDetailed() async {
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return const EmergencyResult(status: SosDeliveryState.simulated);
    }
    return EmergencyResult.fromJson(await _postJson(
      '/api/v1/emergency/trigger', const {}, timeout: const Duration(seconds: 12),
    ));
  }

  Future<EmergencyResult> emergencyStatus(String attemptId) async {
    return EmergencyResult.fromJson(await _getJson(
      '/api/v1/emergency/${Uri.encodeComponent(attemptId)}/status', timeout: const Duration(seconds: 10),
    ));
  }
}

class AiPrivacyStatus {
  const AiPrivacyStatus({required this.enabled, required this.providerAvailable, required this.version});

  static const disclosureVersion = 'gemini-health-v1';
  final bool enabled;
  final bool providerAvailable;
  final String version;

  bool get canReview => providerAvailable && version == disclosureVersion;
  bool get allowed => canReview && enabled;

  factory AiPrivacyStatus.fromJson(Map<String, dynamic> json) => AiPrivacyStatus(
    enabled: json['enabled'] == true,
    providerAvailable: json['provider_available'] == true,
    version: (json['disclosure_version'] as String?) ?? '',
  );
}

enum SosDeliveryState {
  simulated('simulated'),
  manualRequired('manual_required'),
  queued('queued'),
  sent('sent'),
  delivered('delivered'),
  partialFailure('partial_failure'),
  failed('failed'),
  noContacts('no_contacts'),
  unknown('unknown');

  const SosDeliveryState(this.value);
  final String value;

  static SosDeliveryState fromValue(Object? value) =>
      values.firstWhere((state) => state.value == value, orElse: () => unknown);
}

class EmergencyResult {
  const EmergencyResult({
    required this.status,
    this.recipients = const {},
    this.attemptId,
    this.canRefresh = false,
    this.statusCheckUnavailable = false,
  });

  final SosDeliveryState status;
  final Map<String, SosDeliveryState> recipients;
  final String? attemptId;
  final bool canRefresh;
  final bool statusCheckUnavailable;

  int count(SosDeliveryState state) => recipients.values.where((value) => value == state).length;

  factory EmergencyResult.fromJson(Map<String, dynamic> json) {
    final raw = json['recipients'];
    if (raw is! List) return const EmergencyResult(status: SosDeliveryState.unknown);
    final recipients = <String, SosDeliveryState>{};
    for (final row in raw) {
      if (row is Map && row['contact_id'] is String) {
        recipients[row['contact_id'] as String] = SosDeliveryState.fromValue(row['status']);
      }
    }
    var status = SosDeliveryState.fromValue(json['status']);
    if (recipients.length != json['contacts_total'] || recipients.length != raw.length ||
        (status == SosDeliveryState.delivered &&
            (recipients.isEmpty || recipients.values.any((state) => state != SosDeliveryState.delivered)))) {
      status = SosDeliveryState.unknown;
    }
    return EmergencyResult(
      status: status,
      recipients: recipients,
      attemptId: json['attempt_id'] is String ? json['attempt_id'] as String : null,
      canRefresh: json['can_refresh'] == true,
      statusCheckUnavailable: json['status_check_unavailable'] == true,
    );
  }
}
