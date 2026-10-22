import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'e2e.dart';

/// The ONE place the on-device E2E identity (X25519 key pair) is loaded,
/// created and stored. Every screen, the key publisher and the background
/// push isolate go through [IdentityVault.instance].
///
/// Why (owner bug 22 Oct, OPPO Reno 12 F / ColorOS): flutter_secure_storage
/// (Android Keystore) can throw or hang on some ColorOS / MIUI builds. Each
/// screen used to read the slot itself and, on failure, either kept a
/// throw-away in-memory key that was never published, or kept NO identity —
/// so tapping a chat did nothing and the key was never sent, leaving the
/// peer's messages on the clock forever.
///
/// Rules:
///  * [get] never returns null and never throws: secure storage (with a
///    timeout + one retry) → encrypted app-private fallback file → a new
///    identity (stored in both places when possible, else kept for the
///    session so chats still open and the key still publishes).
///  * The fallback file lives in the app's `no_backup` directory (excluded
///    from Android auto-backup) and is sealed with ChaCha20-Poly1305 under a
///    random wrap key kept next to it. Honest limit: this protects against
///    casual file access and cloud backups, not against a rooted device.
///  * The identity is mirrored to the fallback so a Keystore that works today
///    and fails tomorrow never swaps the user's key.
///  * [lastError] records the failure TYPE only (never key material) for the
///    non-fatal error reporter.
class IdentityVault {
  IdentityVault({IdentitySlot? secure, IdentitySlot? fallback, E2E? e2e})
      : _secure = secure ?? const SecureSlot(),
        _fallback = fallback ?? FileSlot(),
        _e2e = e2e ?? SoftwareE2E();

  static IdentityVault instance = IdentityVault();

  final IdentitySlot _secure;
  final IdentitySlot _fallback;
  final E2E _e2e;

  IdentityKeyPair? _cached;
  Future<IdentityKeyPair>? _inflight;

  /// Runtime type of the last storage failure ('' when none). No key data.
  String lastError = '';

  /// True while the identity is only in memory (both stores failed).
  bool get volatile => _volatile;
  bool _volatile = false;

  static const _timeout = Duration(seconds: 4);

  /// The identity, created and stored on first use. Concurrent callers share
  /// one load so two screens can never create two different keys.
  Future<IdentityKeyPair> get() {
    final c = _cached;
    if (c != null) return Future.value(c);
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  /// The stored identity without creating one (background isolates).
  Future<IdentityKeyPair?> peek() async {
    final c = _cached;
    if (c != null) return c;
    final s = await _read(_secure);
    if (s.value != null) return _cached = s.value;
    final f = await _read(_fallback);
    if (f.value != null) return _cached = f.value;
    return null;
  }

  Future<IdentityKeyPair> _load() async {
    var s = await _read(_secure);
    if (s.failed) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      s = await _read(_secure);
    }
    if (s.value != null) {
      unawaited(_write(_fallback, s.value!)); // mirror (see class doc)
      return _cached = s.value!;
    }
    final f = await _read(_fallback);
    if (f.value != null) {
      if (!s.failed) unawaited(_write(_secure, f.value!));
      return _cached = f.value!;
    }
    final id = _e2e.generateIdentity();
    final inSecure = !s.failed && await _write(_secure, id);
    final inFile = await _write(_fallback, id);
    _volatile = !inSecure && !inFile;
    // Re-read so an identity another isolate stored meanwhile wins.
    final again = inSecure ? (await _read(_secure)).value : null;
    return _cached = again ?? id;
  }

  Future<_Read> _read(IdentitySlot slot) async {
    try {
      final raw = await slot.read().timeout(_timeout);
      if (raw == null || raw.isEmpty) return const _Read(null, false);
      return _Read(_decode(raw), false);
    } catch (e) {
      lastError = '${slot.name}:${e.runtimeType}';
      return const _Read(null, true);
    }
  }

  Future<bool> _write(IdentitySlot slot, IdentityKeyPair id) async {
    try {
      await slot.write(_encode(id)).timeout(_timeout);
      return true;
    } catch (e) {
      lastError = '${slot.name}:${e.runtimeType}';
      return false;
    }
  }

  static String _encode(IdentityKeyPair id) => jsonEncode({
        'priv': base64Encode(id.privateKey),
        'pub': base64Encode(id.publicKey),
        'kid': id.keyId,
      });

  static IdentityKeyPair _decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return IdentityKeyPair(base64Decode(j['priv'] as String),
        base64Decode(j['pub'] as String), j['kid'] as String);
  }
}

class _Read {
  final IdentityKeyPair? value;
  final bool failed;
  const _Read(this.value, this.failed);
}

/// One storage location for the serialized identity.
abstract class IdentitySlot {
  String get name;
  Future<String?> read();
  Future<void> write(String value);
}

/// Android Keystore-backed secure storage (the original slot).
class SecureSlot implements IdentitySlot {
  const SecureSlot();
  static const slotKey = 'circle_identity_v1';
  static const _s = FlutterSecureStorage();

  @override
  String get name => 'secure';

  @override
  Future<String?> read() => _s.read(key: slotKey);

  @override
  Future<void> write(String value) => _s.write(key: slotKey, value: value);
}

/// Encrypted app-private file in `<data>/no_backup/assisto_e2e/`.
class FileSlot implements IdentitySlot {
  FileSlot({Future<Directory> Function()? dir}) : _dirFn = dir ?? _defaultDir;

  final Future<Directory> Function() _dirFn;

  @override
  String get name => 'file';

  static Future<Directory> _defaultDir() async {
    final support = await getApplicationSupportDirectory();
    // <data>/files -> <data>/no_backup (Context.getNoBackupFilesDir()).
    return Directory('${support.parent.path}/no_backup/assisto_e2e');
  }

  Future<Uint8List> _wrapKey(Directory d) async {
    final f = File('${d.path}/wk.bin');
    if (await f.exists()) {
      final b = await f.readAsBytes();
      if (b.length == 32) return b;
    }
    final rng = Random.secure();
    final k = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    await f.writeAsBytes(k, flush: true);
    return k;
  }

  @override
  Future<String?> read() async {
    final d = await _dirFn();
    final f = File('${d.path}/id_v1.bin');
    if (!await d.exists() || !await f.exists()) return null;
    final blob = await f.readAsBytes();
    if (blob.length < 12 + 16) return null;
    final key = await _wrapKey(d);
    final plain = ChaCha20Poly1305.decrypt(
        key, blob.sublist(0, 12), blob.sublist(12),
        aad: utf8.encode('assisto-id-v1'));
    if (plain == null) throw const FormatException('fallback tag mismatch');
    return utf8.decode(plain);
  }

  @override
  Future<void> write(String value) async {
    final d = await _dirFn();
    await d.create(recursive: true);
    final key = await _wrapKey(d);
    final rng = Random.secure();
    final nonce =
        Uint8List.fromList(List.generate(12, (_) => rng.nextInt(256)));
    final ct = ChaCha20Poly1305.encrypt(
        key, nonce, Uint8List.fromList(utf8.encode(value)),
        aad: utf8.encode('assisto-id-v1'));
    final tmp = File('${d.path}/id_v1.tmp');
    await tmp.writeAsBytes([...nonce, ...ct], flush: true);
    await tmp.rename('${d.path}/id_v1.bin');
  }
}
