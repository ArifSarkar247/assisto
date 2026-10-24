import 'dart:async';
import 'dart:convert';

import '../security/secret_store.dart';
import 'e2e.dart';

/// The ONE place the on-device E2E identity (X25519 key pair) is loaded,
/// created and stored — on top of [SecretStore] (encrypted app-sandbox file,
/// WhatsApp/Signal style; the Android Keystore is never required). Every
/// screen, the key publisher and the background push isolate use it.
///
/// Owner bug 22 Oct (OPPO Reno 12 F, ColorOS): the Keystore failed, each
/// screen then kept either a throw-away key that was never published or NO
/// key — tapping a chat did nothing and the peer's messages stayed on the
/// clock. Now:
///  * [get] never returns null and never throws;
///  * concurrent callers share one load (never two keys in one process);
///  * a stored identity that can no longer be read is replaced by a new one
///    ([rekeyed]); publishing it makes peers show "security code changed".
class IdentityVault {
  IdentityVault({SecretStore? store, E2E? e2e})
      : _store = store,
        _e2e = e2e ?? SoftwareE2E();

  static IdentityVault instance = IdentityVault();

  /// Same name as the old Keystore slot, so the first read migrates it.
  static const slot = 'circle_identity_v1';

  final SecretStore? _store;
  SecretStore get _s => _store ?? SecretStore.instance;
  final E2E _e2e;

  IdentityKeyPair? _cached;
  Future<IdentityKeyPair>? _inflight;

  /// True while the identity is only in memory (the sandbox write failed).
  bool volatile = false;

  /// True when a stored identity was unreadable and a new one was made.
  bool rekeyed = false;

  /// e2e-recover: the KEY RING — every private key this account ever used on
  /// this phone (current + earlier), kept so old chats always decrypt. Never
  /// shrinks on a re-key; only [SecretStore] (no_backup sandbox) holds it.
  static const ringSlot = 'circle_identity_ring_v1';
  static const ringMax = 32;

  /// e2e-recover: called ONCE before a brand-new identity would be generated
  /// (no current key and no key ring on this phone) — the restore-from-PIN
  /// prompt hooks in here so a reinstall keeps the SAME key. Guarded and
  /// time-boxed by the caller; may write a restored ring via [adoptRing].
  Future<void> Function()? beforeCreate;

  /// e2e-recover: told about every NEW key (first key / re-key) so the
  /// encrypted key backup can refresh. Never awaited, never throws into us.
  void Function(IdentityKeyPair id)? onNewKey;

  List<IdentityKeyPair>? _ringCache;

  /// Last key ring this process loaded (sync, for chat-list previews).
  static List<IdentityKeyPair> ringSnapshot = const [];

  /// The identity, created and stored on first use.
  Future<IdentityKeyPair> get() {
    final c = _cached;
    if (c != null) return Future.value(c);
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  /// The stored identity without creating one (background isolates).
  Future<IdentityKeyPair?> peek() async {
    final c = _cached;
    if (c != null) return c;
    final raw = await _s.read(slot);
    final id = raw == null ? null : _decode(raw);
    return id == null ? null : _cached = id;
  }

  Future<IdentityKeyPair> _load() async {
    final raw = await _s.read(slot);
    if (raw != null) {
      final id = _decode(raw);
      if (id != null) {
        unawaited(_remember(id));
        return _cached = id;
      }
      rekeyed = true; // unreadable -> re-key safely below
    }
    // e2e-recover: the ring still holds the newest key -> keep using it
    // (peers see no key change, nothing to recover).
    // (Only looked at when it can matter: an unreadable slot, or a new
    // install where the restore gate is wired — keeps the plain path to the
    // same storage round-trips as before.)
    var ring = (raw != null || beforeCreate != null)
        ? await _storedRing()
        : const <IdentityKeyPair>[];
    if (ring.isEmpty && beforeCreate != null) {
      try {
        await beforeCreate!();
      } catch (_) {}
      _ringCache = null;
      final again = await _s.read(slot);
      final restored = again == null ? null : _decode(again);
      if (restored != null) {
        unawaited(_remember(restored));
        return _cached = restored;
      }
      ring = await _storedRing();
    }
    if (ring.isNotEmpty) {
      final keep = ring.first;
      volatile = !await _s.write(slot, _encode(keep));
      rekeyed = false;
      return _cached = keep;
    }
    final id = _e2e.generateIdentity();
    volatile = !await _s.write(slot, _encode(id));
    if (volatile) {
      unawaited(_remember(id));
      return _cached = id;
    }
    // Another isolate may have stored one meanwhile: the stored one wins.
    final again = await _s.read(slot);
    final won = (again == null ? null : _decode(again)) ?? id;
    final hook = won.keyId == id.keyId ? onNewKey : null;
    unawaited(_remember(won).then((_) {
      try {
        hook?.call(won); // ring written first: the backup includes it
      } catch (_) {}
    }));
    return _cached = won;
  }

  // ------------------------------------------------------------ key ring
  /// Every private key of this phone, CURRENT FIRST, then newest-older.
  /// Never throws; [] when nothing is stored yet.
  Future<List<IdentityKeyPair>> ring() async {
    final cur = _cached ?? await peek();
    final r = await _storedRing();
    if (cur == null) return r;
    return [cur, ...r.where((k) => k.keyId != cur.keyId)];
  }

  Future<List<IdentityKeyPair>> _storedRing() async {
    final c = _ringCache;
    if (c != null) return c;
    try {
      final raw = await _s.read(ringSlot);
      if (raw == null) return const [];
      final out = <IdentityKeyPair>[];
      for (final e in (jsonDecode(raw) as List)) {
        final id = _decode(jsonEncode(e));
        if (id != null && !out.any((k) => k.keyId == id.keyId)) out.add(id);
      }
      ringSnapshot = out;
      return _ringCache = out;
    } catch (_) {
      return const [];
    }
  }

  /// Put [id] at the FRONT of the ring (newest). Older keys are kept.
  Future<void> _remember(IdentityKeyPair id) async {
    try {
      final r = await _storedRing();
      if (r.isNotEmpty && r.first.keyId == id.keyId) return;
      await _writeRing([id, ...r.where((k) => k.keyId != id.keyId)]);
    } catch (_) {}
  }

  Future<bool> _writeRing(List<IdentityKeyPair> keys) async {
    final capped = keys.length > ringMax ? keys.sublist(0, ringMax) : keys;
    final ok = await _s.write(ringSlot,
        jsonEncode([for (final k in capped) jsonDecode(_encode(k))]));
    _ringCache = ok ? List.unmodifiable(capped) : null;
    ringSnapshot = List.unmodifiable(capped);
    return ok;
  }

  /// e2e-recover: merge keys from a PIN-protected backup. [current] (when
  /// this phone has no identity yet) becomes the identity — the SAME key id
  /// as before the reinstall, so peers see no key change. When a current
  /// key already exists it stays current and the restored keys are only
  /// added to the ring (old chats decrypt again). Returns the ring size.
  Future<int> adoptRing(List<IdentityKeyPair> keys,
      {IdentityKeyPair? current}) async {
    final have = await _storedRing();
    final curRaw = await _s.read(slot);
    final curNow = curRaw == null ? null : _decode(curRaw);
    final head = curNow ?? current ?? _cached;
    final merged = <IdentityKeyPair>[];
    for (final k in [if (head != null) head, ...have, ...keys]) {
      if (!merged.any((m) => m.keyId == k.keyId)) merged.add(k);
    }
    await _writeRing(merged);
    if (curNow == null && head != null) {
      await _s.write(slot, _encode(head));
      _cached = head;
    }
    return merged.length;
  }

  /// TESTS: forget in-memory state (simulates an app restart).
  void resetForTests() {
    _cached = null;
    _ringCache = null;
    _inflight = null;
    rekeyed = false;
    volatile = false;
  }

  static String encodeKey(IdentityKeyPair id) => _encode(id);
  static IdentityKeyPair? decodeKey(String raw) => _decode(raw);

  static String _encode(IdentityKeyPair id) => jsonEncode({
        'priv': base64Encode(id.privateKey),
        'pub': base64Encode(id.publicKey),
        'kid': id.keyId,
      });

  static IdentityKeyPair? _decode(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final priv = base64Decode(j['priv'] as String);
      final pub = base64Decode(j['pub'] as String);
      if (priv.length != 32 || pub.length != 32) return null;
      return IdentityKeyPair(priv, pub, j['kid'] as String);
    } catch (_) {
      return null;
    }
  }
}
