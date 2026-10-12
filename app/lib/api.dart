import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'models.dart';

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, [this.status]);
  @override
  String toString() => message;
}

/// Thin REST client for the Assisto backend. Token auth (DRF).
class ApiClient {
  String? token;
  final http.Client _c = http.Client();

  ApiClient({this.token});

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Token $token',
      };

  Never _fail(http.Response r) {
    String msg;
    try {
      final body = jsonDecode(r.body);
      if (body is Map && body['detail'] != null) {
        msg = body['detail'].toString();
      } else if (body is Map && body.isNotEmpty) {
        msg = body.values.first.toString();
      } else {
        msg = 'সমস্যা হয়েছে (${r.statusCode})';
      }
    } catch (_) {
      msg = 'সমস্যা হয়েছে (${r.statusCode})';
    }
    throw ApiException(msg, r.statusCode);
  }

  Future<Map<String, dynamic>> _postJson(String path, Map body,
      {bool auth = true}) async {
    final r = await _c.post(AppConfig.api(path),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  // ---- auth ----
  Future<({String token, AppUser user})> register({
    required String name,
    String? phone,
    String? email,
    required String password,
  }) async {
    final j = await _postJson('/auth/register', {
      'name': name,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      'password': password,
    });
    return (token: j['token'] as String, user: AppUser.fromJson(j['user']));
  }

  Future<({String token, AppUser user})> login({
    required String identifier,
    required String password,
  }) async {
    final j = await _postJson(
        '/auth/login', {'identifier': identifier, 'password': password});
    return (token: j['token'] as String, user: AppUser.fromJson(j['user']));
  }

  Future<void> logout() async {
    try {
      await _c.post(AppConfig.api('/auth/logout'), headers: _headers());
    } catch (_) {}
  }

  Future<AppUser> me() async {
    final r = await _c.get(AppConfig.api('/me'), headers: _headers());
    if (r.statusCode == 200) return AppUser.fromJson(jsonDecode(r.body));
    _fail(r);
  }

  Future<AppUser> updateProfile(Map<String, dynamic> fields) async {
    final r = await _c.patch(AppConfig.api('/me'),
        headers: _headers(), body: jsonEncode(fields));
    if (r.statusCode == 200) return AppUser.fromJson(jsonDecode(r.body));
    _fail(r);
  }

  // ---- memory ----
  Future<List<Map<String, dynamic>>> listMemory() async {
    final r = await _c.get(AppConfig.api('/memory/'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  Future<Map<String, dynamic>> createMemory(Map<String, dynamic> body) async {
    final r = await _c.post(AppConfig.api('/memory/'),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  Future<void> updateMemory(int id, Map<String, dynamic> body) async {
    final r = await _c.patch(AppConfig.api('/memory/$id/'),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode < 200 || r.statusCode >= 300) _fail(r);
  }

  Future<void> deleteMemory(int id) async {
    final r = await _c.delete(AppConfig.api('/memory/$id/'), headers: _headers());
    if (r.statusCode != 204 && r.statusCode != 404) _fail(r);
  }

  // ---- generic synced collections (reminders / notes / todos) ----
  Future<List<Map<String, dynamic>>> listItems(String path) async {
    final r = await _c.get(AppConfig.api('/$path/'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) async {
    final r = await _c.post(AppConfig.api('/$path/'),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  Future<void> updateItem(String path, int id, Map<String, dynamic> body) async {
    final r = await _c.patch(AppConfig.api('/$path/$id/'),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode < 200 || r.statusCode >= 300) _fail(r);
  }

  Future<void> deleteItem(String path, int id) async {
    final r = await _c.delete(AppConfig.api('/$path/$id/'), headers: _headers());
    if (r.statusCode != 204 && r.statusCode != 404) _fail(r);
  }

  Future<Map<String, dynamic>> moneySummary() async {
    final r = await _c.get(AppConfig.api('/money/summary'), headers: _headers());
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<bool> undo() async {
    final r = await _c.post(AppConfig.api('/undo'), headers: _headers());
    return r.statusCode == 200;
  }

  Future<List<Map<String, dynamic>>> sources() async {
    final r = await _c.get(AppConfig.api('/sources'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  Future<void> toggleSource(String source, bool enabled) async {
    await _c.post(AppConfig.api('/sources'),
        headers: _headers(), body: jsonEncode({"source": source, "enabled": enabled}));
  }

  Future<void> sendSupport(String kind, String message, String appVersion) async {
    await _c.post(AppConfig.api('/support/'),
        headers: _headers(), body: jsonEncode(
            {"kind": kind, "message": message, "app_version": appVersion}));
  }

  // ---- audit / data ----
  Future<List<AuditEntry>> audit() async {
    final r = await _c.get(AppConfig.api('/audit'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List)
          .map((e) => AuditEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    _fail(r);
  }

  // ---- documents (vault) ----
  Future<List<Map<String, dynamic>>> listDocuments() async {
    final r = await _c.get(AppConfig.api('/documents/'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  Future<void> uploadDocument({
    required String title,
    required String docType,
    String? expiryDate,
    String? note,
    required String filePath,
  }) async {
    final req = http.MultipartRequest('POST', AppConfig.api('/documents/'));
    if (token != null) req.headers['Authorization'] = 'Token $token';
    req.fields['title'] = title;
    req.fields['doc_type'] = docType;
    if (expiryDate != null && expiryDate.isNotEmpty) req.fields['expiry_date'] = expiryDate;
    if (note != null && note.isNotEmpty) req.fields['note'] = note;
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed = await req.send();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw ApiException('ডকুমেন্ট আপলোড ব্যর্থ (${streamed.statusCode})', streamed.statusCode);
    }
  }

  Future<void> createDocument({
    required String title,
    required String docType,
    String? expiryDate,
    String? note,
  }) async {
    final r = await _c.post(AppConfig.api('/documents/'),
        headers: _headers(),
        body: jsonEncode({
          'title': title,
          'doc_type': docType,
          if (expiryDate != null && expiryDate.isNotEmpty) 'expiry_date': expiryDate,
          if (note != null && note.isNotEmpty) 'note': note,
        }));
    if (r.statusCode < 200 || r.statusCode >= 300) _fail(r);
  }

  Future<void> deleteDocument(int id) async {
    final r = await _c.delete(AppConfig.api('/documents/$id/'), headers: _headers());
    if (r.statusCode != 204 && r.statusCode != 404) _fail(r);
  }

  // ---- emergency card ----
  Future<Map<String, dynamic>> getEmergency() async {
    final r = await _c.get(AppConfig.api('/emergency'), headers: _headers());
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<void> putEmergency(Map<String, dynamic> body) async {
    final r = await _c.put(AppConfig.api('/emergency'),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode < 200 || r.statusCode >= 300) _fail(r);
  }

  Future<List<int>> getBytes(String path) async {
    final r = await _c.get(AppConfig.api(path),
        headers: {if (token != null) 'Authorization': 'Token $token'});
    if (r.statusCode == 200) return r.bodyBytes;
    _fail(r);
  }

  Future<String> exportRaw() async {
    final r = await _c.get(AppConfig.api('/export'), headers: _headers());
    if (r.statusCode == 200) return r.body;
    _fail(r);
  }

  Future<void> deleteAccount() async {
    final r = await _c.delete(AppConfig.api('/account'), headers: _headers());
    if (r.statusCode != 204) _fail(r);
  }
}
