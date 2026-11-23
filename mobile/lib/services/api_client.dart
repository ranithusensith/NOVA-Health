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

  Future<Map<String, dynamic>> _sendImage(String path, XFile file) async {
    final request = http.MultipartRequest('POST', Uri.parse('${AppConfig.apiUrl}$path'))
      ..headers.addAll(_authHeaders)
      ..files.add(http.MultipartFile.fromBytes(
        'image',
        await file.readAsBytes(),
        filename: file.name,
      ));

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

  Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> payload) async {
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('${AppConfig.apiUrl}$path'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 60));
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

  // ---------------------------------------------------------------- public API
  // With USE_MOCK_API=true these return sample data, so the UI can be built
  // and tested without the backend or an AI key.

  Future<PrescriptionScan> scanPrescription(XFile file) async {
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
    return PrescriptionScan.fromJson(await _sendImage('/api/v1/scan/prescription', file));
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

  Future<ReportScan> scanReport(XFile file) async {
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
    return ReportScan.fromJson(await _sendImage('/api/v1/scan/report', file));
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
    return FoodScan.fromJson(await _sendImage('/api/v1/scan/food', file));
  }

  /// Sends a message to the AI assistant and returns its reply text.
  Future<String> chat(String message) async {
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return 'Sample reply: your sleep was short and water was low this week. '
          'Try an earlier bedtime and a glass of water now.\n\nGuidance, not medical advice.';
    }
    final data = await _postJson('/api/v1/assistant/chat', {'message': message});
    return (data['reply'] as String?) ?? '';
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final http.Response res;
    try {
      res = await http
          .get(Uri.parse('${AppConfig.apiUrl}$path'), headers: _authHeaders)
          .timeout(const Duration(seconds: 60));
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

  /// GET /api/v1/reports/daily?date=YYYY-MM-DD → the AI summary text for that day.
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

  /// POST /api/v1/emergency/trigger → how many contacts were notified.
  Future<int> triggerEmergency() async => (await triggerEmergencyDetailed()).notified;

  /// Same call, with the details. `delivered` is false when the server only logged the
  /// alert (no SMS service set up), so the app must open the phone's messages app instead.
  Future<EmergencyResult> triggerEmergencyDetailed() async {
    if (AppConfig.useMockApi) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return const EmergencyResult(notified: 0, total: 0, delivered: false);
    }
    final data = await _postJson('/api/v1/emergency/trigger', const {});
    return EmergencyResult(
      notified: (data['contacts_notified'] as num?)?.toInt() ?? 0,
      total: (data['contacts_total'] as num?)?.toInt() ?? 0,
      delivered: data['delivered'] == true,
    );
  }
}

/// What the server did with an SOS.
class EmergencyResult {
  const EmergencyResult({required this.notified, required this.total, required this.delivered});
  final int notified;
  final int total;
  final bool delivered;
}
