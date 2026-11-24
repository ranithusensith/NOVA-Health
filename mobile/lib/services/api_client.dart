import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/scan_models.dart';
import '../data/symptom_repository.dart';
import '../data/care_models.dart';
import '../data/daily_metrics.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  factory ApiException.fromResponse(int status, Object? error, String path) {
    final code = error is Map ? error['code'] : null;
    final message = switch (code) {
      'UNAUTHORIZED' => 'Sign in again.',
      'FORBIDDEN' => 'Your account cannot perform this action.',
      'AUTH_UNAVAILABLE' || 'AUTH_RESPONSE_INVALID' =>
        'Could not verify your session. Try again later.',
      'AI_CONSENT_REQUIRED' =>
        'Review and enable Google Gemini processing in Privacy and consent.',
      'AI_DISCLOSURE_OUTDATED' => 'Update the app to review the current AI disclosure.',
      'AI_PRIVACY_UNAVAILABLE' => 'External AI is unavailable. Check Privacy and consent or try again later.',
      'AI_RESPONSE_INVALID' => 'The AI returned an unreadable answer. Try again.',
      'AI_REQUEST_REJECTED' || 'AI_PROVIDER_AUTH_FAILED' || 'AI_UNAVAILABLE' =>
        'The AI service is unavailable. Try again later.',
      'CHAT_DELETION_UNVERIFIED' => 'Could not verify older chat deletion. Try again later.',
      'REVIEW_REQUIRED' when path.endsWith('/report/confirm') =>
        'Check the results against your report before saving.',
      'REVIEW_REQUIRED' when path.endsWith('/scan/food') =>
        'Review the photo and retake it with only the food visible.',
      'REVIEW_REQUIRED' => 'Review the information and remove identifying details before sharing.',
      'OCR_UNAVAILABLE' => 'Private text extraction is unavailable. You can enter clinical text manually.',
      'SCAN_FAILED' => 'Could not find the expected details. Check the image or reviewed text and try again.',
      'INVALID_INPUT' => 'Check the information you entered and try again.',
      'MEDICATION_CHANGED' => 'Health or medication information changed. Reopen Medications and try again.',
      'NOT_FOUND' when path == '/api/v1/medications/confirm' =>
        'This medication is unavailable. Reopen Medications and try again.',
      'MEDICATION_SAVE_UNVERIFIED' =>
        'Could not verify that the medication was saved. Check Medications before trying again.',
      'PRESCRIPTION_SAVE_UNVERIFIED' =>
        'Could not verify that the prescription was saved. Check Medications before trying again.',
      'LAB_SAVE_UNVERIFIED' =>
        'Could not verify the save. Check Medical records before trying again.',
      'SOS_UNAVAILABLE' =>
        'Could not read your emergency contacts. Call 1990 or your contacts directly.',
      'SOS_STATUS_UNAVAILABLE' => 'Delivery status is unavailable for this SOS.',
      'RATE_LIMITED' when path == '/api/v1/emergency/trigger' =>
        'An SOS was recently requested. Check its status or call 1990 now.',
      'RATE_LIMITED' => 'Too many requests. Try again later.',
      _ when status == 401 => 'Sign in again.',
      _ => 'NOVA could not process this request. Try again.',
    };
    return ApiException(message);
  }

  @override
  String toString() => message;
}

/// Calls the NOVA FastAPI backend with the signed-in user's Supabase token.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();
  final _revocations = ValueNotifier<int>(0);
  ValueListenable<int> get aiConsentRevocations => _revocations;

  Map<String, String> get _authHeaders {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) throw ApiException('Please sign in again.');
    return {'Authorization': 'Bearer $token'};
  }

  String? get aiAccountId => AppConfig.current.canConnect
      ? Supabase.instance.client.auth.currentUser?.id
      : null;

  Uri _uri(String path) {
    final config = AppConfig.current;
    if (!config.canConnect) {
      throw ApiException('Real NOVA services are unavailable with this app configuration.');
    }
    return Uri.parse('${config.apiBase}$path');
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
    return _responseData(body, streamed.statusCode, path);
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
    return _responseData(res.body, res.statusCode, path);
  }

  Map<String, dynamic> _responseData(String body, int status, String path) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw ApiException('Unexpected server response. Try again.');
    }
    if (status < 200 || status >= 300) {
      throw ApiException.fromResponse(status, json is Map ? json['error'] : null, path);
    }
    if (json is Map && json['data'] is Map<String, dynamic>) {
      return json['data'] as Map<String, dynamic>;
    }
    throw ApiException('Unexpected server response. Try again.');
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 60),
  }) => _requestJson('POST', path, payload: payload, timeout: timeout);

  Future<AiPrivacyStatus> aiPrivacyStatus() async {
    return AiPrivacyStatus.fromJson(await _getJson('/api/v1/privacy/ai'));
  }

  Future<void> setAiConsent(bool enabled) async {
    final owner = aiAccountId;
    await _postJson('/api/v1/privacy/ai', {
      'enabled': enabled,
      if (enabled) 'disclosure_version': AiPrivacyStatus.disclosureVersion,
    });
    if (!enabled && owner != null && aiAccountId == owner) _revocations.value++;
  }

  Future<int> deleteLegacyAiChats() async {
    final result = await _requestJson('DELETE', '/api/v1/privacy/ai/chats');
    final count = result['deleted'];
    if (count is int && count >= 0) return count;
    throw ApiException('Could not verify older chat deletion. Try again later.');
  }

  Future<String> extractMedicalText(XFile file) async {
    final result = await _sendImage('/api/v1/scan/medical-text', file);
    return (result['text'] as String?) ?? '';
  }

  // ---------------------------------------------------------------- public API

  Future<PrescriptionScan> scanPrescription(String reviewedText) async {
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

  Future<PrescriptionConfirmation> confirmMedication(Map<String, dynamic> draft) async {
    final account = draft['expected_account_id'];
    if (account == null || aiAccountId != account) {
      throw ApiException('Use the account that opened this medication.');
    }
    final result = await _postJson('/api/v1/medications/confirm', draft);
    if (aiAccountId != account) throw ApiException('Use the account that opened this medication.');
    return PrescriptionConfirmation.fromJson(result);
  }

  Future<ReportScan> scanReport(String reviewedText) async {
    return ReportScan.fromJson(await _postJson('/api/v1/scan/report', {'text': reviewedText, 'reviewed': true}));
  }

  Future<int> confirmLabReport(
    ReportScan scan,
    String? expectedUserId,
    DateTime? reviewedDate,
    List<LabResultDraft> reviewedRows,
  ) async {
    if (expectedUserId == null || aiAccountId != expectedUserId) {
      throw ApiException('Sign in to the account that opened this report.');
    }
    final data = await _postJson('/api/v1/scan/report/confirm', scan.toReviewedJson(
      expectedUserId: expectedUserId,
      reviewedDate: reviewedDate,
      reviewedRows: reviewedRows,
    ));
    if (data['saved'] != reviewedRows.length) {
      throw ApiException('Could not verify the save. Check Medical records before trying again.');
    }
    return reviewedRows.length;
  }

  Future<FoodScan> scanFood(XFile file) async {
    return FoodScan.fromJson(await _sendImage('/api/v1/scan/food', file, reviewed: true));
  }

  /// Local symptom check. The endpoint neither saves the draft nor sends it to AI.
  Future<String?> checkSymptomEmergency(SymptomDraft draft, String accountId) async {
    if (aiAccountId != accountId) throw ApiException('Open Symptoms from your signed-in account.');
    final data = await _postJson('/api/v1/symptoms/check', draft.safetyJson, timeout: const Duration(seconds: 8));
    if (aiAccountId != accountId) throw ApiException('Open Symptoms from your signed-in account.');
    final reply = data['reply'];
    if (data['emergency'] == false && reply == '') return null;
    if (data['emergency'] == true && reply is String && reply.trim().isNotEmpty) return reply;
    throw ApiException('NOVA could not complete the symptom safety check.');
  }

  /// Checks the question on NOVA's backend before AI consent or sharing.
  Future<String?> checkAssistantEmergency(String message) async {
    final data = await _postJson('/api/v1/assistant/chat', {
      'message': message,
      'emergency_only': true,
    }, timeout: const Duration(seconds: 8));
    final emergency = data['emergency'];
    final reply = data['reply'];
    if (emergency == false && reply == '') return null;
    if (emergency == true && reply is String && reply.trim().isNotEmpty) {
      return reply;
    }
    throw ApiException('NOVA could not check this message for an emergency.');
  }

  /// Sends a reviewed message and returns NOVA's reply and its source labels.
  Future<AssistantReply> chat(String message, {List<String> healthData = const [], List<String> recentQuestions = const []}) async {
    final data = await _postJson('/api/v1/assistant/chat', {
      'message': message,
      'reviewed': true,
      'health_data': healthData,
      if (healthData.any((kind) => kind == 'logs' || kind == 'heart_rate'))
        'local_calendar': deviceCalendar(DateTime.now()),
      'recent_questions': recentQuestions,
    });
    return AssistantReply.fromJson(data);
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Duration timeout = const Duration(seconds: 60),
  }) => _requestJson('GET', path, timeout: timeout);

  /// GET /api/v1/reports/daily?date=YYYY-MM-DD → the NOVA summary text for that day.
  Future<String> dailyReport(DateTime day) async {
    final query = Uri(queryParameters: {
      'date': ymd(day),
      'start_offset_minutes': localBoundaryOffset(day).toString(),
      'end_offset_minutes': localBoundaryOffset(day, 1).toString(),
    }).query;
    final data = await _getJson('/api/v1/reports/daily?$query');
    return (data['report'] as String?) ?? '';
  }

  Future<EmergencyResult> triggerEmergencyDetailed() async {
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

class AssistantReply {
  const AssistantReply(this.text, {this.sources = const [], this.emergency = false});

  final String text;
  final List<String> sources;
  final bool emergency;

  static const _sourceLabels = {
    'water': 'Water logs',
    'sleep': 'Sleep logs',
    'mood': 'Mood logs',
    'meals': 'Meal logs',
    'symptoms': 'Symptom logs',
    'profile': 'Health profile',
    'medications': 'Medication records',
    'allergies': 'Allergy records',
    'medicine safety': 'Medication safety checks',
    'heart rate': 'Heart-rate records',
    'cycle': 'Period logs',
    'lab results': 'Lab results',
  };

  factory AssistantReply.fromJson(Map<String, dynamic> data) {
    final raw = data['sources'];
    final sources = <String>{};
    if (raw is List) {
      for (final source in raw.whereType<String>()) {
        if (_sourceLabels[source] case final label?) sources.add(label);
      }
    }
    final text = data['reply'];
    return AssistantReply(
      text is String ? text : '',
      sources: List.unmodifiable(sources),
      emergency: data['emergency'] == true,
    );
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
