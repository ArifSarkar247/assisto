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

/// Emergency words — the app shows 999 / 131 at once (also told by the server).
const List<String> kTrainEmergencyWords = [
  'অসুস্থ', 'সাহায্য', 'বাঁচাও', 'বাচাও', 'জরুরি', 'জরুরী', 'বিপদ', 'ডাকাত', 'ছিনতাই',
  'হামলা', 'আগুন', 'অজ্ঞান', 'দুর্ঘটনা', 'help', 'sick', 'emergency', 'sos', 'fire',
  'robbery', 'attack', 'accident', 'ambulance', 'police', 'osustho', 'shahajjo', 'sahajjo',
  'bachao', 'bipod', 'dakat', 'agun',
];

bool trainIsEmergency(String text) {
  final t = text.toLowerCase();
  for (final w in kTrainEmergencyWords) {
    if (RegExp(r'^[a-z]+$').hasMatch(w)) {
      if (RegExp('(?<![a-z])$w(?![a-z])').hasMatch(t)) return true;
    } else if (t.contains(w)) {
      return true;
    }
  }
  return false;
}
