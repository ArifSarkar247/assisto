// p3docs — HTTP surface of the vault's end-to-end layer (backend
// core/vault_e2e.py). Every body here is ALREADY sealed on the phone: no PIN,
// recovery code, document key or plaintext ever travels (the server refuses
// them anyway).
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../config.dart';
import 'vault_e2e.dart';

/// Abstract so screens/tests can inject a fake (no network in tests).
abstract class VaultE2EBackend {
  Future<Map<String, dynamic>> state();
  Future<void> putRecovery(String wrap);
  Future<String?> getRecovery();
  Future<void> deleteRecovery();
  Future<Map<String, dynamic>> peerKey(int memberId);
  Future<Map<String, dynamic>> addHelper(int memberId, String wrap, String keyId);
  Future<void> deleteHelper(int wrapId);
  Future<Map<String, dynamic>> requestHelp(int wrapId, String publicKeyB64, String keyId);
  Future<Map<String, dynamic>?> helpRequest();
  Future<void> cancelHelp();
  Future<List<Map<String, dynamic>>> helpInbox();
  Future<Map<String, dynamic>> decideHelp(int id, {required bool approve, String? wrap});
  Future<Map<String, dynamic>> uploadSealed({
    required String docType,
    String? expiryDate,
    required bool expiryAlerts,
    required String box,
    Uint8List? file,
  });
  Future<Map<String, dynamic>> createShare(int docId, int hours, int maxOpens, Uint8List blob);
  Future<List<Map<String, dynamic>>> shares(int docId);
  Future<void> revokeShare(int id);
}

class ApiVaultE2EBackend implements VaultE2EBackend {
  final ApiClient api;
  ApiVaultE2EBackend(this.api);

  Map<String, String> get _auth => {
        if (api.token != null) 'Authorization': 'Token ${api.token}',
        'Accept-Language': api.lang ?? 'bn',
      };

  Never _throw(int code, String body) {
    String msg = 'HTTP $code';
    try {
      final j = jsonDecode(body);
      if (j is Map && j['detail'] != null) msg = '${j['detail']}';
    } catch (_) {}
    throw ApiException(msg, code);
  }

  @override
  Future<Map<String, dynamic>> state() => api.getJson('/vault/e2e/state');

  @override
  Future<void> putRecovery(String wrap) async {
    final r = await http.put(AppConfig.api('/vault/e2e/recovery'),
        headers: {..._auth, 'Content-Type': 'application/json'},
        body: jsonEncode({'blob': wrap}));
    if (r.statusCode < 200 || r.statusCode >= 300) _throw(r.statusCode, r.body);
  }

  @override
  Future<String?> getRecovery() async {
    final r = await http.get(AppConfig.api('/vault/e2e/recovery'), headers: _auth);
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _throw(r.statusCode, r.body);
    return (jsonDecode(r.body) as Map<String, dynamic>)['blob'] as String?;
  }

  @override
  Future<void> deleteRecovery() async {
    await api.deleteJson('/vault/e2e/recovery');
  }

  @override
  Future<Map<String, dynamic>> peerKey(int memberId) =>
      api.getJson('/circle/keys/peer/$memberId');

  @override
  Future<Map<String, dynamic>> addHelper(int memberId, String wrap, String keyId) =>
      api.postJsonRaw('/vault/e2e/helpers', {'member_id': memberId, 'blob': wrap, 'key_id': keyId});

  @override
  Future<void> deleteHelper(int wrapId) async {
    await api.deleteJson('/vault/e2e/helpers/$wrapId');
  }

  @override
  Future<Map<String, dynamic>> requestHelp(int wrapId, String publicKeyB64, String keyId) =>
      api.postJsonRaw('/vault/e2e/help/request',
          {'wrap_id': wrapId, 'public_key': publicKeyB64, 'key_id': keyId});

  @override
  Future<Map<String, dynamic>?> helpRequest() async {
    final j = await api.getJson('/vault/e2e/help/request');
    final r = j['request'];
    return r is Map ? r.cast<String, dynamic>() : null;
  }

  @override
  Future<void> cancelHelp() async {
    await api.postJson('/vault/e2e/help/cancel');
  }

  @override
  Future<List<Map<String, dynamic>>> helpInbox() async {
    final j = await api.getJson('/vault/e2e/help/inbox');
    return ((j['results'] as List?) ?? const []).whereType<Map>()
        .map((m) => m.cast<String, dynamic>()).toList();
  }

  @override
  Future<Map<String, dynamic>> decideHelp(int id, {required bool approve, String? wrap}) =>
      api.postJsonRaw('/vault/e2e/help/$id/${approve ? 'approve' : 'decline'}',
          {if (wrap != null) 'blob': wrap});

  @override
  Future<Map<String, dynamic>> uploadSealed({
    required String docType,
    String? expiryDate,
    required bool expiryAlerts,
    required String box,
    Uint8List? file,
  }) async {
    final req = http.MultipartRequest('POST', AppConfig.api('/documents/'));
    req.headers.addAll(_auth);
    req.fields['e2e'] = 'true';
    req.fields['title'] = '';
    req.fields['doc_type'] = docType;
    req.fields['expiry_alerts'] = expiryAlerts ? 'true' : 'false';
    // The expiry date travels in clear ONLY when its reminder is on.
    if (expiryAlerts && expiryDate != null && expiryDate.isNotEmpty) {
      req.fields['expiry_date'] = expiryDate;
    }
    req.fields['details'] = jsonEncode({'e2e': 1, 'box': box});
    if (file != null) {
      req.files.add(http.MultipartFile.fromBytes('file', file, filename: 'sealed.bin'));
    }
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode < 200 || res.statusCode >= 300) _throw(res.statusCode, res.body);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> createShare(int docId, int hours, int maxOpens, Uint8List blob) async {
    final req = http.MultipartRequest('POST', AppConfig.api('/vault/share'));
    req.headers.addAll(_auth);
    req.fields['document_id'] = '$docId';
    req.fields['hours'] = '$hours';
    req.fields['max_opens'] = '$maxOpens';
    req.files.add(http.MultipartFile.fromBytes('blob', blob, filename: 'share.bin'));
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode < 200 || res.statusCode >= 300) _throw(res.statusCode, res.body);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> shares(int docId) async {
    final j = await api.getJson('/vault/share?document_id=$docId');
    return ((j['results'] as List?) ?? const []).whereType<Map>()
        .map((m) => m.cast<String, dynamic>()).toList();
  }

  @override
  Future<void> revokeShare(int id) async {
    await api.postJson('/vault/share/$id/revoke');
  }
}

/// p3docs: a vault100 recovery code was (re)made while the end-to-end key is
/// open -> wrap the key under the SAME code and store that wrap (sealed) on
/// the server, so one code unlocks both. Silent no-op when the lock is off.
Future<bool> syncE2ERecoveryCode(VaultE2EBackend be, String code, {VaultE2E? keyring}) async {
  try {
    final w = await (keyring ?? VaultE2E.instance).wrapForCode(code);
    if (w == null) return false;
    await be.putRecovery(w);
    return true;
  } catch (_) {
    return false;
  }
}
