import 'api.dart';

/// kidaudio (owner 2 Nov PART 1 b) — child emergency audio. Built only on the
/// generic getJson / postJsonRaw helpers (no api.dart edit). Server:
/// backend/core/kid_audio_views.py, flag `child_emergency_audio` (OFF).
/// Literal paths (one per server route) so the API contract test resolves
/// every call. postJsonRaw never throws on a 4xx: the body carries
/// {ok, reason} + `_status`.
extension KidAudioApi on ApiClient {
  Future<Map<String, dynamic>> kauConfig() => getJson('/kid-audio/config');

  Future<Map<String, dynamic>> kauLog() => getJson('/kid-audio/log');

  Future<Map<String, dynamic>> kauPending() => getJson('/kid-audio/pending');

  /// The parent's side of the advance consent.
  Future<Map<String, dynamic>> kauSetConsent(Map<String, dynamic> body) =>
      postJsonRaw('/kid-audio/consent', body);

  /// The child's own agreement (confirms the birth year).
  Future<Map<String, dynamic>> kauAgree(int consentId, int birthYear) =>
      postJsonRaw('/kid-audio/consent/$consentId/agree', {'birth_year': birthYear});

  /// Either side, any time.
  Future<Map<String, dynamic>> kauRevoke(int consentId) =>
      postJsonRaw('/kid-audio/consent/$consentId/revoke');

  /// The parent asks to listen ('phone') or to call the watch ('watch').
  Future<Map<String, dynamic>> kauListen(int consentId, String channel) =>
      postJsonRaw('/kid-audio/listen', {'consent_id': consentId, 'channel': channel});

  /// started (child phone, with notice_shown) | stop (either side).
  Future<Map<String, dynamic>> kauEvent(int sessionId, Map<String, dynamic> body) =>
      postJsonRaw('/kid-audio/sessions/$sessionId/event', body);
}
