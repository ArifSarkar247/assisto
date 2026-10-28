// cashguard — every server call the Smart Cash Guard screens make, behind one
// seam so widget tests / the screenshot gallery inject a fake. Shapes mirror
// backend/core/cashguard_views.py.
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';

abstract class CashGuardSource {
  /// GET shop/cashguard — caps, usage, sites (away state), labels.
  Future<Map<String, dynamic>> overview();

  /// PUT shop/sites/<id>/away — {on, hours} and/or {schedule}.
  Future<Map<String, dynamic>> setAway(int siteId, Map<String, dynamic> body);

  /// GET shop/events/<id>/clip — {status, url, meta (my wrap), expires_at}.
  Future<Map<String, dynamic>> clip(int eventId);

  /// POST shop/events/<id>/clip/viewed — the owner watched it (deletes it).
  Future<Map<String, dynamic>> clipViewed(int eventId);

  /// The clip's ciphertext from its signed link (no auth header needed).
  Future<Uint8List> download(String url);

  /// This phone's private keys (current first). Never leaves the phone.
  Future<List<IdentityKeyPair>> myKeys();

  /// POST shop/cameras/<id>/ezviz.
  Future<Map<String, dynamic>> linkEzviz(int cameraId, String serial, String code);
}

class ApiCashGuardSource implements CashGuardSource {
  final ApiClient api;
  ApiCashGuardSource(this.api);

  static const _maxBytes = 3 * 1024 * 1024;

  @override
  Future<Map<String, dynamic>> overview() => api.getJson('/shop/cashguard');

  @override
  Future<Map<String, dynamic>> setAway(int siteId, Map<String, dynamic> body) =>
      api.postJson('/shop/sites/$siteId/away', body);

  @override
  Future<Map<String, dynamic>> clip(int eventId) => api.getJson('/shop/events/$eventId/clip');

  @override
  Future<Map<String, dynamic>> clipViewed(int eventId) =>
      api.postJson('/shop/events/$eventId/clip/viewed', const {});

  @override
  Future<Uint8List> download(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) throw ApiException('Error ${r.statusCode}', r.statusCode);
    if (r.bodyBytes.length > _maxBytes) throw ApiException('Error 413', 413);
    return r.bodyBytes;
  }

  @override
  Future<List<IdentityKeyPair>> myKeys() => IdentityVault.instance.ring();

  @override
  Future<Map<String, dynamic>> linkEzviz(int cameraId, String serial, String code) =>
      api.postJson('/shop/cameras/$cameraId/ezviz',
          {'device_serial': serial, 'verification_code': code});
}
