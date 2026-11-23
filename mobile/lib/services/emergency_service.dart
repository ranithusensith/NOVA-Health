import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/care_models.dart';
import '../data/care_repository.dart';
import 'api_client.dart';

/// One device-local snapshot, accessible only by its signed-in owner.
class EmergencyContactCache {
  EmergencyContactCache({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                sharedPreferencesName: 'NovaEmergencyContacts',
              ),
              iOptions: IOSOptions(
                  accessibility: KeychainAccessibility.unlocked_this_device),
            );

  static const _key = 'nova.emergency.contacts';
  final FlutterSecureStorage _storage;
  Future<void> _pending = Future<void>.value();
  String? _owner;
  int _generation = 0;

  void setAccount(String? userId) {
    if (userId == _owner) return;
    final previous = _owner;
    _owner = userId;
    _generation++;
    if (previous != null) _schedule(() => _storage.delete(key: _key));
  }

  Future<void> _schedule(Future<void> Function() action) {
    // Keep failed platform operations out of logs and keep the queue usable.
    return _pending = _pending.then((_) => action()).catchError((Object _) {});
  }

  Future<List<EmergencyContact>?> _read(String owner) async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    final data = jsonDecode(value);
    if (data is! Map || data['owner'] != owner || data['contacts'] is! List)
      return null;
    return [
      for (final row in data['contacts'] as List)
        EmergencyContact.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  Future<List<EmergencyContact>?> read(String? owner) async {
    final generation = _generation;
    await _pending;
    if (owner == null || owner != _owner || generation != _generation)
      return null;
    try {
      final contacts = await _read(owner);
      return generation == _generation ? contacts : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> update(
    String owner,
    List<EmergencyContact> Function(List<EmergencyContact> existing) change,
  ) {
    final generation = _generation;
    return _schedule(() async {
      if (owner != _owner || generation != _generation) return;
      final existing = await _read(owner) ?? const [];
      if (generation != _generation) return;
      await _write(owner, change(existing));
    });
  }

  Future<void> replace(String owner, List<EmergencyContact> contacts) {
    final generation = _generation;
    return _schedule(() async {
      if (owner == _owner && generation == _generation)
        await _write(owner, contacts);
    });
  }

  Future<void> _write(String owner, List<EmergencyContact> contacts) =>
      _storage.write(
          key: _key,
          value: jsonEncode({
            'owner': owner,
            'contacts': [
              for (final contact in contacts)
                {
                  'id': contact.id,
                  'name': contact.name,
                  'phone': contact.phone
                },
            ],
          }));
}

class EmergencyService {
  EmergencyService._();

  static final instance = EmergencyService._();
  static const _channel = MethodChannel('nova_health/emergency');
  static const _message =
      'NOVA Health SOS: I need help. Please call me or come to me now.';

  final _cache = EmergencyContactCache();
  int _contactsRevision = 0;

  String? get accountId => Supabase.instance.client.auth.currentUser?.id;
  Stream<String?> get accountChanges =>
      Supabase.instance.client.auth.onAuthStateChange
          .map((_) => accountId)
          .distinct();
  bool get _supportsCache => Platform.isAndroid || Platform.isIOS;

  void attach() {
    if (!_supportsCache) return;
    var owner = accountId;
    _cache.setAccount(owner);
    if (owner != null) _prefetchContacts();
    accountChanges.listen(
      (current) {
        if (current == owner) return;
        owner = current;
        _cache.setAccount(current);
        if (current != null) _prefetchContacts();
      },
      onError: (Object _) {},
    );
  }

  void _prefetchContacts() {
    unawaited(refreshContacts().then<void>((_) {}, onError: (Object _) {}));
  }

  Future<List<EmergencyContact>?> cachedContacts() async =>
      _supportsCache ? _cache.read(accountId) : null;

  Future<List<EmergencyContact>?> refreshContacts() async {
    final owner = accountId;
    if (owner == null) return null;
    final revision = _contactsRevision;
    final contacts = await CareRepository.instance
        .emergencyContacts()
        .timeout(const Duration(seconds: 5));
    if (accountId != owner || revision != _contactsRevision) return null;
    if (_supportsCache) await _cache.replace(owner, contacts);
    return accountId == owner && revision == _contactsRevision
        ? contacts
        : null;
  }

  Future<void> addContact(
      {required String name,
      required String phone,
      String? relationship}) async {
    final owner = accountId;
    if (owner == null) throw StateError('Sign in to add a contact.');
    final contact = await CareRepository.instance.addEmergencyContact(
      name: name,
      phone: phone,
      relationship: relationship,
    );
    if (_supportsCache && accountId == owner) {
      _contactsRevision++;
      await _cache.update(
          owner,
          (contacts) =>
              [...contacts.where((c) => c.id != contact.id), contact]);
    }
  }

  Future<void> deleteContact(String contactId) async {
    final owner = accountId;
    if (owner == null) throw StateError('Sign in to remove a contact.');
    await CareRepository.instance.deleteEmergencyContact(contactId);
    if (_supportsCache && accountId == owner) {
      _contactsRevision++;
      await _cache.update(owner,
          (contacts) => contacts.where((c) => c.id != contactId).toList());
    }
  }

  Future<EmergencyResult> trigger() =>
      ApiClient.instance.triggerEmergencyDetailed();

  Future<EmergencyResult> checkStatus(String attemptId) =>
      ApiClient.instance.emergencyStatus(attemptId);

  Future<bool> openMessages(EmergencyContact contact) async {
    final phone = smsNumber(contact.phone);
    if (phone == null) return false;
    return await _channel.invokeMethod<bool>(
            'openSms', {'phone': phone, 'body': _message}) ??
        false;
  }

  Future<bool> call(String phone) {
    final cleaned = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    return launchUrl(Uri(scheme: 'tel', path: cleaned),
        mode: LaunchMode.externalApplication);
  }

  static String? smsNumber(String phone) {
    final text = phone.trim();
    if (!RegExp(r'^\+?[0-9().\s-]+$').hasMatch(text)) return null;
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7 || digits.length > 15) return null;
    return text.startsWith('+') ? '+$digits' : digits;
  }
}
