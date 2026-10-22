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
      if (id != null) return _cached = id;
      rekeyed = true; // unreadable -> re-key safely below
    }
    final id = _e2e.generateIdentity();
    volatile = !await _s.write(slot, _encode(id));
    if (volatile) return _cached = id;
    // Another isolate may have stored one meanwhile: the stored one wins.
    final again = await _s.read(slot);
    return _cached = (again == null ? null : _decode(again)) ?? id;
  }

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
