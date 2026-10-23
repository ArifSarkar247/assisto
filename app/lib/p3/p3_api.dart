// P3 — My Circle API surface (@Assisto, stories, notes). Extension on
// ApiClient so api.dart stays untouched. Server contract: backend
// core/views_p3_circle.py.
import '../api.dart';

/// Outcome of an @Assisto AI run. [error] is '' on success, else one of
/// credits | paused | limit | ai_off | busy | consent_required | empty | net.
class AssistoRun {
  final String result;
  final String error;
  final int charged;
  final int? balance;
  const AssistoRun({this.result = '', this.error = '', this.charged = 0, this.balance});
  bool get ok => error.isEmpty;
}

/// Credit costs shown BEFORE an AI action runs.
class AssistoQuote {
  final Map<String, int> credits; // summarize/translate/ask -> credits
  final int balance;
  final bool aiAvailable;
  final int maxMessages;
  const AssistoQuote(this.credits, this.balance, this.aiAvailable, this.maxMessages);
  int cost(String action) => credits[action] ?? 1;

  static AssistoQuote fromJson(Map<String, dynamic> j) {
    final acts = (j['actions'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AssistoQuote(
      {
        for (final e in acts.entries)
          e.key: ((e.value as Map?)?['credits'] as num?)?.toInt() ?? 1,
      },
      (j['balance'] as num?)?.toInt() ?? 0,
      j['ai_available'] == true,
      (j['max_messages'] as num?)?.toInt() ?? 80,
    );
  }
}

extension P3Api on ApiClient {
  /// GET /circle/assisto/quote
  Future<AssistoQuote> assistoQuote() async =>
      AssistoQuote.fromJson(await getJson('/circle/assisto/quote'));

  /// POST /circle/assisto/run — ONLY the text the user chose; `consent` is the
  /// user's explicit OK to send chat content to Assisto AI.
  Future<AssistoRun> assistoRun(String action,
      {List<Map<String, String>>? messages,
      String? text,
      String? question,
      String target = 'en',
      bool consent = false}) async {
    try {
      final r = await postJsonRaw('/circle/assisto/run', {
        'action': action,
        if (messages != null) 'messages': messages,
        if (text != null) 'text': text,
        if (question != null) 'question': question,
        'target': target,
        'consent': consent,
      });
      final st = (r['_status'] as int?) ?? 0;
      if (st >= 200 && st < 300 && r['ok'] == true) {
        return AssistoRun(
            result: '${r['result'] ?? ''}',
            charged: (r['charged'] as num?)?.toInt() ?? 0,
            balance: (r['balance'] as num?)?.toInt());
      }
      return AssistoRun(
          error: '${r['error'] ?? 'busy'}',
          balance: (r['balance'] as num?)?.toInt());
    } catch (_) {
      return const AssistoRun(error: 'net');
    }
  }

  // ---- stories ----
  Future<Map<String, dynamic>> storyTray() => getJson('/circle/status');
  Future<Map<String, dynamic>> storiesOf(int authorUserId) =>
      getJson('/circle/status/author/$authorUserId');
  Future<Map<String, dynamic>> myStories() => getJson('/circle/status/mine');
  Future<Map<String, dynamic>> postStory(Map<String, dynamic> body) =>
      postJson('/circle/status', body);
  Future<void> deleteStory(int id) => postJson('/circle/status/$id/delete');
  Future<void> seeStory(int id) => postJson('/circle/status/$id/view');
  Future<void> muteStories(int authorUserId, bool on) =>
      postJson('/circle/status/mute', {'author_id': authorUserId, 'on': on});
  Future<Map<String, dynamic>> privacyDefaults() =>
      getJson('/circle/status/privacy');
  Future<Map<String, dynamic>> savePrivacyDefaults(Map<String, dynamic> body) =>
      postJson('/circle/status/privacy', body);

  // ---- notes ----
  Future<Map<String, dynamic>> notes() => getJson('/circle/notes');
  Future<Map<String, dynamic>> postNote(Map<String, dynamic> body) =>
      postJson('/circle/notes', body);
  Future<void> clearNote() => postJson('/circle/notes/clear');
}
