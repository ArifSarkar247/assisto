import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'feature_gates.dart' show kMedicalFeaturesAllowed;
import 'crypto/e2e.dart';
import 'models.dart';
import 'services/own_device_guard.dart'; // grab-guard

class ApiException implements Exception {
  final String message;
  final int? status;

  /// Server-supplied correlation reference (e.g. CRM error ref code). Parsed
  /// from `body['ref']` in [ApiClient._fail] when present; null otherwise.
  final String? ref;
  ApiException(this.message, [this.status, this.ref]);
  @override
  String toString() => message;
}

/// Thin REST client for the Assisto backend. Token auth (DRF).
class ApiClient {
  String? _token;
  String? lang; // 'bn'|'en' -> Accept-Language (follows selected locale)
  final http.Client _c = http.Client();

  ApiClient({String? token}) {
    this.token = token;
  }

  /// A client for background cleanup with an OLD session's token: it does not
  /// touch [AppConfig.authToken], so the signed-out app never reuses it.
  ApiClient.detached(String token) : _token = token;

  String? get token => _token;

  /// Setting the token also mirrors it into [AppConfig.authToken] so avatar
  /// image widgets can authenticate against our own backend's media views.
  set token(String? v) {
    _token = v;
    AppConfig.authToken = v;
  }

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Token $token',
        'Accept-Language': lang ?? 'bn',
        // play-nomed: tells the server this is the Play build (no medicine
        // schedules from chat, no medicine suggestions). The website APK
        // sends nothing extra.
        if (AppConfig.playStore) 'X-Assisto-Flavour': 'play',
        // own-device: lets the server see a request comes FROM the protected
        // phone itself (hashed install id, never a hardware id)
        if (AppConfig.deviceId != null && AppConfig.deviceId!.isNotEmpty)
          'X-Device-Id': AppConfig.deviceId!,
      };

  Never _fail(http.Response r) {
    String msg;
    String? ref;
    try {
      final body = jsonDecode(r.body);
      if (body is Map) {
        if (body['ref'] != null) ref = body['ref'].toString();
        if (body['detail'] != null) {
          msg = body['detail'].toString();
        } else if (body.isNotEmpty) {
          // Prefer a human message field over the ref itself.
          final firstMsg = body.entries
              .firstWhere((e) => e.key != 'ref', orElse: () => body.entries.first);
          msg = firstMsg.value.toString();
        } else {
          msg = 'Something went wrong (${r.statusCode})';
        }
      } else {
        msg = 'Something went wrong (${r.statusCode})';
      }
    } catch (_) {
      msg = 'Something went wrong (${r.statusCode})';
    }
    throw ApiException(msg, r.statusCode, ref);
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
    String? otpProof,
  }) async {
    final j = await _postJson('/auth/register', {
      'name': name,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      'password': password,
      if (otpProof != null && otpProof.isNotEmpty) 'otp_proof': otpProof,
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
  // Insert the trailing slash BEFORE any query string. Building '/$path/'
  // naively turns 'crm/leads?org=7' into '/crm/leads?org=7/', which Django's
  // APPEND_SLASH 301-redirects into '/crm/leads/?org=7/' — moving the slash
  // into the query value ('org=7/') and 500ing the view. Split first.
  static String _withSlash(String path) {
    final q = path.indexOf('?');
    if (q < 0) return '/$path/';
    return '/${path.substring(0, q)}/${path.substring(q)}';
  }

  Future<List<Map<String, dynamic>>> listItems(String path) async {
    final r = await _c.get(AppConfig.api(_withSlash(path)), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) async {
    final r = await _c.post(AppConfig.api(_withSlash(path)),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  Future<void> updateItem(String path, int id, Map<String, dynamic> body) async {
    final r = await _c.patch(AppConfig.api(_withSlash('$path/$id')),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode < 200 || r.statusCode >= 300) _fail(r);
  }

  Future<void> deleteItem(String path, int id) async {
    final r = await _c.delete(AppConfig.api(_withSlash('$path/$id')), headers: _headers());
    if (r.statusCode != 204 && r.statusCode != 404) _fail(r);
  }

  /// Home agent turn. [sessionId] keeps the home conversation in one saved
  /// thread (sidebar history); the reply carries the `session_id` to reuse.
  Future<Map<String, dynamic>> agent(String text, {String? sessionId}) async {
    final r = await _c.post(AppConfig.api('/agent'),
        headers: _headers(),
        body: jsonEncode({'text': text, if (sessionId != null) 'session_id': sessionId}));
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  Future<List<Map<String, dynamic>>> alertsList() async {
    final r = await _c.get(AppConfig.api('/alerts'), headers: _headers());
    if (r.statusCode == 200) {
      final all = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      // play-nomed: no medicine refill alerts in the Play flavour (watch feed,
      // proactive AI, chat and the foreground poller all read this list).
      // grab-guard: never an anti-theft row about this user's OWN phone
      // (every reader — poller, urgent card, watch feed — goes through here).
      final mine = await OwnDeviceGuard.filterAlerts(all);
      if (kMedicalFeaturesAllowed) return mine;
      return mine.where((a) => '${a['type']}' != 'refill').toList();
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

  Future<void> medicineTaken(int id, String slot,
      {bool taken = true, bool skipped = false}) async {
    await _c.post(AppConfig.api('/medicines/$id/taken'),
        headers: _headers(),
        body: jsonEncode({'slot': slot, 'taken': taken, 'skipped': skipped}));
  }

  // ---- medicine: adherence history, caregiver dashboard, escalation ----
  Future<Map<String, dynamic>> medicineHistory({String? member}) =>
      getJson('/medicines/history${member != null ? '?member=$member' : ''}');

  Future<Map<String, dynamic>> caregiverDashboard() =>
      getJson('/medicines/caregiver');

  Future<Map<String, dynamic>> medicineEscalation(int id, {String? slot}) =>
      getJson('/medicines/$id/escalation${slot != null ? '?slot=$slot' : ''}');

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

  // ==========================================================================
  // Secure "Delete my profile & all data" (Play-compliant). This is the NEW,
  // multi-factor, cancellable, theft-safe flow that REPLACES the one-tap
  // [deleteAccount] above in the UI (that DELETE path is left only for legacy /
  // tests — the app routes everything through DeleteAccountScreen now).
  //
  // Backend contract (see views_account_deletion.py):
  //   POST account/delete/preview -> {counts:{type:n}, export_downloaded}
  //   POST account/delete/request {password, otp, security_pin?, lat?, lng?}
  //        -> {state:'pending', effective_at, id}
  //         | 423 {state:'blocked', reason:'theft_signal'|'frozen'}
  //         | 403/400 {ok:false, reason:'bad_password'|'bad_otp'|'bad_pin'}
  //   POST account/delete/cancel {token?} -> {ok, state}
  //   GET  account/delete/status -> {state, effective_at} | {state:null}
  // ==========================================================================

  /// What a deletion would remove — counts per data type, plus whether an
  /// export was already downloaded. No side effects.
  Future<Map<String, dynamic>> accountDeletePreview() =>
      postJson('/account/delete/preview');

  /// Schedule the deletion. Issues a RAW POST (like [securityAction]) because
  /// the 423 (blocked) and 403/400 (bad_password/bad_otp/bad_pin) bodies carry
  /// the interpretable result; [_status] is merged in so the caller can branch
  /// on it instead of catching a generic failure.
  Future<Map<String, dynamic>> accountDeleteRequest({
    required String password,
    String? otp,
    String? otpProof,
    String? securityPin,
    double? lat,
    double? lng,
  }) async {
    final r = await _c.post(AppConfig.api('/account/delete/request'),
        headers: _headers(),
        body: jsonEncode({
          'password': password,
          if (otp != null && otp.isNotEmpty) 'otp': otp,
          if (otpProof != null && otpProof.isNotEmpty) 'otp_proof': otpProof,
          if (securityPin != null && securityPin.isNotEmpty)
            'security_pin': securityPin,
          if (lat != null) 'lat': lat,
          if (lng != null) 'lng': lng,
        }));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    // 400/403 (bad_password/bad_otp/bad_pin) and 423 (blocked) are meaningful,
    // interpretable results — surface the parsed body with its status.
    if (r.statusCode == 400 || r.statusCode == 403 || r.statusCode == 423) {
      final body = r.body.isEmpty ? {} : jsonDecode(r.body);
      if (body is Map<String, dynamic>) {
        return {...body, '_status': r.statusCode};
      }
    }
    _fail(r);
  }

  /// Cancel a pending deletion. Authed owner, or a one-tap [token] from the
  /// "this wasn't me" alert. -> {ok, state}.
  Future<Map<String, dynamic>> accountDeleteCancel({String? token}) =>
      postJson('/account/delete/cancel',
          {if (token != null && token.isNotEmpty) 'token': token});

  /// Current deletion request, if any -> {state:'pending'|'cancelled'|
  /// 'completed', effective_at} | {state:null}.
  Future<Map<String, dynamic>> accountDeleteStatus() =>
      getJson('/account/delete/status');

  /// dl1: signed in during the grace period and chose "Delete now and start
  /// fresh". POST account/delete/start-fresh {password, confirm_text,
  /// otp_proof?} -> 201 {token, user, start_fresh} | 400/403/409/423 bodies
  /// ({reason: confirm_required|bad_password|otp_required|bad_otp|no_pending}
  /// or {state: blocked}) returned with `_status` so the screen can branch.
  Future<Map<String, dynamic>> accountStartFresh({
    required String password,
    required String confirmText,
    String? otpProof,
  }) async {
    final r = await _c.post(AppConfig.api('/account/delete/start-fresh'),
        headers: _headers(),
        body: jsonEncode({
          'password': password,
          'confirm_text': confirmText,
          if (otpProof != null && otpProof.isNotEmpty) 'otp_proof': otpProof,
        }));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    if (const [400, 403, 409, 423].contains(r.statusCode)) {
      final body = r.body.isEmpty ? {} : jsonDecode(r.body);
      if (body is Map<String, dynamic>) {
        return {...body, '_status': r.statusCode};
      }
    }
    _fail(r);
  }

  /// Request a one-time code for [identifier] (phone or email) — hits the SAME
  /// existing endpoint the login/reset OTP flow uses (OTPRequestView). When no
  /// SMS provider is configured the server degrades gracefully (503 +
  /// sms_enabled:false) and account deletion treats OTP as satisfied-if-absent.
  /// Returns the parsed body (incl. {sms_enabled:false}) rather than throwing
  /// on the degraded 503, so the UI can tell the user OTP is simply off.
  Future<Map<String, dynamic>> requestOtp(String identifier) async {
    final r = await _c.post(AppConfig.api('/auth/otp/request'),
        headers: _headers(), body: jsonEncode({'identifier': identifier}));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    if (r.statusCode == 503 || r.statusCode == 501) {
      final body = r.body.isEmpty ? {} : jsonDecode(r.body);
      if (body is Map<String, dynamic>) {
        return {...body, '_status': r.statusCode, 'sms_enabled': false};
      }
    }
    _fail(r);
  }

  // ---------- P10 generic helpers for new endpoints ----------
  Future<Map<String, dynamic>> getJson(String path) async {
    final r = await _c.get(AppConfig.api(path), headers: _headers());
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    _fail(r);
  }

  /// feature-flags: conditional GET. Sends If-None-Match when [etag] is set;
  /// a 304 comes back as (status: 304, body: null). Other errors throw.
  Future<({int status, Map<String, dynamic>? body, String? etag})>
      getJsonEtag(String path, String? etag) async {
    final r = await _c.get(AppConfig.api(path), headers: {
      ..._headers(),
      if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
    });
    if (r.statusCode == 304) {
      return (status: 304, body: null, etag: r.headers['etag'] ?? etag);
    }
    if (r.statusCode == 200) {
      return (
        status: 200,
        body: jsonDecode(r.body) as Map<String, dynamic>,
        etag: r.headers['etag'],
      );
    }
    _fail(r);
  }

  // ---- o1-otp ----
  /// POST that never throws on an HTTP error status: returns the parsed body
  /// with `_status` merged in (OTP endpoints carry reason / retry_after /
  /// attempts_left in their 4xx/5xx bodies). Network failures still throw.
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    final r = await _c.post(AppConfig.api(path),
        headers: _headers(), body: jsonEncode(body));
    Map<String, dynamic> out = {};
    try {
      final j = r.body.isEmpty ? null : jsonDecode(r.body);
      if (j is Map<String, dynamic>) out = j;
    } catch (_) {}
    return {...out, '_status': r.statusCode};
  }
  // ---- /o1-otp ----

  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    final r = await _c.post(AppConfig.api(path),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      _e2AfterPost(path, body);
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  // ---- e2-keys ----
  /// Fired after ANY successful My Circle accept (request act=accept on the
  /// circle or messenger path, or an invite redeem) so the device publishes
  /// its public key at once — wired by crypto/key_wiring.dart.
  static void Function()? onRequestAccepted;
  static final RegExp _e2AcceptPath =
      RegExp(r'^/(circle|messenger)/request/\d+/act$');

  void _e2AfterPost(String path, Map<String, dynamic> body) {
    try {
      if ((body['event'] == 'accept' && _e2AcceptPath.hasMatch(path)) ||
          path == '/circle/invite/redeem') {
        onRequestAccepted?.call();
      }
    } catch (_) {}
  }
  // ---- /e2-keys ----

  /// Mirror of [postJson] but issues an HTTP PATCH. Messenger edit/setting
  /// endpoints (channel edit, community group update, /me/* privacy toggles)
  /// are modelled as PATCH on the backend; this hits those real handlers
  /// instead of a non-existent POST (405). The slash stays before any query
  /// string exactly as [AppConfig.api] produces it.
  Future<Map<String, dynamic>> patchJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    final r = await _c.patch(AppConfig.api(path),
        headers: _headers(), body: jsonEncode(body));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  /// v1-vehicle: generic DELETE on an exact path (no slash rewriting, unlike
  /// [deleteItem]) returning the JSON body. Non-2xx -> ApiException.
  Future<Map<String, dynamic>> deleteJson(String path) async {
    final r = await _c.delete(AppConfig.api(path), headers: _headers());
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

  // ---- Shop Box / CCTV loss-prevention (Part 4, Business tier) ----
  // Signals-only, privacy-first: NO video. These wrap the owner-side endpoints
  // (normal Token auth). Paths carry NO trailing slash — the shop views are
  // registered without one, so getJson/postJson/patchJson (which do not add a
  // slash) hit them directly.
  Future<Map<String, dynamic>> shopSites() => getJson('/shop/sites');

  Future<Map<String, dynamic>> shopCreateSite(String name, int retentionDays) =>
      postJson('/shop/sites',
          {'name': name, 'snapshot_retention_days': retentionDays});

  Future<Map<String, dynamic>> shopUpdateSite(int id,
          {String? name, int? retentionDays}) =>
      patchJson('/shop/sites/$id', {
        if (name != null) 'name': name,
        if (retentionDays != null) 'snapshot_retention_days': retentionDays,
      });

  Future<Map<String, dynamic>> shopCameras(int siteId) =>
      getJson('/shop/sites/$siteId/cameras');

  /// Add a camera. The server returns 402 with `code:"camera_cap"` + the
  /// credit figures when the included-camera cap is hit. We must NOT crash on
  /// that, so this issues a raw POST and returns the parsed JSON for BOTH 2xx
  /// and 402, with an `_ok` flag + `_status` the caller inspects. Other
  /// non-2xx still throw via [_fail] (real errors).
  Future<Map<String, dynamic>> shopAddCamera(int siteId,
      {required String name, String? kind, bool enabled = true}) async {
    final r = await _c.post(AppConfig.api('/shop/sites/$siteId/cameras'),
        headers: _headers(),
        body: jsonEncode({
          'name': name,
          if (kind != null) 'kind': kind,
          'enabled': enabled,
        }));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      final body = r.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(r.body) as Map<String, dynamic>;
      return {...body, '_ok': true, '_status': r.statusCode};
    }
    if (r.statusCode == 402) {
      final body = r.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(r.body) as Map<String, dynamic>;
      return {...body, '_ok': false, '_status': 402};
    }
    _fail(r);
  }

  Future<Map<String, dynamic>> shopEvents(int siteId, {String? status}) =>
      getJson('/shop/events?site=$siteId'
          '${status != null ? '&status=$status' : ''}');

  Future<Map<String, dynamic>> shopMarkEvent(int eventId, String status) =>
      postJson('/shop/events/$eventId/mark', {'status': status});

  Future<Map<String, dynamic>> shopSummary(int siteId, {int days = 7}) =>
      getJson('/shop/summary?site=$siteId&days=$days');

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

  Future<Map<String, dynamic>> moneyTrends() => getJson('/money/trends');
  Future<Map<String, dynamic>> moneyNetWorth() => getJson('/money/networth');
  Future<Map<String, dynamic>> moneyBudgetDetail(String category) =>
      getJson('/money/budget?category=${Uri.encodeQueryComponent(category)}');
  Future<Map<String, dynamic>> moneyReport() => getJson('/money/report');
  Future<Map<String, dynamic>> moneyParse(String text) =>
      postJson('/money/parse', {'text': text});
  Future<Map<String, dynamic>> moneyLearnCategory(String counterparty, String category) =>
      postJson('/money/learn-category',
          {'counterparty': counterparty, 'category': category});
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

  // ---- plans (public plan catalogue) ----
  Future<List<Map<String, dynamic>>> plansPublic() async {
    final r = await _c.get(AppConfig.api('/plans'), headers: _headers());
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  // ==========================================================================
  // Business Model Build 3 — plans / credits / storage / ads / owner P&L.
  //
  // HONESTY: the server is the authority on every price, credit count and
  // state. No payment provider or AdMob key is wired yet, so top-up and
  // rewarded-ad endpoints return an HONEST non-confirmed state
  // (`needs_provider` / a not-configured flag) — the UI must surface that and
  // NEVER fake a checkout, an ad, or a reward. All helpers are thin wrappers on
  // [getJson]/[postJson]; non-200s throw [ApiException] which screens interpret
  // (e.g. 403 -> owner-only for the P&L dashboard).
  // ==========================================================================

  /// GET /plans (localized) -> [{code, name, price, desc/benefits, included
  /// credits/pool}]. Alias of [plansPublic] so callers can use the name from
  /// the build spec without knowing the legacy method.
  Future<List<Map<String, dynamic>>> plansList() => plansPublic();

  /// GET /credits/packs -> [{id/code, taka, credits, valid_months}].
  Future<List<Map<String, dynamic>>> creditsPacks() async {
    // pay1: the server answers `purchasable` for THIS build's channels.
    final flavour = AppConfig.playStore ? 'play' : 'apk';
    final r = await _c.get(AppConfig.api('/credits/packs?flavour=$flavour'),
        headers: _headers());
    if (r.statusCode == 200) {
      final body = jsonDecode(r.body);
      // NO SHOWPIECES: no LIVE payment channel (pay1) -> no buy buttons (the
      // screen shows "no top-up packs right now"). Older servers omit the
      // flag and keep the old behaviour.
      if (body is Map && body['purchasable'] == false) {
        return const <Map<String, dynamic>>[];
      }
      final list = body is Map ? (body['packs'] ?? body['items'] ?? []) : body;
      return (list as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  /// POST /credits/topup {pack} -> {state:'pending'|'needs_provider'|
  /// 'confirmed', ...}. HONEST: with no payment provider configured the server
  /// returns `needs_provider`; this wrapper returns that body as-is so the UI
  /// shows the "payment setup pending" state instead of a broken checkout.
  Future<Map<String, dynamic>> creditsTopup(String pack) =>
      postJson('/credits/topup', {'pack': pack});

  /// GET /credits/history -> {balance, items:[ledger], expiry_buckets}.
  Future<Map<String, dynamic>> creditsHistory() => getJson('/credits/history');

  /// GET /me/usage-summary -> {plan, balance, ad_wallet_credits, included_pool,
  /// month_usage:[{action,credits}], month_total, storage:{used, quota_bytes,
  /// pct, full}}.
  Future<Map<String, dynamic>> meUsageSummary() => getJson('/me/usage-summary');

  /// GET /storage/meter -> {used, quota_bytes, pct, full}.
  Future<Map<String, dynamic>> storageMeter() => getJson('/storage/meter');

  /// GET /ads/wallet -> {balance_credits, caps:{app_open_next_ts,
  /// rewarded_today, rewarded_cap}}.
  Future<Map<String, dynamic>> adsWallet() => getJson('/ads/wallet');

  /// POST /ads/event {kind:'rewarded'} -> credits the ad wallet. AdMob-key
  /// gated: when ads are not enabled the server returns a not-configured state
  /// (e.g. {enabled:false} / {ok:false}) rather than crediting — the UI shows
  /// the honest "ads not set up yet" message and NEVER fakes a reward.
  Future<Map<String, dynamic>> adsEvent(String kind) =>
      postJson('/ads/event', {'kind': kind});

  /// GET /admin/pnl?days=N (OWNER only; 403 otherwise) -> {series, totals,
  /// segments, margin_per_feature, break_even, guard, alerts}. The 403 surfaces
  /// as [ApiException] with status 403 so the screen can show its owner-only
  /// state, matching the admin-flags console.
  Future<Map<String, dynamic>> adminPnl({int days = 30}) =>
      getJson('/admin/pnl?days=$days');

  /// GET /app/home-defaults -> {quick_buttons: [route x6], count} — the
  /// owner's default home shortcuts (used only until the user customizes).
  Future<Map<String, dynamic>> homeDefaults() =>
      getJson('/app/home-defaults');

  // ---- reminders NL parse (server-of-truth; UI also parses offline) ----
  Future<Map<String, dynamic>> parseReminder(String text) =>
      postJson('/reminders/parse', {'text': text});

  // ---- memory semantic/keyword search ----
  Future<List<Map<String, dynamic>>> searchMemoryApi(String q) async {
    final r = await _c.get(
        AppConfig.api('/memory/search?q=${Uri.encodeQueryComponent(q)}'),
        headers: _headers());
    if (r.statusCode == 200) {
      final body = jsonDecode(r.body);
      final list = body is Map ? (body['results'] ?? body['items'] ?? []) : body;
      return (list as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  // ---- module-5 launch gaps: password reset (neutral, no enumeration) ----
  /// POST /auth/reset/request {email} -> {message} (always neutral).
  Future<Map<String, dynamic>> requestPasswordReset(String email) =>
      postJson('/auth/reset/request', {'email': email});

  /// POST /auth/reset/confirm {token, password} -> {ok, message}.
  Future<Map<String, dynamic>> confirmPasswordReset(
          String token, String password) =>
      postJson('/auth/reset/confirm', {'token': token, 'password': password});

  // ---- module-5 launch gaps: legal viewer (DRAFT pages) ----
  /// GET /legal -> [{key, title, stamp}, ...].
  Future<List<Map<String, dynamic>>> legalIndex() async {
    final r = await getJson('/legal');
    return ((r['pages'] ?? r['index'] ?? []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// GET /legal/<key> -> {key, title, body, stamp, last_updated}.
  Future<Map<String, dynamic>> legalPage(String key) => getJson('/legal/$key');

  // ---- module-5 launch gaps: Unseen Bangladesh travel companion ----
  /// GET /unseen -> {destinations[], tips[], attribution}.
  Future<Map<String, dynamic>> unseenCompanion() => getJson('/unseen');

  // ---- M1: referral points ----
  /// GET /referral/balance -> {points, redeemable_days, points_per_day,
  /// min_redeem, can_redeem, invite_link?}.
  Future<Map<String, dynamic>> referralBalance() => getJson('/referral/balance');

  /// GET /referral/history -> {history:[{kind, points, reason, label,
  /// created_at}, ...]}.
  Future<Map<String, dynamic>> referralHistory() => getJson('/referral/history');

  /// POST /referral/redeem {points} -> {ok, days, spent, points, ...}.
  Future<Map<String, dynamic>> referralRedeem(int points) =>
      postJson('/referral/redeem', {'points': points});

  // ---- M1: Connected Circle calls ----
  /// GET /circle/calls -> {calls:[...]}.
  Future<Map<String, dynamic>> circleCalls() => getJson('/circle/calls');

  /// POST /circle/<member>/call {kind} -> {allowed, upgrade_required?, call_id?,
  /// ice?, transport?}. Server enforces the video plan gate.
  Future<Map<String, dynamic>> circlePlaceCall(int memberId, String kind) =>
      postJson('/circle/$memberId/call', {'kind': kind});

  /// POST /circle/<member>/call/answer {kind} -> same shape as place-call.
  Future<Map<String, dynamic>> circleAnswerCall(int memberId, String kind) =>
      postJson('/circle/$memberId/call/answer', {'kind': kind});

  /// POST /circle/calls/<id>/event {event} -> {state, duration_sec?}.
  Future<Map<String, dynamic>> circleCallEvent(int callId, String event) =>
      postJson('/circle/calls/$callId/event', {'event': event});

  // ---- M1: Connected Circle privacy ----
  /// GET /circle/privacy -> {visibility, read_receipts, typing, call_policy, ...}.
  Future<Map<String, dynamic>> circlePrivacy() => getJson('/circle/privacy');

  /// POST /circle/privacy {...} -> saved privacy config.
  Future<Map<String, dynamic>> circleSetPrivacy(Map<String, dynamic> body) =>
      postJson('/circle/privacy', body);

  /// POST /circle/<member>/controls {blocked?, restricted?, muted_until?,
  /// pinned?, archived?} -> updated member controls.
  Future<Map<String, dynamic>> circleSetMemberControls(
          int memberId, Map<String, dynamic> body) =>
      postJson('/circle/$memberId/controls', body);

  // ==========================================================================
  // M2: Connected Circle messenger — GROUPS (item 7)
  // Server is the authority (core/logic/circle_groups.py); every endpoint
  // re-enforces membership + role. All message/poll bodies are E2E ciphertext
  // fanned out per-recipient — the server never sees plaintext.
  // ==========================================================================

  /// GET /circle/groups -> {groups:[{id, name, member_count, pinned_count,
  /// announcements_only, my_role, ...}]}.
  Future<Map<String, dynamic>> circleGroups() => getJson('/circle/groups');

  /// POST /circle/groups {name, description?, member_ids[], announcements_only?}
  /// -> the created group. Members must be in the caller's circle.
  Future<Map<String, dynamic>> circleCreateGroup(Map<String, dynamic> body) =>
      postJson('/circle/groups', body);

  /// GET /circle/groups/<id> -> {id, name, description, announcements_only,
  /// size_limit, my_role, ...} (sanitize_group_info).
  Future<Map<String, dynamic>> circleGroup(int groupId) =>
      getJson('/circle/groups/$groupId');

  /// POST /circle/groups/<id> {name?, description?} -> updated group info.
  Future<Map<String, dynamic>> circleEditGroup(
          int groupId, Map<String, dynamic> body) =>
      postJson('/circle/groups/$groupId', body);

  /// GET /circle/groups/<id>/members -> {members:[{id, name, role, public_key,
  /// key_id, is_self, my_member_id, my_role}]} resolved per viewer.
  Future<Map<String, dynamic>> circleGroupMembers(int groupId) =>
      getJson('/circle/groups/$groupId/members');

  /// POST /circle/groups/<id>/members {member_id} -> add a circle member
  /// (server gates via can_add_member). Returns the updated roster.
  Future<Map<String, dynamic>> circleGroupAddMember(int groupId, int memberId) =>
      postJson('/circle/groups/$groupId/members', {'member_id': memberId});

  /// POST /circle/groups/<id>/members/<m> {event: remove|promote|demote}
  /// -> applies the membership/role event (server re-checks actor role).
  Future<Map<String, dynamic>> circleGroupMemberEvent(
          int groupId, int memberId, String event) =>
      postJson('/circle/groups/$groupId/members/$memberId', {'event': event});

  /// GET /circle/groups/<id>/messages -> {results:[{id, sender_id, per_recipient,
  /// mentions?, announcement, pinned, created_at, ...}]}.
  Future<Map<String, dynamic>> circleGroupMessages(int groupId) =>
      getJson('/circle/groups/$groupId/messages');

  /// POST /circle/groups/<id>/messages {per_recipient:{<member_id>:envelope},
  /// mentions?:[member_id], reply_to?} -> the stored message descriptor.
  /// The body carries a PER-RECIPIENT fan-out map (one sealed envelope per
  /// member id), never a shared plaintext; mentions are member IDs, not names.
  Future<Map<String, dynamic>> circleGroupSendMessage(
          int groupId, Map<String, dynamic> body) =>
      postJson('/circle/groups/$groupId/messages', body);

  /// POST /circle/groups/<id>/messages/<mid>/pin {pinned} -> admin pin/unpin
  /// (server caps at 5). Returns the updated message.
  Future<Map<String, dynamic>> circleGroupPinMessage(
          int groupId, int messageId, bool pinned) =>
      postJson('/circle/groups/$groupId/messages/$messageId/pin',
          {'pinned': pinned});

  /// POST /circle/groups/<id>/polls {question_ct:{<mid>:env}, options_ct:
  /// {<mid>:[env,...]}, multi} -> created poll. Question + each option are
  /// per-recipient ciphertexts; the backend stores them index-aligned and
  /// tallies by option index (never reads text).
  Future<Map<String, dynamic>> circleGroupCreatePoll(
          int groupId, Map<String, dynamic> body) =>
      postJson('/circle/groups/$groupId/polls', body);

  /// POST /circle/groups/<id>/polls/<pid>/vote {choices:[index,...]} -> tally.
  /// A re-vote replaces the voter's previous choices.
  Future<Map<String, dynamic>> circleGroupVotePoll(
          int groupId, int pollId, List<int> choices) =>
      postJson('/circle/groups/$groupId/polls/$pollId/vote',
          {'choices': choices});

  /// POST /circle/groups/<id>/announcements {on} -> toggle announcements-only.
  Future<Map<String, dynamic>> circleGroupSetAnnouncements(
          int groupId, bool on) =>
      postJson('/circle/groups/$groupId/announcements', {'on': on});

  /// POST /circle/groups/<id>/size-limit {size_limit} -> clamped limit.
  Future<Map<String, dynamic>> circleGroupSetSizeLimit(
          int groupId, int sizeLimit) =>
      postJson('/circle/groups/$groupId/size-limit', {'size_limit': sizeLimit});

  /// GET /circle/groups/<id>/invite -> {token, link}. Redeeming is circle-gated.
  Future<Map<String, dynamic>> circleGroupInvite(int groupId) =>
      getJson('/circle/groups/$groupId/invite');

  /// POST /circle/groups/<id>/leave {} -> leaving (dissolves if last admin).
  Future<Map<String, dynamic>> circleGroupLeave(int groupId) =>
      postJson('/circle/groups/$groupId/leave', const {});

  /// POST /circle/groups/<id>/report {reason} -> acknowledged report.
  Future<Map<String, dynamic>> circleGroupReport(int groupId, String reason) =>
      postJson('/circle/groups/$groupId/report', {'reason': reason});

  /// POST /circle/groups/<id>/call {kind: voice|video} -> {allowed,
  /// upgrade_required?, call_id?}. Server gates group video on Premium
  /// (can_place_group_call reuses circle_calls.can_place_call).
  Future<Map<String, dynamic>> circleGroupStartCall(int groupId, String kind) =>
      postJson('/circle/groups/$groupId/call', {'kind': kind});

  // ==========================================================================
  // M2: Connected Circle messenger — STATUS / STORIES (item 8)
  // (Folded from the former CircleStatusApi extension.)
  // Everything is E2E / ciphertext-only; the server resolves visibility,
  // viewer list and 24h expiry without reading content.
  // ==========================================================================

  /// POST /circle/status {kind:text, visibility{mode,allow_ids,except_ids},
  /// ...ciphertext} -> created status (id, created_at, expires_at). The backend
  /// validates ciphertext-only (validate_status_meta) and stamps 24h expiry.
  Future<Map<String, dynamic>> postTextStatus({
    required Ciphertext ciphertext,
    required Map<String, dynamic> visibility,
  }) =>
      postJson('/circle/status', {
        'kind': 'text',
        'visibility': visibility,
        ...ciphertext.toEnvelopeFields(),
      });

  /// GET /circle/status -> {mine?, entries:[{author_id, author{}, count,
  /// has_unseen, latest_at}]} grouped per author (unseen first).
  Future<Map<String, dynamic>> statusTray() => getJson('/circle/status');

  /// GET /circle/status/mine -> {statuses:[{id, kind, ...ciphertext,
  /// views:[{viewer, at, anonymous}], viewer_count}]}. Server serializes only
  /// named (non-anonymous) viewers plus an anonymous count.
  Future<Map<String, dynamic>> myStatuses() => getJson('/circle/status/mine');

  /// GET /circle/status/author/<id> -> {statuses:[...]} the caller may view
  /// (visibility resolved server-side).
  Future<Map<String, dynamic>> authorStatuses(int authorId) =>
      getJson('/circle/status/author/$authorId');

  /// POST /circle/status/<id>/view {} -> record a view. Server re-checks
  /// can_view_status + is_active and honours the reciprocal read-receipt rule.
  Future<void> viewStatus(String statusId) =>
      postJson('/circle/status/$statusId/view', const {});

  /// POST /circle/status/mute {author_id, on} -> mute/unmute an author.
  Future<void> muteStatusAuthor(int authorId, {bool on = true}) =>
      postJson('/circle/status/mute', {'author_id': authorId, 'on': on});

  /// POST /circle/status/<id>/reply {author_id, ...ciphertext} -> reply
  /// privately: builds a 1:1 relay envelope (never stored on the status).
  Future<void> replyToStatus({
    required String statusId,
    required int authorId,
    required Ciphertext ciphertext,
  }) =>
      postJson('/circle/status/$statusId/reply', {
        'author_id': authorId,
        ...ciphertext.toEnvelopeFields(),
      });

  // ==========================================================================
  // M2: Connected Circle messenger — EXTRAS (items 9 + 10)
  // Per-chat settings, scheduled messages, broadcast fan-out, encrypted
  // backup/restore, linked devices. All opaque to the server.
  // ==========================================================================

  /// GET /circle/<peer>/settings -> {disappearing_sec} (only server-side field).
  Future<Map<String, dynamic>> circleChatSettings(int peerId) =>
      getJson('/circle/$peerId/settings');

  /// POST /circle/<peer>/settings {disappearing_sec} -> persisted settings.
  Future<Map<String, dynamic>> setCircleChatSettings(
          int peerId, Map<String, dynamic> body) =>
      postJson('/circle/$peerId/settings', body);

  /// GET /circle/<peer>/scheduled -> {results:[{id, send_at, status, ...}]}.
  Future<Map<String, dynamic>> listScheduled(int peerId) =>
      getJson('/circle/$peerId/scheduled');

  /// POST /circle/<peer>/scheduled {client_msg_id, send_at, envelope} ->
  /// queued message (opaque envelope; the cron worker sends it at send_at).
  Future<Map<String, dynamic>> scheduleMessage(
          int peerId, Map<String, dynamic> body) =>
      postJson('/circle/$peerId/scheduled', body);

  /// POST /circle/scheduled/<id>/cancel {} -> cancel a pending scheduled send.
  Future<Map<String, dynamic>> cancelScheduled(int scheduledId) =>
      postJson('/circle/scheduled/$scheduledId/cancel', const {});

  /// POST /circle/broadcast {sends:[{peer_id, client_msg_id, envelope}, ...]}
  /// -> N INDIVIDUAL private sends (per-recipient fan-out, distinct
  /// client_msg_ids). This is NOT a group: recipients are never linked
  /// server-side and never see each other (review G1).
  Future<Map<String, dynamic>> broadcast(List<Map<String, dynamic>> sends) =>
      postJson('/circle/broadcast', {'sends': sends});

  /// GET /circle/backup -> {backup?:{v, created_at, ...ciphertext, salt, iters,
  /// message_count, recovery_hint, size_bytes}}. Opaque; restore is client-side.
  Future<Map<String, dynamic>> getChatBackup() => getJson('/circle/backup');

  /// POST /circle/backup {v, scheme, ciphertext, nonce, salt, iters,
  /// message_count, recovery_hint?, size_bytes} -> stored (secrets rejected by
  /// validate_backup_envelope).
  Future<Map<String, dynamic>> putChatBackup(Map<String, dynamic> envelope) =>
      postJson('/circle/backup', envelope);

  /// GET /circle/devices -> {devices:[{id, device_id, platform, role, name,
  /// linked_at, revoked}]}.
  Future<Map<String, dynamic>> listDevices() => getJson('/circle/devices');

  /// POST /circle/devices/link {device_id, platform, public_key_id, name} ->
  /// a linked device record.
  Future<Map<String, dynamic>> linkDevice(Map<String, dynamic> body) =>
      postJson('/circle/devices/link', body);

  /// POST /circle/devices/<id>/revoke {} -> revoke a linked device.
  Future<Map<String, dynamic>> revokeDevice(int deviceId) =>
      postJson('/circle/devices/$deviceId/revoke', const {});

  // ==========================================================================
  // Section 8: Stolen-While-Unlocked Protection
  // Server-side ownership + delayed/alerted sensitive actions. The app NEVER
  // enforces OS settings — these endpoints add a delay, alert the owner +
  // trusted contacts, and hold ownership so a snatched phone can't instantly
  // be sold / wiped-of-ownership. A thief who already knows the Security PIN
  // is NOT stopped outright; the delay + alerts + cancel are the defence.
  // ==========================================================================

  /// GET security/state -> {has_pin, armed, frozen_until, status, wrong_pin_count,
  /// trusted_place_count, pending:[{id, action, effective_at, state}]}.
  Future<Map<String, dynamic>> securityState() => getJson('/security/state');

  /// POST security/pin/set {new_pin, current_pin?} -> {ok, reason?}. When a PIN
  /// already exists the server requires [currentPin].
  Future<Map<String, dynamic>> securityPinSet(String newPin,
          {String? currentPin}) =>
      postJson('/security/pin/set', {
        'new_pin': newPin,
        if (currentPin != null) 'current_pin': currentPin,
      });

  /// POST security/pin/verify {pin} -> {ok, locked?}.
  Future<Map<String, dynamic>> securityPinVerify(String pin) =>
      postJson('/security/pin/verify', {'pin': pin});

  /// POST security/action {action, pin, lat?, lng?}. action in
  /// [sell_transfer, disarm, remove_admin, change_contacts, turn_off_lost,
  /// change_pin, export_data]. Responses:
  ///   {state:'applied', id:null}
  ///   {state:'pending'|'awaiting_approval', effective_at, id}
  ///   HTTP 423 {state:'blocked', reason:'frozen'}
  ///   HTTP 403 {ok:false, reason:'bad_pin'}
  ///   {ok:false, locked:true}
  /// This issues a RAW POST (not via [postJson]) because the 403/423 bodies
  /// carry the interpretable result — [SecurityGuard] reads them off the
  /// thrown [ApiException].status instead of a generic failure.
  Future<Map<String, dynamic>> securityAction(String action, String pin,
      {double? lat, double? lng, String? otpProof}) async {
    final r = await _c.post(AppConfig.api('/security/action'),
        headers: _headers(),
        body: jsonEncode({
          'action': action,
          'pin': pin,
          if (otpProof != null && otpProof.isNotEmpty) 'otp_proof': otpProof,
          if (lat != null) 'lat': lat,
          if (lng != null) 'lng': lng,
        }));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    // 403 (bad_pin) and 423 (frozen) are meaningful, interpretable results —
    // surface the parsed body to the caller rather than a generic error.
    if (r.statusCode == 403 || r.statusCode == 423) {
      final body = r.body.isEmpty ? {} : jsonDecode(r.body);
      if (body is Map<String, dynamic>) {
        return {...body, '_status': r.statusCode};
      }
    }
    _fail(r);
  }

  /// POST security/action/<id>/cancel {token?} -> {ok, state}. Authed owner OR
  /// a one-tap cancel token (from the alert notification/email on another
  /// device). "This wasn't me."
  Future<Map<String, dynamic>> securityCancel(int id, {String? token}) =>
      postJson('/security/action/$id/cancel',
          {if (token != null) 'token': token});

  /// POST security/action/<id>/approve -> {ok, state}. Family approver only.
  Future<Map<String, dynamic>> securityApprove(int id) =>
      postJson('/security/action/$id/approve', const {});

  /// POST security/signal {kind} -> {ok, frozen_until, status}. A theft signal
  /// (e.g. SIM swap, repeated wrong PIN) that freezes sensitive actions.
  Future<Map<String, dynamic>> securitySignal(String kind) =>
      postJson('/security/signal', {'kind': kind});

  /// POST security/arm {pin} -> {ok, armed} | {ok:false, reason|locked}.
  /// Arming raises protection (PIN required; no delay — it only increases safety).
  Future<Map<String, dynamic>> securityArm(String pin) =>
      postJson('/security/arm', {'pin': pin});

  /// POST security/approver {member_id} -> {ok, approver_id}. Pass null/empty to
  /// clear. The member must be an ACCEPTED circle contact.
  Future<Map<String, dynamic>> securitySetApprover(int? memberId) =>
      postJson('/security/approver', {'member_id': memberId});

  // ==========================================================================
  // Anti-theft Batch 4: community stolen-phone REGISTRY + a safe SALE/TRANSFER
  // ledger. HONESTY: this is a COMMUNITY + server-side ownership registry —
  // Assisto never blocks a phone at the mobile-network level (that is NEIR,
  // which is not available yet; see [registryNeirStatus]). A "reported_stolen"
  // result means a seller/community flagged the IMEI; it advises contacting the
  // police, never confronting anyone.
  // ==========================================================================

  /// POST registry/report-stolen {imei, gd_number, model?, area?}
  /// -> {ok, report_id}. [gdNumber] is the police General-Diary reference (file
  /// an Online GD first). [area] is a COARSE locality, never a precise address.
  Future<Map<String, dynamic>> registryReportStolen({
    required String imei,
    required String gdNumber,
    String? model,
    String? area,
  }) =>
      postJson('/registry/report-stolen', {
        'imei': imei,
        'gd_number': gdNumber,
        if (model != null && model.isNotEmpty) 'model': model,
        if (area != null && area.isNotEmpty) 'area': area,
      });

  /// POST registry/recover {imei} -> {ok}. Clears a stolen flag after recovery.
  Future<Map<String, dynamic>> registryRecover(String imei) =>
      postJson('/registry/recover', {'imei': imei});

  /// POST registry/check {imei}
  /// -> {result:'clean'|'reported_stolen'|'verified_transfer',
  ///     advice_key:'buy_ok'|'contact_police_dont_confront'|'verified_ok'}.
  /// HTTP 429 when rate-limited (too many checks). RAW post so the 429 body is
  /// surfaced to the caller as an [ApiException] with `.status == 429`, exactly
  /// like [securityAction] surfaces 403/423 — a generic failure would hide it.
  Future<Map<String, dynamic>> registryCheck(String imei) async {
    final r = await _c.post(AppConfig.api('/registry/check'),
        headers: _headers(), body: jsonEncode({'imei': imei}));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    // 429 (rate-limited) is an interpretable result — carry the status through
    // so the screen can show a friendly "too many checks, try later" message.
    _fail(r);
  }

  /// GET registry/neir-status -> {available:false, message_key:'neir_not_available'}.
  /// The honest placeholder for the official (NEIR) stolen-phone registry.
  Future<Map<String, dynamic>> registryNeirStatus() =>
      getJson('/registry/neir-status');

  /// GET registry/tac?imei=... -> {available:bool, brand?, model?}.
  ///
  /// Looks up the make/model implied by an IMEI's Type Allocation Code (first 8
  /// digits), used to flag a re-flashed IMEI whose TAC no longer matches the
  /// phone in hand. This needs a real TAC database, so the backend is HONEST:
  /// when no data source is wired up it returns {available:false} and we say so
  /// — we NEVER invent a brand/model. Key-gated; any non-200 (incl. the gate
  /// being closed) degrades gracefully to the "not available yet" state rather
  /// than throwing, so the tamper pre-check still runs its deterministic parts.
  Future<Map<String, dynamic>> tacLookup(String imei) async {
    try {
      final r = await _c.get(
          AppConfig.api('/registry/tac?imei=${Uri.encodeQueryComponent(imei)}'),
          headers: _headers());
      if (r.statusCode >= 200 && r.statusCode < 300) {
        final body =
            r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
        return {'available': body['available'] == true, ...body};
      }
    } catch (_) {
      // fall through to the honest "not available" result
    }
    return const {'available': false};
  }

  /// POST sale/create {imei, model?, price, buyer_name, buyer_nid?}
  /// -> {id, token, state}. [price] is in TAKA (whole/decimal) as the backend
  /// expects — the sale ledger is a receipt, not a wallet; no money moves.
  Future<Map<String, dynamic>> saleCreate({
    required String imei,
    required String price,
    required String buyerName,
    String? model,
    String? buyerNid,
  }) =>
      postJson('/sale/create', {
        'imei': imei,
        'price': price,
        'buyer_name': buyerName,
        if (model != null && model.isNotEmpty) 'model': model,
        if (buyerNid != null && buyerNid.isNotEmpty) 'buyer_nid': buyerNid,
      });

  /// POST sale/authorize {id} -> {ok?, state, reason?}. HTTP 423/409 when the
  /// transfer is blocked by a theft signal / reported-stolen / frozen state.
  /// RAW post so those interpretable bodies are surfaced to the caller via
  /// [ApiException].status + the merged `_status` field (same pattern as
  /// [securityAction]). The Sell flow only calls this AFTER SecurityGuard has
  /// returned `applied` — this is the server-side re-check on top of that gate.
  Future<Map<String, dynamic>> saleAuthorize(int id) async {
    final r = await _c.post(AppConfig.api('/sale/authorize'),
        headers: _headers(), body: jsonEncode({'id': id}));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    // 409 (conflict: reported-stolen) and 423 (locked: theft signal / frozen)
    // carry a readable state/reason — surface the parsed body to the caller.
    if (r.statusCode == 409 || r.statusCode == 423) {
      final body = r.body.isEmpty ? {} : jsonDecode(r.body);
      if (body is Map<String, dynamic>) {
        return {...body, '_status': r.statusCode};
      }
    }
    _fail(r);
  }

  /// POST sale/accept {token} -> {ok, state}. Called by the BUYER's account to
  /// accept a transfer (they scan the QR with any app, or paste the token).
  Future<Map<String, dynamic>> saleAccept(String token) =>
      postJson('/sale/accept', {'token': token});

  // ==========================================================================
  // Anti-theft Batch 5: "My lost phone" view + RECOVERY help + a best-effort
  // FOREGROUND heartbeat.
  //
  // HONESTY: Assisto only ever sees the phone while it is ONLINE. It cannot
  // locate an offline / powered-off / flashed phone. The heartbeat here is a
  // best-effort, foreground-only stopgap (sent when the owner opens/resumes the
  // app with protection armed) until the native always-on engine ships. FRP +
  // IMEI + a police GD are what actually help recovery — these endpoints build
  // those documents, never a fake live location.
  // ==========================================================================

  /// POST security/heartbeat {lat?, lng?, battery?, network?}
  /// -> {lost_mode, lost_message, lost_contact, armed, frozen,
  ///     heartbeat_interval_min}. Best-effort "I'm online" ping from the
  /// foreground. Every field is optional (omit what the device can't supply).
  Future<Map<String, dynamic>> securityHeartbeat({
    double? lat,
    double? lng,
    int? battery,
    String? network,
  }) =>
      postJson('/security/heartbeat', {
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (battery != null) 'battery': battery,
        if (network != null && network.isNotEmpty) 'network': network,
      });

  /// POST security/lost-mode {on:true, message?, contact?, reward?} -> {ok}.
  /// IMPORTANT: this ONLY turns lost mode ON. Turning it OFF is a sensitive
  /// (Section-8-gated) action — call SecurityGuard.run(context,'turn_off_lost')
  /// instead; the server returns HTTP 409 if on:false is posted here, so this
  /// method never accepts an `on` flag.
  Future<Map<String, dynamic>> securityLostMode({
    String? message,
    String? contact,
    String? reward,
  }) =>
      postJson('/security/lost-mode', {
        'on': true,
        if (message != null && message.isNotEmpty) 'message': message,
        if (contact != null && contact.isNotEmpty) 'contact': contact,
        if (reward != null && reward.isNotEmpty) 'reward': reward,
      });

  /// GET security/lost-phone -> {imei1, imei2, model, armed, lost_mode, frozen,
  /// went_dark_at:ISO|null, last_location:{lat,lng,at}|null,
  /// trail:[{lat,lng,at}], events:[{id,kind,data,at,photo_url?}],
  /// sim_change:{...}|null, status}.
  Future<Map<String, dynamic>> securityLostPhone() =>
      getJson('/security/lost-phone');

  /// Authed URL for an intruder-event photo (owner only). Built the same way
  /// AppConfig produces every other API URL so the Authorization header still
  /// applies when fetched via [getBytes]; use the path (not this Uri) with
  /// [getBytes] to carry the token.
  static String securityEventPhotoPath(int eventId) =>
      '/security/event/$eventId/photo';

  /// GET recovery/gd-draft -> {text}. A ready-to-file Online GD (General Diary)
  /// draft the owner can copy into gd.police.gov.bd.
  Future<Map<String, dynamic>> recoveryGdDraft() =>
      getJson('/recovery/gd-draft');

  /// GET recovery/sp-letter -> {text}. An escalation letter to the SP
  /// (Superintendent of Police) when a GD stalls.
  Future<Map<String, dynamic>> recoverySpLetter() =>
      getJson('/recovery/sp-letter');

  /// GET recovery/police-stations?lat&lng
  /// -> {stations:[{name, phone?, lat, lng}]} | {available:false}.
  /// HONEST: returns {available:false} where no real station data exists —
  /// the app never invents stations.
  Future<Map<String, dynamic>> recoveryPoliceStations(double lat, double lng) =>
      getJson('/recovery/police-stations?lat=$lat&lng=$lng');

  /// Path for the evidence PDF (owner only). Fetch the bytes with [getBytes]
  /// (reuses the vault / money-report download path so the Token header
  /// applies) then share via share_plus.
  static const String recoveryEvidencePdfPath = '/recovery/evidence.pdf';

  /// GET sale/mine -> {as_seller:[...], as_buyer:[...]} OR a bare list. Callers
  /// MUST code defensively against both shapes (see used/sell screens).
  Future<Map<String, dynamic>> saleMine() async {
    final r = await _c.get(AppConfig.api('/sale/mine'), headers: _headers());
    if (r.statusCode == 200) {
      final body = r.body.isEmpty ? {} : jsonDecode(r.body);
      // Normalise a bare list into the documented map shape so screens have a
      // single contract to read.
      if (body is List) {
        return {'as_seller': body, 'as_buyer': const []};
      }
      if (body is Map<String, dynamic>) return body;
      return {'as_seller': const [], 'as_buyer': const []};
    }
    _fail(r);
  }

  // ==========================================================================
  // Part 3: Assisto AI — the ChatGPT-like full-history chat. The HOME chat
  // (/agent) stays as-is; this is the richer, persistent-session experience.
  //
  // HONESTY: with no AI key the backend answers via Assisto Brain (real
  // user-data summaries / help answers / honest "needs key"). Every reply
  // carries `meta.source` so the UI can label a Brain answer instead of
  // pretending it was a streamed AI response. We NEVER fabricate a reply.
  //
  // Sessions endpoints code DEFENSIVELY: the list view may return either
  // {sessions:[...]} or a bare list; [chatSessions] normalises both.
  // ==========================================================================

  /// GET chat/sessions?query= -> list of {id, title, pinned, updated, snippet}.
  /// Handles both {sessions:[...]} and a bare list.
  Future<List<Map<String, dynamic>>> chatSessions({String? query}) async {
    final q = (query != null && query.trim().isNotEmpty)
        ? '?query=${Uri.encodeQueryComponent(query.trim())}'
        : '';
    final r = await _c.get(AppConfig.api('/chat/sessions$q'), headers: _headers());
    if (r.statusCode == 200) {
      final body = r.body.isEmpty ? [] : jsonDecode(r.body);
      final list = body is Map ? (body['sessions'] ?? body['results'] ?? []) : body;
      return (list as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  /// POST chat/sessions -> the created session {id, ...}.
  Future<Map<String, dynamic>> chatCreateSession({String? title}) =>
      postJson('/chat/sessions',
          {if (title != null && title.isNotEmpty) 'title': title});

  /// PATCH chat/sessions/<id> {title?, pinned?, archived?} -> updated session.
  Future<Map<String, dynamic>> chatUpdateSession(String id,
      {String? title, bool? pinned, bool? archived}) async {
    final r = await _c.patch(AppConfig.api('/chat/sessions/$id'),
        headers: _headers(),
        body: jsonEncode({
          if (title != null) 'title': title,
          if (pinned != null) 'pinned': pinned,
          if (archived != null) 'archived': archived,
        }));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    }
    _fail(r);
  }

  /// DELETE chat/sessions/<id>.
  Future<void> chatDeleteSession(String id) async {
    final r =
        await _c.delete(AppConfig.api('/chat/sessions/$id'), headers: _headers());
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) {
      _fail(r);
    }
  }

  /// GET chat/sessions/<id>/messages -> list of {id, role, text, meta}.
  /// Handles both {messages:[...]} and a bare list.
  Future<List<Map<String, dynamic>>> chatMessages(String sessionId) async {
    final r = await _c.get(AppConfig.api('/chat/sessions/$sessionId/messages'),
        headers: _headers());
    if (r.statusCode == 200) {
      final body = r.body.isEmpty ? [] : jsonDecode(r.body);
      final list =
          body is Map ? (body['messages'] ?? body['results'] ?? []) : body;
      return (list as List).cast<Map<String, dynamic>>();
    }
    _fail(r);
  }

  /// POST chat/sessions/<id>/send {text} -> the assistant message
  /// {id, role:'assistant', text, meta, cards?}.
  Future<Map<String, dynamic>> chatSend(String sessionId, String text) =>
      postJson('/chat/sessions/$sessionId/send', {'text': text});

  /// POST chat/sessions/<id>/regenerate {edit?} -> a new assistant message.
  /// Pass [edit] to resend an edited version of the last user message.
  Future<Map<String, dynamic>> chatRegenerate(String sessionId,
          {String? edit}) =>
      postJson('/chat/sessions/$sessionId/regenerate',
          {if (edit != null && edit.isNotEmpty) 'edit': edit});

  /// SSE stream of chat/sessions/<id>/stream (POST {text}). Yields `token`
  /// chunks as they arrive and a final `done` event carrying
  /// {message_id, cards, source}. Parses the standard text/event-stream
  /// framing (`event:` + `data:` lines, blank-line separated).
  ///
  /// Each yielded record is one of:
  ///   {'kind':'token', 'chunk': <String>}
  ///   {'kind':'done', 'message_id':..., 'cards':[...], 'source':...}
  ///
  /// Callers that can't stream should fall back to [chatSend]. The stream is
  /// cancellable by cancelling the StreamSubscription (we abort the request).
  Stream<Map<String, dynamic>> chatStream(String sessionId, String text) async* {
    final req = http.Request(
        'POST', AppConfig.api('/chat/sessions/$sessionId/stream'));
    req.headers.addAll(_headers());
    req.headers['Accept'] = 'text/event-stream';
    req.body = jsonEncode({'text': text});
    final resp = await _c.send(req);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException('stream failed', resp.statusCode);
    }
    final lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    String? event;
    final dataBuf = StringBuffer();
    await for (final line in lines) {
      if (line.isEmpty) {
        // Blank line = dispatch the accumulated event.
        final data = dataBuf.toString();
        dataBuf.clear();
        if (data.isEmpty) {
          event = null;
          continue;
        }
        Map<String, dynamic> payload;
        try {
          final decoded = jsonDecode(data);
          payload = decoded is Map<String, dynamic> ? decoded : {'value': decoded};
        } catch (_) {
          payload = {'chunk': data};
        }
        final ev = event ?? (payload.containsKey('message_id') ? 'done' : 'token');
        if (ev == 'done') {
          yield {
            'kind': 'done',
            'message_id': payload['message_id'],
            'cards': payload['cards'] ?? const [],
            'source': payload['source'],
            'meta': payload['meta'],
            'text': payload['text'],
          };
        } else {
          yield {'kind': 'token', 'chunk': payload['chunk'] ?? payload['value'] ?? ''};
        }
        event = null;
        continue;
      }
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (dataBuf.isNotEmpty) dataBuf.write('\n');
        dataBuf.write(line.substring(5).trimLeft());
      }
      // other SSE fields (id:, retry:, comments) are ignored.
    }
  }
}
