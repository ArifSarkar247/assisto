import 'dart:async';
import 'dart:convert';

import '../security/secret_store.dart';

/// offline1st — the LOCAL, ENCRYPTED copy of what the user last saw, so the
/// app opens like WhatsApp with no internet: the signed-in profile, the My
/// Circle member + chat lists and the newest page of each opened chat.
///
/// Storage = [SecretStore]: one file per slot, ChaCha20-Poly1305 under the
/// app-sandbox wrap key, in the `no_backup` directory (never in a cloud
/// backup, never on the server) — the same store that already holds the login
/// token and the E2E identity, and that works on every Android brand (no
/// Keystore dependency; OEM fallback built in).
///
/// Chat messages are stored exactly as the server relayed them: END-TO-END
/// CIPHERTEXT envelopes (the plaintext this phone already decrypted lives in
/// the separate PlainCache). So the at-rest copy is encrypted twice.
///
/// Per account: slots are named `off1_<uid>_<name>`; an index slot lists
/// them so [clearAccount] (logout / account switch) wipes every one.
/// Size-capped: at most [maxChats] chat pages (least recently used dropped).
class OfflineStore {
  OfflineStore({SecretStore? store}) : _store = store, _memoryOnly = false;

  /// Unit tests: a fresh in-memory store per test (test/flutter_test_config).
  OfflineStore.memoryOnly() : _store = null, _memoryOnly = true;
  final bool _memoryOnly;

  static OfflineStore instance = OfflineStore();

  static const maxChats = 40;
  static const _prefix = 'off1_';

  final SecretStore? _store;
  SecretStore get _s => _store ?? SecretStore.instance;

  /// In-memory mirror (the second read of a slot costs nothing).
  final Map<String, Object?> _mem = {};

  String _slot(Object uid, String name) =>
      '$_prefix${_safe('$uid')}_${_safe(name)}';
  String _indexSlot(Object uid) => '$_prefix${_safe('$uid')}__index';

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');

  /// The cached JSON value of [name] for account [uid] (null when none or
  /// unreadable). Never throws.
  Future<Object?> read(Object? uid, String name) async {
    if (uid == null || '$uid'.isEmpty) return null;
    final slot = _slot(uid, name);
    if (_mem.containsKey(slot)) return _mem[slot];
    if (_memoryOnly) return null;
    try {
      final raw = await _s.read(slot);
      final v = raw == null ? null : jsonDecode(raw);
      _mem[slot] = v;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Store [value] (JSON-encodable) for account [uid]. Never throws.
  Future<void> write(Object? uid, String name, Object? value) async {
    if (uid == null || '$uid'.isEmpty) return;
    final slot = _slot(uid, name);
    _mem[slot] = value;
    if (_memoryOnly) return;
    try {
      await _s.write(slot, jsonEncode(value));
      await _touchIndex(uid, name);
    } catch (_) {}
  }

  Future<List<String>> _index(Object uid) async {
    try {
      final raw = await _s.read(_indexSlot(uid));
      if (raw == null) return [];
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _touchIndex(Object uid, String name) async {
    final idx = await _index(uid);
    idx.remove(name);
    idx.add(name); // most recently written last
    // LRU cap on the per-chat pages (lists/profile are always kept)
    final chats = idx.where((n) => n.startsWith('msgs:')).toList();
    final drop = chats.length > maxChats
        ? chats.sublist(0, chats.length - maxChats)
        : const <String>[];
    for (final n in drop) {
      idx.remove(n);
      final slot = _slot(uid, n);
      _mem.remove(slot);
      await _s.delete(slot);
    }
    await _s.write(_indexSlot(uid), jsonEncode(idx));
  }

  /// Remove one slot (e.g. a chat the user cleared / deleted).
  Future<void> remove(Object? uid, String name) async {
    if (uid == null) return;
    final slot = _slot(uid, name);
    _mem.remove(slot);
    if (_memoryOnly) return;
    try {
      await _s.delete(slot);
    } catch (_) {}
  }

  /// Wipe everything cached for account [uid] (logout, account deleted).
  Future<void> clearAccount(Object? uid) async {
    if (uid == null) return;
    if (_memoryOnly) {
      _mem.removeWhere((k, _) => k.startsWith('$_prefix${_safe('$uid')}_'));
      return;
    }
    try {
      for (final n in await _index(uid)) {
        await _s.delete(_slot(uid, n));
      }
      await _s.delete(_indexSlot(uid));
    } catch (_) {}
    _mem.removeWhere((k, _) => k.startsWith('$_prefix${_safe('$uid')}_'));
  }

  /// The signed-in account (set by AppState) — for callers without one.
  Object? currentUid;

  /// A chat was cleared / deleted for me: its saved page must never come back.
  Future<void> dropChat(String chatKey) => remove(currentUid, 'msgs:$chatKey');

  // ---------------------------------------------------------- named slots
  static String chatSlot(String kind, Object id) => 'msgs:$kind:$id';
  static const chatList = 'circle_chats';
  static const members = 'circle_members';
}

/// The signed-in profile, kept OUTSIDE the per-account slots (it is how the
/// app knows WHICH account it is before any network): one fixed slot.
class CachedSession {
  static const slot = 'off1_me_v1';

  static Future<Map<String, dynamic>?> readUser({SecretStore? store}) async {
    try {
      final raw = await (store ?? SecretStore.instance).read(slot);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      return j is Map ? j.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeUser(Map<String, dynamic> j, {SecretStore? store}) async {
    try {
      await (store ?? SecretStore.instance).write(slot, jsonEncode(j));
    } catch (_) {}
  }

  static Future<void> clear({SecretStore? store}) async {
    try {
      await (store ?? SecretStore.instance).delete(slot);
    } catch (_) {}
  }
}
