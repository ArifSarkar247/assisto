import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../config.dart';

/// bizai (owner 4 Nov 02:05 BUSINESS AI REAL IMPACT): every server call of the
/// in-app shop chat (customer side), the seller's shop-link card and the
/// Business-home outcome card — behind ONE seam so widget tests inject a fake.
/// Server: backend/core/views_bizai.py (flag `business_agent`).
abstract class BizaiSource {
  // customer side
  Future<List<Map<String, dynamic>>> myShops();
  Future<Map<String, dynamic>> shop(String code);
  Future<Map<String, dynamic>> messages(String code, int after);
  Future<Map<String, dynamic>> send(String code, String text);

  /// kind: image | audio; [path] = a file the app owns.
  Future<Map<String, dynamic>> sendFile(String code, String kind, String path, String mime);
  Future<Map<String, dynamic>> talkToPerson(String code);
  // shop side
  Future<Map<String, dynamic>> shopLink(int? businessId);
  Future<Map<String, dynamic>> saveShopLink(int? businessId, Map<String, dynamic> body);
  Future<Map<String, dynamic>> outcomes(int? businessId, {int days = 7});
}

List<Map<String, dynamic>> bzList(Object? v) =>
    [for (final x in (v as List? ?? const [])) (x as Map).cast<String, dynamic>()];

String _biz(int? id) => id == null ? '' : '?business=$id';

/// "12-ab34cd56" from a code or https://lifeassisto.com/shop/<code>; else null.
String? shopCodeFrom(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  final i = s.indexOf('/shop/');
  if (i != -1) s = s.substring(i + 6);
  s = s.split(RegExp(r'[?#/\s]')).first;
  return RegExp(r'^\d{1,10}-[0-9a-f]{8}$').hasMatch(s) ? s : null;
}

class ApiBizaiSource implements BizaiSource {
  final ApiClient api;
  ApiBizaiSource(this.api);

  String _c(String code) => Uri.encodeComponent(code);

  @override
  Future<List<Map<String, dynamic>>> myShops() async =>
      bzList((await api.getJson('/shopchat/mine'))['shops']);
  @override
  Future<Map<String, dynamic>> shop(String code) => api.getJson('/shopchat/${_c(code)}');
  @override
  Future<Map<String, dynamic>> messages(String code, int after) =>
      api.getJson('/shopchat/${_c(code)}/messages?after=$after');
  @override
  Future<Map<String, dynamic>> send(String code, String text) =>
      api.postJson('/shopchat/${_c(code)}/send', {'text': text});
  @override
  Future<Map<String, dynamic>> talkToPerson(String code) =>
      api.postJson('/shopchat/${_c(code)}/person');

  @override
  Future<Map<String, dynamic>> sendFile(
      String code, String kind, String path, String mime) async {
    final req = http.MultipartRequest('POST', AppConfig.api('/shopchat/${_c(code)}/send'));
    final tok = api.token;
    if (tok != null) req.headers['Authorization'] = 'Token $tok';
    req.headers['Accept-Language'] = api.lang ?? 'bn';
    if (AppConfig.playStore) req.headers['X-Assisto-Flavour'] = 'play';
    req.fields['type'] = kind;
    req.files.add(await http.MultipartFile.fromPath('file', path));
    final r = await http.Response.fromStream(await req.send());
    Map<String, dynamic> body = const {};
    try {
      final j = jsonDecode(r.body);
      if (j is Map) body = j.cast<String, dynamic>();
    } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    throw ApiException('${body['detail'] ?? 'HTTP ${r.statusCode}'}', r.statusCode, null,
        body['reason'] as String?, body);
  }

  @override
  Future<Map<String, dynamic>> shopLink(int? businessId) =>
      api.getJson('/bizai/shop-link${_biz(businessId)}');
  @override
  Future<Map<String, dynamic>> saveShopLink(int? businessId, Map<String, dynamic> body) =>
      api.postJson('/bizai/shop-link${_biz(businessId)}', body);
  @override
  Future<Map<String, dynamic>> outcomes(int? businessId, {int days = 7}) => api.getJson(
      '/bizai/outcomes${businessId == null ? '?' : '${_biz(businessId)}&'}days=$days');
}

/// bizai pillar 5: a marketing post's share text WITH its tracked shop-chat
/// link + code (GET bizai/prochar/tracked/<id>); null when not available.
Future<String?> Function(String itemId) bizaiTrackedText(ApiClient api) => (id) async {
      final r = await api.getJson('/bizai/prochar/tracked/${Uri.encodeComponent(id)}');
      final t = r['text'];
      return t is String ? t : null;
    };
