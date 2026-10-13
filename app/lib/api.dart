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
        msg = 'Something went wrong (${r.statusCode})';
      }
    } catch (_) {
      msg = 'Something went wrong (${r.statusCode})';
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

  Future<Map<String, dynamic>> agent(String text) async {
    final r = await _c.post(AppConfig.api('/agent'),
        headers: _headers(), body: jsonEncode({'text': text}));
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<List<Map<String, dynamic>>> alertsList() async {
    final r = await _c.get(AppConfig.api('/alerts'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  Future<void> deleteByModel(String model, int id) async {
    const paths = {
      'reminder': 'reminders', 'txn': 'transactions', 'loan': 'loans',
      'medicine': 'medicines', 'memory': 'memory', 'note': 'notes', 'todo': 'todos',
    };
    final p = paths[model];
    if (p == null) return;
    await _c.delete(AppConfig.api('/$p/$id/'), headers: _headers());
  }

  Future<Map<String, dynamic>> wrapped() async {
    final r = await _c.get(AppConfig.api('/wrapped'), headers: _headers());
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<Map<String, dynamic>> invite() async {
    final r = await _c.get(AppConfig.api('/invite'), headers: _headers());
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<Map<String, dynamic>> briefing() async {
    final r = await _c.get(AppConfig.api('/briefing'), headers: _headers());
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<List<Map<String, dynamic>>> medicinesToday() async {
    final r = await _c.get(AppConfig.api('/medicines/today'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  Future<void> medicineTaken(int id, String slot, {bool taken = true}) async {
    await _c.post(AppConfig.api('/medicines/$id/taken'),
        headers: _headers(),
        body: jsonEncode({'slot': slot, 'taken': taken}));
  }

  Future<Map<String, dynamic>> scamCheck(String message) async {
    final r = await _c.post(AppConfig.api('/scam/check'),
        headers: _headers(), body: jsonEncode({'message': message}));
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
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
      throw ApiException('Document upload failed (${streamed.statusCode})', streamed.statusCode);
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

  // ---------- P10 generic helpers for new endpoints ----------
  Future<Map<String, dynamic>> getJson(String path) async {
    final r = await _c.get(AppConfig.api(path), headers: _headers());
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    final r = await _c.post(AppConfig.api(path),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  // Monetization
  Future<Map<String, dynamic>> plan() => getJson('/me/plan');
  Future<Map<String, dynamic>> rewardedAd() => postJson('/credits/rewarded');
  Future<Map<String, dynamic>> joinWaitlist(String contact) =>
      postJson('/waitlist', {'contact': contact});

  // Watcher
  Future<Map<String, dynamic>> watchFeed() => getJson('/watch/feed');

  // Nearby + music/artist (voice)
  Future<Map<String, dynamic>> nearby(double lat, double lon, String type) =>
      getJson('/nearby?lat=$lat&lon=$lon&type=$type');
  Future<Map<String, dynamic>> favouriteArtist(String name,
          {String channelRss = ''}) =>
      postJson('/artist/favourite', {'name': name, 'channel_rss': channelRss});

  // Finance tools
  Future<Map<String, dynamic>> finance(String tool, Map<String, dynamic> args) =>
      postJson('/finance', {'tool': tool, ...args});

  // Guides, elderly, inbox, studio
  Future<Map<String, dynamic>> guides() => getJson('/guides');
  Future<Map<String, dynamic>> setElderly(bool v) =>
      postJson('/me/elderly', {'enabled': v});
  Future<Map<String, dynamic>> inboxStatus() => getJson('/inbox');
  Future<Map<String, dynamic>> studio(String kind, String prompt) =>
      postJson('/studio', {'kind': kind, 'prompt': prompt});

  // Business mode
  Future<Map<String, dynamic>> businessReply(String text) =>
      postJson('/business/reply', {'text': text});
  Future<Map<String, dynamic>> businessOrder(String text) =>
      postJson('/business/order', {'text': text});

  // Job hunter
  Future<Map<String, dynamic>> jobTailor(int id, {String extra = ''}) =>
      postJson('/jobs/$id/tailor', {'extra': extra});

  // Nominee
  Future<Map<String, dynamic>> nomineeActivate(int id, bool on) =>
      postJson('/nominees/$id/activate', {'activated': on});

  // Auto-pay
  Future<Map<String, dynamic>> autopayStopAll() => postJson('/autopay/stop-all');
}
