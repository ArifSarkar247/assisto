import 'dart:convert';

import '../api.dart';

/// train: Train Tracker API (server: backend/core/train_views.py), built only
/// on the generic getJson / postJson helpers.
extension TrainApi on ApiClient {
  Future<Map<String, dynamic>> trainConfig() => getJson('/train/config');

  Future<Map<String, dynamic>> trainSearch(String q) =>
      getJson('/train/search?q=${Uri.encodeQueryComponent(q)}');

  Future<Map<String, dynamic>> trainLive(String no, String date) =>
      getJson('/train/$no/live?date=$date');

  Future<Map<String, dynamic>> trainShareStart(String no, String date) =>
      postJson('/train/$no/share', {'date': date});

  Future<Map<String, dynamic>> trainShareFixes(int id, List<Map<String, dynamic>> pts) =>
      postJson('/train/share/$id/fixes', {'points': pts});

  Future<Map<String, dynamic>> trainShareStop(int id) => postJson('/train/share/$id/stop');

  Future<Map<String, dynamic>> trainChat(String no, String date, {int after = 0}) =>
      getJson('/train/$no/chat?date=$date&after=$after');

  Future<Map<String, dynamic>> trainChatJoin(String no, String date, String nickname) =>
      postJson('/train/$no/chat/join', {'date': date, 'nickname': nickname});

  Future<Map<String, dynamic>> trainChatSay(String no, String date, String text) =>
      postJson('/train/$no/chat', {'date': date, 'text': text});

  Future<Map<String, dynamic>> trainChatLeave(String no, String date) =>
      postJson('/train/$no/chat/leave', {'date': date});

  /// action: report | block | circle (circle = a REQUEST the other person decides)
  Future<Map<String, dynamic>> trainMsgAction(int id, String action, {String? reason}) =>
      postJson('/train/chat/msg/$id/$action', {if (reason != null) 'reason': reason});

  /// action: accept | decline
  Future<Map<String, dynamic>> trainRequestAct(int id, String action) =>
      postJson('/train/chat/request/$id/$action');
}

/// SMS "TR <no>" to 16318 — opened in the phone's OWN SMS app; the user
/// presses Send (৳4 from their balance). Assisto never sends it.
Uri trainSmsUri(String no) => Uri.parse('sms:16318?body=${Uri.encodeComponent('TR $no')}');

/// One-tap dial (opens the dialer; never auto-dials).
Uri trainTelUri(String number) => Uri.parse('tel:$number');

/// Emergency words — the app shows 999 / 131 at once (the server also
/// flags every message). Latin (English + Banglish) words live here; the
/// Bangla ones are data in assets/train/emergency_words.json (mirror of
/// backend/core/logic/train_chat.py).
const List<String> kTrainEmergencyLatin = [
  'help', 'sick', 'emergency', 'sos', 'fire', 'robbery', 'attack', 'accident', 'ambulance',
  'police', 'osustho', 'osusto', 'shahajjo', 'sahajjo', 'bachao', 'bipod', 'dakat', 'agun',
];

List<String> parseEmergencyWords(String raw) {
  try {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return [for (final w in (j['bn'] as List? ?? const [])) '$w'];
  } catch (_) {
    return const []; // best-effort: Latin words + server flag still work
  }
}

bool trainIsEmergency(String text, [List<String> bangla = const []]) {
  final t = text.toLowerCase();
  for (final w in kTrainEmergencyLatin) {
    if (RegExp('(?<![a-z])$w(?![a-z])').hasMatch(t)) return true;
  }
  return bangla.any(t.contains);
}

/// sjtrain (Safe Journey V2): the crowd-sourced seat card.
extension TrainSeatApi on ApiClient {
  Future<Map<String, dynamic>> trainSeat(String no, String date, String coach, String seat) =>
      getJson('/train/$no/seat?date=$date&coach=${Uri.encodeQueryComponent(coach)}'
          '&seat=${Uri.encodeQueryComponent(seat)}');

  Future<Map<String, dynamic>> trainSeatAnswer(String no, String date, String coach, String seat,
          {String facing = '', String place = '', String side = '', int? coachPos}) =>
      postJson('/train/$no/seat', {
        'date': date,
        'coach': coach,
        'seat': seat,
        if (facing.isNotEmpty) 'facing': facing,
        if (place.isNotEmpty) 'place': place,
        if (side.isNotEmpty) 'side': side,
        if (coachPos != null) 'coach_pos': coachPos,
      });
}

/// train-app (Train Tracker V2): check-in, shared text, offline pack.
/// Server: the engine lane (ci/train-engine-arb); contract in
/// owner_actions/TRAIN_TRACKER_V2_BN.md (app section).
extension TrainV2Api on ApiClient {
  /// body: {date, station_id, kind: reached|left, at, lat?, lng?, acc?}
  /// -> {ok, status: accepted|pending|rejected, reason?, points}
  Future<Map<String, dynamic>> trainCheckin(String no, Map<String, dynamic> body) =>
      postJson('/train/$no/checkin', body);

  /// ANY text the user shared / pasted (16318 reply, a group post...):
  /// body {text, no?, date?, source: paste|share, at}
  /// -> {ok, parsed: {...}|null, applied}
  Future<Map<String, dynamic>> trainText(Map<String, dynamic> body) =>
      postJson('/train/text', body);

  /// -> {version, size_bytes, updated_at}
  Future<Map<String, dynamic>> trainOfflineMeta() => getJson('/train/offline/meta');

  /// The whole pack (or {not_modified: true} when [have] is current).
  Future<Map<String, dynamic>> trainOfflinePack(String? have) => getJson(
      '/train/offline/pack${have == null ? '' : '?have=${Uri.encodeQueryComponent(have)}'}');
}
