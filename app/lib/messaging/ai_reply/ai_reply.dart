/// ai-reply-core (owner order 17 Nov): AI reply in My Circle — the app side.
///
/// My Circle is end-to-end encrypted: only THIS phone can read a message.
/// So the phone decrypts the incoming text, sends it to the server for a
/// moment (POST /ai/reply/suggest or /ai/reply/auto — never stored, never
/// logged), and sends the AI reply itself, encrypted, with the single-use
/// `ai_reply_token` that makes the server tag it "Assisto AI reply".
///
/// Modes per person: off | suggest | busy | auto. Groups: off | suggest
/// (the server enforces it). Contract: owner_actions/AI_REPLY_SPEC_BN.md.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../config.dart';

const kAiReplyFlag = 'ai_reply';
const kAiReplyModes = ['off', 'suggest', 'busy', 'auto'];
const kAiBusyMinutes = [30, 60, 120, 0]; // 0 = until I turn it off
const kAiUnlockPlacement = 'ai_reply_unlock';

/// The server's view of one chat's AI reply settings.
@immutable
class AiReplyState {
  final bool enabled;
  final String mode;
  final List<String> allowedModes;
  final DateTime? busyUntil;
  final bool labelOn;
  final bool isGroup;
  final bool child;
  final bool styleConsent;
  final int creditsPerReply;
  final int freeLeft;
  final String unlock; // ad | premium
  final int? adsPerReply;
  final List<Map<String, dynamic>> held;

  const AiReplyState({
    this.enabled = false,
    this.mode = 'off',
    this.allowedModes = const ['off'],
    this.busyUntil,
    this.labelOn = true,
    this.isGroup = false,
    this.child = false,
    this.styleConsent = false,
    this.creditsPerReply = 1,
    this.freeLeft = 0,
    this.unlock = 'premium',
    this.adsPerReply,
    this.held = const [],
  });

  factory AiReplyState.fromJson(Map<String, dynamic> j) => AiReplyState(
        enabled: j['enabled'] == true,
        mode: kAiReplyModes.contains(j['mode']) ? '${j['mode']}' : 'off',
        allowedModes: ((j['allowed_modes'] as List?) ?? const ['off'])
            .map((e) => '$e')
            .where(kAiReplyModes.contains)
            .toList(),
        busyUntil: DateTime.tryParse('${j['busy_until'] ?? ''}')?.toLocal(),
        labelOn: j['label_on'] != false,
        isGroup: j['is_group'] == true,
        child: j['child'] == true,
        styleConsent: j['style_consent'] == true,
        creditsPerReply: (j['credits_per_reply'] as num?)?.toInt() ?? 1,
        freeLeft: (j['free_left'] as num?)?.toInt() ?? 0,
        unlock: '${j['unlock'] ?? 'premium'}',
        adsPerReply: (j['ads_per_reply'] as num?)?.toInt(),
        held: ((j['held'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList(),
      );

  bool get suggests => mode == 'suggest';
  bool get autoReplies => mode == 'busy' || mode == 'auto';
}

/// The answer of POST /ai/reply/suggest.
@immutable
class AiSuggestResult {
  final List<String> suggestions;
  final String reason; // '' = ok | blocked | no_credits | rate_limited | ...
  final String category;
  final String unlock;
  const AiSuggestResult(
      {this.suggestions = const [], this.reason = '', this.category = '', this.unlock = ''});
  bool get needsYou => reason == 'blocked';
  bool get noCredits => reason == 'no_credits';

  factory AiSuggestResult.fromJson(Map<String, dynamic> j) => AiSuggestResult(
        suggestions: j['ok'] == true
            ? ((j['suggestions'] as List?) ?? const []).map((e) => '$e').toList()
            : const [],
        reason: j['ok'] == true ? '' : '${j['reason'] ?? 'error'}',
        category: '${j['category'] ?? ''}',
        unlock: '${j['unlock'] ?? ''}',
      );
}

/// Thin client over the app's [ApiClient].
class AiReplyApi {
  final ApiClient api;
  AiReplyApi(this.api);

  String _path(bool group, int id) => '/ai/reply/settings/${group ? 'group' : 'member'}/$id';

  Future<AiReplyState> load({required bool group, required int id}) async {
    final s = AiReplyState.fromJson(await api.getJson(_path(group, id)));
    if (!group) await AiReplyLocal.save(id, s);
    return s;
  }

  Future<AiReplyState> save(
      {required bool group, required int id, String? mode, int? busyMinutes, bool? labelOn}) async {
    final s = AiReplyState.fromJson(await api.postJson(_path(group, id), {
      if (mode != null) 'mode': mode,
      if (busyMinutes != null) 'busy_minutes': busyMinutes,
      if (labelOn != null) 'label_on': labelOn,
    }));
    if (!group) await AiReplyLocal.save(id, s);
    return s;
  }

  Future<AiSuggestResult> suggest({
    required String text,
    required List<Map<String, String>> context,
    int? memberId,
    int? groupId,
  }) async {
    try {
      return AiSuggestResult.fromJson(await api.postJson('/ai/reply/suggest', {
        'source': 'circle',
        'text': text,
        'context': context,
        'lang': 'auto',
        'is_group': groupId != null,
        if (memberId != null) 'member_id': memberId,
        if (groupId != null) 'group_id': groupId,
      }));
    } on ApiException catch (e) {
      return AiSuggestResult(
          reason: e.reason ?? 'error', unlock: '${e.body?['unlock'] ?? ''}');
    }
  }

  Future<Map<String, dynamic>> auto(Map<String, dynamic> body) =>
      api.postJson('/ai/reply/auto', body);

  Future<bool> styleConsent() async =>
      (await api.getJson('/ai/reply/style'))['consent'] == true;

  Future<void> setStyleConsent(bool on) => api.postJson('/ai/reply/style', {'consent': on});

  Future<void> learn(List<String> ownSentTexts) =>
      api.postJson('/ai/reply/style/learn', {'samples': ownSentTexts.take(200).toList()});

  Future<void> heldSeen(int id) => api.postJson('/ai/reply/held/$id/seen');
}

/// Local copy of the per-chat mode, so a message push only calls the
/// server when this chat is really on Busy / Full auto (no extra request
/// for every message of every chat). SharedPreferences works in the FCM
/// background isolate too.
class AiReplyLocal {
  static String _k(int memberId) => 'aireply.m.$memberId';

  static Future<void> save(int memberId, AiReplyState s) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!s.enabled || !s.autoReplies) {
        await p.remove(_k(memberId));
        return;
      }
      await p.setString(_k(memberId), jsonEncode({
        'mode': s.mode,
        'until': s.busyUntil?.millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  /// Is this 1:1 chat on Busy (not expired) or Full auto on this phone?
  static Future<bool> autoOn(int memberId, {DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_k(memberId));
      if (raw == null) return false;
      return autoOnFrom(jsonDecode(raw) as Map<String, dynamic>, now ?? DateTime.now());
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static bool autoOnFrom(Map<String, dynamic> j, DateTime now) {
    final mode = '${j['mode'] ?? ''}';
    if (mode == 'auto') return true;
    if (mode != 'busy') return false;
    final until = j['until'];
    return until == null || DateTime.fromMillisecondsSinceEpoch(until as int).isAfter(now);
  }
}

/// PURE: the message a Busy / Full-auto reply should answer, from a list of
/// rows (newest last) — the LAST row, only when it is the peer's plain text
/// (if I already wrote after it, there is nothing to answer).
Map<String, dynamic>? aiIncomingToAnswer(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return null;
  final last = rows.last;
  if (last['mine'] == true) return null;
  if ('${last['content_type'] ?? 'text'}' != 'text') return null;
  if ('${last['deleted'] ?? ''}'.isNotEmpty) return null;
  if (last['ai_reply'] == true) return null; // loop guard (the server checks too)
  return last;
}

/// PURE: up to 4 earlier text lines as {from: me|them, text}.
List<Map<String, String>> aiContext(
    List<Map<String, dynamic>> rows, String? Function(Map<String, dynamic>) text) {
  final out = <Map<String, String>>[];
  final upto = rows.isEmpty ? 0 : rows.length - 1;
  for (var i = (upto - 4).clamp(0, upto); i < upto; i++) {
    final r = rows[i];
    if ('${r['content_type'] ?? 'text'}' != 'text') continue;
    final s = text(r);
    if (s == null || s.trim().isEmpty) continue;
    out.add({'from': r['mine'] == true ? 'me' : 'them', 'text': s.trim()});
  }
  return out;
}

/// The background (FCM isolate) HTTP side of a Busy / Full-auto reply.
abstract class AiAutoBackend {
  Future<Map<String, dynamic>> auto(Map<String, dynamic> body);
}

class AiReplyHttp implements AiAutoBackend {
  final String token;
  final String lang;
  final http.Client _c;
  AiReplyHttp(this.token, {this.lang = 'bn', http.Client? client})
      : _c = client ?? http.Client();

  @override
  Future<Map<String, dynamic>> auto(Map<String, dynamic> body) async {
    final r = await _c
        .post(AppConfig.api('/ai/reply/auto'),
            headers: {
              'Authorization': 'Token $token',
              'Content-Type': 'application/json',
              'Accept-Language': lang,
            },
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode < 200 || r.statusCode >= 300) throw StateError('http ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}
