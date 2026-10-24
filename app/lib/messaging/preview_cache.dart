import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// a1-circle — the chat-list preview text this phone ALREADY decrypted, one
/// entry per chat ("member:12" → {id, text}).
///
/// The chat screen writes the newest message it showed; the chat list uses
/// it when the row's last message can't be decrypted with any key the phone
/// knows (e.g. the peer reinstalled and the old key is gone). Keyed by the
/// message id, so a stale entry is never shown for a newer message. Stays on
/// this phone only (like the outbox), never sent anywhere.
class PreviewCache {
  PreviewCache._();
  static final PreviewCache instance = PreviewCache._();
  static const _k = 'a1_preview_cache_v1';
  static const _maxChats = 200;
  static const _maxText = 160;

  Map<String, Map<String, String>>? _mem;

  Future<Map<String, Map<String, String>>> _load() async {
    final m = _mem;
    if (m != null) return m;
    final out = <String, Map<String, String>>{};
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_k);
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) {
          if (v is Map) {
            out['$k'] = {'id': '${v['id'] ?? ''}', 'text': '${v['text'] ?? ''}'};
          }
        });
      }
    } catch (_) {}
    return _mem = out;
  }

  /// The cached preview text for [chatKey] when it belongs to message [msgId].
  Future<String?> textFor(String chatKey, String msgId) async {
    final e = (await _load())[chatKey];
    if (e == null || e['id'] != msgId || (e['text'] ?? '').isEmpty) return null;
    return e['text'];
  }

  /// Synchronous read of the loaded map (null before the first [warm]).
  String? peek(String chatKey, String msgId) {
    final e = _mem?[chatKey];
    if (e == null || e['id'] != msgId || (e['text'] ?? '').isEmpty) return null;
    return e['text'];
  }

  Future<void> warm() => _load();

  Future<void> put(String chatKey, String msgId, String text) async {
    final t = text.replaceAll('\n', ' ').trim();
    if (msgId.isEmpty || t.isEmpty) return;
    final m = await _load();
    final cur = m[chatKey];
    final v = t.length > _maxText ? t.substring(0, _maxText) : t;
    if (cur != null && cur['id'] == msgId && cur['text'] == v) return;
    m.remove(chatKey);
    m[chatKey] = {'id': msgId, 'text': v};
    while (m.length > _maxChats) {
      m.remove(m.keys.first);
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_k, jsonEncode(m));
    } catch (_) {}
  }

  /// e-gaps: forget [chatKey]'s preview when it is message [msgId] (a
  /// disappearing message expired, a view-once photo was opened).
  Future<void> drop(String chatKey, String msgId) async {
    final m = await _load();
    final cur = m[chatKey];
    if (cur == null || cur['id'] != msgId) return;
    m.remove(chatKey);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_k, jsonEncode(m));
    } catch (_) {}
  }

  /// Tests only.
  void resetForTest() => _mem = null;
}
