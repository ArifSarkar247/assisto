import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../security/secret_store.dart'; // offline1st

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

  /// offline1st: the decrypted preview text is kept ENCRYPTED AT REST
  /// ([SecretStore], no_backup) instead of plain SharedPreferences. Unit
  /// tests switch this off (test/flutter_test_config.dart) because they reset
  /// SharedPreferences per test; preview_cache_secret_test covers it.
  static bool encrypted = true;
  static const _slot = 'a1_preview_cache_v2';

  Future<Map<String, Map<String, String>>> _load() async {
    final m = _mem;
    if (m != null) return m;
    final out = <String, Map<String, String>>{};
    void adopt(String? raw) {
      if (raw == null || raw.isEmpty) return;
      (jsonDecode(raw) as Map).forEach((k, v) {
        if (v is Map) {
          out.putIfAbsent('$k', () => {'id': '${v['id'] ?? ''}', 'text': '${v['text'] ?? ''}'});
        }
      });
    }
    if (encrypted) {
      try {
        adopt(await SecretStore.instance.read(_slot));
      } catch (_) {}
    }
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_k);
      adopt(raw);
      if (encrypted && raw != null) {
        // one-time move off the plaintext store
        if (await SecretStore.instance.write(_slot, jsonEncode(out))) {
          await p.remove(_k);
        }
      }
    } catch (_) {}
    return _mem = out;
  }

  Future<void> _persist(Map<String, Map<String, String>> m) async {
    try {
      if (encrypted) {
        await SecretStore.instance.write(_slot, jsonEncode(m));
        return;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString(_k, jsonEncode(m));
    } catch (_) {}
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
    await _persist(m);
  }

  /// e-gaps: forget [chatKey]'s preview when it is message [msgId] (a
  /// disappearing message expired, a view-once photo was opened).
  Future<void> drop(String chatKey, String msgId) async {
    final m = await _load();
    final cur = m[chatKey];
    if (cur == null || cur['id'] != msgId) return;
    m.remove(chatKey);
    await _persist(m);
  }

  /// chat-actions: forget [chatKey]'s preview entirely (chat cleared /
  /// deleted on this phone).
  Future<void> dropChat(String chatKey) async {
    final m = await _load();
    if (m.remove(chatKey) == null) return;
    await _persist(m);
  }

  /// Tests only.
  void resetForTest() => _mem = null;
}
