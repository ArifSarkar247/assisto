import 'dart:async';
import 'dart:convert';

import '../security/secret_store.dart';

/// e2e-recover item 4 — a LOCAL cache of messages this phone already
/// decrypted, so a chat that was read once never breaks on later key
/// trouble. It lives in [SecretStore] (ChaCha20-Poly1305 under the sandbox
/// wrap key, no_backup dir — never in a cloud backup, never on the server),
/// per signed-in account, size-capped (oldest dropped first).
///
/// Not cached: view-once media and anything deleted for everyone (callers
/// skip those), so the cache can never resurrect what should be gone.
class PlainCache {
  PlainCache({SecretStore? store}) : _store = store;

  static PlainCache instance = PlainCache();

  static const maxEntries = 3000;
  static const maxChars = 1500000;
  static const _slotPrefix = 'e2_plain_cache_v1_';

  final SecretStore? _store;
  SecretStore get _s => _store ?? SecretStore.instance;

  String _owner = '';
  // insertion-ordered: oldest first
  final Map<String, String> _m = <String, String>{};
  int _chars = 0;
  bool _warm = false;
  Future<void>? _warming;

  /// Load the cache of account [owner] (once; switching account reloads).
  Future<void> warm(Object? owner) {
    final o = '${owner ?? ''}';
    if (_warm && o == _owner) return Future.value();
    if (o != _owner) {
      _m.clear();
      _chars = 0;
      _warm = false;
      _warming = null;
      _owner = o;
    }
    return _warming ??= _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _s.read('$_slotPrefix$_owner');
      if (raw != null) {
        final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
        for (final e in j.entries) {
          final v = '${e.value}';
          _m[e.key] = v;
          _chars += v.length;
        }
      }
    } catch (_) {}
    _warm = true;
  }

  /// The cached plaintext of message [id] (sync; null when unknown).
  String? get(String id) => id.isEmpty ? null : _m[id];

  void put(String id, String plaintext) {
    if (id.isEmpty || int.tryParse(id) == null) return; // server ids only
    if (_m[id] == plaintext) return;
    final old = _m.remove(id);
    if (old != null) _chars -= old.length;
    _m[id] = plaintext;
    _chars += plaintext.length;
    while (_m.length > maxEntries || _chars > maxChars) {
      final k = _m.keys.first;
      _chars -= _m.remove(k)!.length;
    }
    _schedule();
  }

  void remove(String id) {
    final old = _m.remove(id);
    if (old == null) return;
    _chars -= old.length;
    _schedule();
  }

  // No timers (they would outlive widget tests): callers flush after each
  // decrypted batch; writes are coalesced while one is running.
  void _schedule() => _dirty = true;

  bool _dirty = false;
  Future<void>? _writing;

  /// Write the cache if anything changed. Never throws.
  Future<void> persist() async {
    if (!_dirty || !_warm) return;
    final w = _writing;
    if (w != null) return w;
    _dirty = false;
    final run = () async {
      try {
        await _s.write('$_slotPrefix$_owner', jsonEncode(_m));
      } catch (_) {}
    }();
    _writing = run;
    await run;
    _writing = null;
  }

  int get length => _m.length;

  /// TESTS: forget memory (simulates an app restart; disk stays).
  void resetForTests() {
    _dirty = false;
    _writing = null;
    _m.clear();
    _chars = 0;
    _warm = false;
    _warming = null;
    _owner = '';
  }
}
