import 'dart:convert';

import 'api.dart';

/// kidswatch (owner idea 2, 28 Oct) — Kids GPS watch + Child School Mode,
/// built only on the generic getJson / postJson / patchJson / deleteJson /
/// getBytes helpers (no api.dart edit). Server: backend/core/kidswatch_views.py.
/// Behind the server flag `kids_watch` (OFF); the CHILD's side
/// (/school-mode/mine, stop, delete history) is never flag-gated.
extension KidsWatchApi on ApiClient {
  Future<Map<String, dynamic>> kwConfig() => getJson('/kids-watch/config');

  Future<Map<String, dynamic>> kwWatches() => getJson('/kids-watch/watches');

  Future<Map<String, dynamic>> kwPair(
          {required String code,
          required String childName,
          List<int> guardianIds = const [],
          List<String> sosNumbers = const [],
          int? childUserId}) =>
      postJson('/kids-watch/watches', {
        'code': code,
        'child_name': childName,
        'guardian_ids': guardianIds,
        'sos_numbers': sosNumbers,
        if (childUserId != null) 'child_user_id': childUserId,
      });

  Future<Map<String, dynamic>> kwUpdate(int id, Map<String, dynamic> body) =>
      patchJson('/kids-watch/watches/$id', body);

  Future<Map<String, dynamic>> kwRemove(int id) => deleteJson('/kids-watch/watches/$id');

  Future<Map<String, dynamic>> kwRepair(int id) => postJson('/kids-watch/watches/$id/repair');

  /// Only 'locate_now' and 'find_watch' exist. There is no listen command.
  Future<Map<String, dynamic>> kwCommand(int id, String kind) =>
      postJson('/kids-watch/watches/$id/command', {'kind': kind});

  Future<Map<String, dynamic>> kwVoiceList(int id) =>
      getJson('/kids-watch/watches/$id/voice');

  Future<Map<String, dynamic>> kwSendVoice(int id, List<int> amr) =>
      postJson('/kids-watch/watches/$id/voice', {'audio_b64': base64Encode(amr)});

  Future<List<int>> kwVoiceAudio(int noteId) => getBytes('/kids-watch/voice/$noteId/audio');

  Future<Map<String, dynamic>> kwTranscript(int noteId) =>
      postJson('/kids-watch/voice/$noteId/transcript');

  Future<Map<String, dynamic>> smPeople() => getJson('/school-mode/people');

  Future<Map<String, dynamic>> smPlaces() => getJson('/school-mode/places');

  Future<Map<String, dynamic>> smPlans() => getJson('/school-mode/plans');

  Future<Map<String, dynamic>> smMine() => getJson('/school-mode/mine');

  Future<Map<String, dynamic>> smCreate(Map<String, dynamic> body) =>
      postJson('/school-mode/plans', body);

  Future<Map<String, dynamic>> smUpdate(int id, Map<String, dynamic> body) =>
      patchJson('/school-mode/plans/$id', body);

  Future<Map<String, dynamic>> smDelete(int id) => deleteJson('/school-mode/plans/$id');

  /// accept | stop | pause-today | resume-today
  Future<Map<String, dynamic>> smAction(int id, String action) =>
      postJson('/school-mode/plans/$id/$action');

  /// The child's big button: leaving | arrived | ok.
  Future<Map<String, dynamic>> smCheckin(int id, String kind,
          {double? lat, double? lng, List<int>? audio, String mime = 'audio/mp4'}) =>
      postJson('/school-mode/plans/$id/checkin', {
        'kind': kind,
        if (lat != null && lng != null) 'lat': lat,
        if (lat != null && lng != null) 'lng': lng,
        if (audio != null && audio.isNotEmpty) 'audio_b64': base64Encode(audio),
        if (audio != null && audio.isNotEmpty) 'mime': mime,
      });

  Future<Map<String, dynamic>> smEvents(int id) => getJson('/school-mode/plans/$id/events');

  Future<Map<String, dynamic>> smClearHistory(int id) =>
      postJson('/school-mode/plans/$id/events/clear');
}

/// Typed list helper: rows under [key] of a JSON map.
List<Map<String, dynamic>> kwRows(Map<String, dynamic>? r, String key) {
  final raw = r == null ? null : r[key];
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
}

/// 'HH:mm' (24 h) of an ISO time in the phone's local zone, '' if none.
String kwClock(Object? iso) {
  if (iso is! String || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final l = d.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')}';
}
