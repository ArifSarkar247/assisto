// cctvx — every server call the CCTV-extras screens make (owner order
// 28 Oct: no-sale drawer, alert actions, offline, escalation, open/close,
// guard report, placement helper, evidence pack, privacy kit), behind one
// seam so widget tests / the screenshot gallery inject a fake. Shapes mirror
// backend/core/cctvx_views.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../config.dart';

abstract class CctvxSource {
  /// GET shop/sites/<id>/guard — {settings, circle, bounds, caps, usage, tip}.
  Future<Map<String, dynamic>> guard(int siteId);

  /// PUT shop/sites/<id>/guard — partial settings; the server clamps bounds.
  Future<Map<String, dynamic>> saveGuard(int siteId, Map<String, dynamic> body);

  /// GET shop/sites/<id>/guard/report — today's lines (0 credits).
  Future<Map<String, dynamic>> report(int siteId);

  /// GET shop/sites/<id>/privacy-kit — sticker (bn + en) + staff notice.
  Future<Map<String, dynamic>> privacyKit(int siteId);

  /// GET shop/cameras/<id>/placement — light / clarity / framing tips.
  Future<Map<String, dynamic>> placement(int cameraId);

  /// GET shop/events/<id> — the alert + what can be done from it.
  Future<Map<String, dynamic>> event(int eventId);

  /// POST shop/events/<id>/opened — seen (stops the escalation chain).
  Future<Map<String, dynamic>> opened(int eventId);

  /// POST shop/events/<id>/siren.
  Future<Map<String, dynamic>> siren(int eventId, {int? cameraId, int? seconds});

  /// GET shop/events/<id>/share-targets — Circle people with a phone key.
  Future<Map<String, dynamic>> shareTargets(int eventId);

  /// POST shop/events/<id>/clip/share — a re-wrapped key (+ the ciphertext
  /// when the server's copy is already gone).
  Future<Map<String, dynamic>> share(int eventId, int uid, Map<String, String> wrap,
      {Uint8List? ciphertext});

  /// GET / POST shop/events/<id>/evidence — facts + GD draft.
  Future<Map<String, dynamic>> evidence(int eventId);
  Future<Map<String, dynamic>> evidenceRecord(int eventId, String manifestSha256, int files);

  /// GET shop/guard/inbox — alerts passed to me / clips shared with me.
  Future<Map<String, dynamic>> inbox();

  /// The ONE alert photo from its signed link (no auth header).
  Future<Uint8List> download(String url);
}

class ApiCctvxSource implements CctvxSource {
  final ApiClient api;
  ApiCctvxSource(this.api);

  static const _maxBytes = 3 * 1024 * 1024;

  @override
  Future<Map<String, dynamic>> guard(int siteId) => api.getJson('/shop/sites/$siteId/guard');

  @override
  Future<Map<String, dynamic>> saveGuard(int siteId, Map<String, dynamic> body) =>
      api.postJson('/shop/sites/$siteId/guard', body);

  @override
  Future<Map<String, dynamic>> report(int siteId) =>
      api.getJson('/shop/sites/$siteId/guard/report');

  @override
  Future<Map<String, dynamic>> privacyKit(int siteId) =>
      api.getJson('/shop/sites/$siteId/privacy-kit');

  @override
  Future<Map<String, dynamic>> placement(int cameraId) =>
      api.getJson('/shop/cameras/$cameraId/placement');

  @override
  Future<Map<String, dynamic>> event(int eventId) => api.getJson('/shop/events/$eventId');

  @override
  Future<Map<String, dynamic>> opened(int eventId) =>
      api.postJson('/shop/events/$eventId/opened', const {});

  @override
  Future<Map<String, dynamic>> siren(int eventId, {int? cameraId, int? seconds}) =>
      api.postJson('/shop/events/$eventId/siren', {
        if (cameraId != null) 'camera_id': cameraId,
        if (seconds != null) 'seconds': seconds,
      });

  @override
  Future<Map<String, dynamic>> shareTargets(int eventId) =>
      api.getJson('/shop/events/$eventId/share-targets');

  @override
  Future<Map<String, dynamic>> share(int eventId, int uid, Map<String, String> wrap,
      {Uint8List? ciphertext}) async {
    if (ciphertext == null) {
      return api.postJson('/shop/events/$eventId/clip/share', {'uid': uid, 'wrap': wrap});
    }
    // the server copy is gone (the owner watched it): send the SAME
    // ciphertext again — the server checks its SHA-256 against the original
    final req = http.MultipartRequest('POST', AppConfig.api('/shop/events/$eventId/clip/share'));
    final tok = api.token;
    if (tok != null) req.headers['Authorization'] = 'Token $tok';
    req.headers['Accept-Language'] = api.lang ?? 'bn';
    req.fields['uid'] = '$uid';
    req.fields['wrap'] = jsonEncode(wrap);
    req.files.add(http.MultipartFile.fromBytes('blob', ciphertext, filename: 'clip.bin'));
    final r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 60)));
    Map<String, dynamic> body = const {};
    try {
      final j = r.body.isEmpty ? null : jsonDecode(r.body);
      if (j is Map<String, dynamic>) body = j;
    } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    throw ApiException((body['detail'] ?? 'Error ${r.statusCode}').toString(), r.statusCode,
        null, body['error']?.toString(), body);
  }

  @override
  Future<Map<String, dynamic>> evidence(int eventId) =>
      api.getJson('/shop/events/$eventId/evidence');

  @override
  Future<Map<String, dynamic>> evidenceRecord(int eventId, String manifestSha256, int files) =>
      api.postJson('/shop/events/$eventId/evidence',
          {'manifest_sha256': manifestSha256, 'files': files});

  @override
  Future<Map<String, dynamic>> inbox() => api.getJson('/shop/guard/inbox');

  @override
  Future<Uint8List> download(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw ApiException('Error ${r.statusCode}', r.statusCode);
    if (r.bodyBytes.length > _maxBytes) throw ApiException('Error 413', 413);
    return r.bodyBytes;
  }
}
