import '../api.dart';

/// halaladz (owner order 23 Nov) — HalalAdz link / support client.
///
/// Built only on ApiClient's public helpers (no api.dart edit). Routes live in
/// backend core/views_halaladz.py. The Assisto SERVER talks to HalalAdz (the
/// app never holds the shared secret). While the server has no secret every
/// call answers `enabled: false` / 503 and the Settings tile stays hidden.
extension HalalAdzApi on ApiClient {
  /// GET /halaladz/status -> {enabled, linked, account{hz_account_id,
  /// display_name}, official{channel_url, community_url, ...}, support_unread}
  Future<Map<String, dynamic>> hzStatus() => getJson('/halaladz/status');

  /// POST /halaladz/link {code}. Raw answer with `_status` (200 linked;
  /// 400 bad_format / bad_code; 409 taken; 429 rate_limited; 502 unreachable;
  /// 503 disabled). Every error carries a localized `message`.
  Future<Map<String, dynamic>> hzLink(String code) =>
      postJsonRaw('/halaladz/link', {'code': code});

  /// POST /halaladz/unlink -> {linked: false}.
  Future<Map<String, dynamic>> hzUnlink() => postJson('/halaladz/unlink');

  /// GET /halaladz/support -> {ticket, messages[{id, sender, text, kind,
  /// media_url, duration_ms, at}]}. Marks the team's replies read.
  Future<Map<String, dynamic>> hzSupport() => getJson('/halaladz/support');

  /// POST /halaladz/support — text and/or ONE photo / voice note (base64).
  /// Raw answer with `_status` (201 sent; 400 / 429 carry `message`).
  Future<Map<String, dynamic>> hzSupportSend(
          {String text = '',
          String? photoB64,
          String? voiceB64,
          int durationMs = 0}) =>
      postJsonRaw('/halaladz/support', {
        if (text.isNotEmpty) 'text': text,
        if (photoB64 != null) 'photo_b64': photoB64,
        if (voiceB64 != null) 'voice_b64': voiceB64,
        if (voiceB64 != null) 'duration_ms': durationMs,
      });
}

/// The link code rule (server checks it again): 8 letters / digits, spaces
/// and dashes ignored, upper-cased.
String? normHzCode(String? raw) {
  final c = (raw ?? '').replaceAll(RegExp(r'[\s\-]'), '').toUpperCase();
  return RegExp(r'^[A-Z0-9]{8}$').hasMatch(c) ? c : null;
}

/// Only https pages on halaladz.com / lifeassisto.com (or their subdomains)
/// are ever opened from a HalalAdz notification. Same rule as the server.
Uri? hzSafeUri(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty || s.length > 500) return null;
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || u.userInfo.isNotEmpty) return null;
  if (u.hasPort && u.port != 443) return null;
  final h = u.host.toLowerCase();
  const ok = ['halaladz.com', 'lifeassisto.com'];
  if (!ok.any((d) => h == d || h.endsWith('.$d'))) return null;
  return u;
}
