import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../security/secret_store.dart';
import 'e2e.dart';
import 'identity_vault.dart';
import 'scrypt.dart';

/// e2e-recover item 3 — WhatsApp-style ENCRYPTED KEY-RING BACKUP.
///
/// The whole key ring ([IdentityVault.ring]) is sealed ON THE PHONE:
///   master   = scrypt(PIN, salt, N=2^15, r=8, p=1)  (32 MiB, ~0.4 s on the
///              dev server, ~1-2 s on a mid-range phone; see docs)
///   enc_key  = HKDF(master, "assisto-e2e-keyring-enc-v1")  -> NEVER sent
///   auth_key = HKDF(master, "assisto-e2e-keyring-auth-v1") -> the proof
///   blob     = ChaCha20-Poly1305(enc_key, ring JSON)
/// The server stores salt + params + sealed blob + a HASH of auth_key and
/// releases the blob only after a correct proof, counting wrong attempts
/// (5/hour, 24 h lock after 10 in a row). It never sees the PIN through
/// this path, the enc key or a private key.
///
/// HONEST LIMIT: a short numeric PIN can be brute-forced OFFLINE by someone
/// holding a copy of the server database; scrypt only slows that down.
class KdfParams {
  final int n, r, p;
  const KdfParams(this.n, this.r, this.p);
  static const standard = KdfParams(1 << 15, 8, 1);
  Map<String, dynamic> toJson() => {'alg': 'scrypt', 'n': n, 'r': r, 'p': p};
  static KdfParams? fromJson(Object? j) {
    if (j is! Map || j['alg'] != 'scrypt') return null;
    final n = (j['n'] as num?)?.toInt(), r = (j['r'] as num?)?.toInt();
    final p = (j['p'] as num?)?.toInt();
    if (n == null || r == null || p == null) return null;
    if (n < 2 || n > (1 << 20) || r < 1 || r > 16 || p < 1 || p > 4) return null;
    return KdfParams(n, r, p);
  }
}

/// enc + auth keys derived from one PIN + salt.
class BackupSecret {
  final Uint8List salt, enc, auth;
  final KdfParams kdf;
  const BackupSecret(this.salt, this.kdf, this.enc, this.auth);

  String toStore() => jsonEncode({
        'salt': base64Encode(salt),
        'kdf': kdf.toJson(),
        'enc': base64Encode(enc),
        'auth': base64Encode(auth),
      });

  static BackupSecret? fromStore(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final kdf = KdfParams.fromJson(j['kdf']);
      if (kdf == null) return null;
      return BackupSecret(base64Decode(j['salt'] as String), kdf,
          base64Decode(j['enc'] as String), base64Decode(j['auth'] as String));
    } catch (_) {
      return null;
    }
  }
}

/// scrypt + HKDF, pure function (runs in a background isolate in the app).
List<Uint8List> deriveBackupKeys(
    String pin, Uint8List salt, int n, int r, int p) {
  final master =
      Scrypt.derive(utf8.encode(pin), salt, n: n, r: r, p: p, dkLen: 32);
  final enc = Hkdf.derive(
      master, Uint8List.fromList(utf8.encode('assisto-e2e-keyring-enc-v1')), 32);
  final auth = Hkdf.derive(master,
      Uint8List.fromList(utf8.encode('assisto-e2e-keyring-auth-v1')), 32);
  return [enc, auth];
}

enum RestoreOutcome { restored, wrongPin, locked, noBackup, failed }

class RestoreResult {
  final RestoreOutcome outcome;
  final int attemptsLeft;
  final DateTime? lockedUntil;
  final int keys;
  const RestoreResult(this.outcome,
      {this.attemptsLeft = 0, this.lockedUntil, this.keys = 0});
}

typedef BackupGet = Future<Map<String, dynamic>> Function(String path);
typedef BackupPost = Future<Map<String, dynamic>> Function(
    String path, Map<String, dynamic> body);

/// Thrown by a [BackupPost] for a non-2xx answer whose JSON body matters
/// (403 wrong PIN / 429 locked). Tests' fake API throws it too.
class BackupHttpError implements Exception {
  final int status;
  final Map<String, dynamic> body;
  BackupHttpError(this.status, this.body);
}

class KeyBackupService {
  KeyBackupService({
    IdentityVault? vault,
    SecretStore? store,
    this.params = KdfParams.standard,
    Future<List<Uint8List>> Function(String, Uint8List, KdfParams)? derive,
    Random? rng,
  })  : _vault = vault,
        _store = store,
        _derive = derive ?? _isolateDerive,
        _rng = rng ?? Random.secure();

  static KeyBackupService instance = KeyBackupService();

  static const secretSlot = 'e2_backup_secret_v1';
  static const _aad = 'assisto-e2e-keyring-v1';

  final IdentityVault? _vault;
  IdentityVault get vault => _vault ?? IdentityVault.instance;
  final SecretStore? _store;
  SecretStore get _s => _store ?? SecretStore.instance;
  final KdfParams params;
  final Future<List<Uint8List>> Function(String, Uint8List, KdfParams) _derive;
  final Random _rng;

  /// Wired by KeyWiring (the app's ApiClient); null = not signed in.
  BackupGet? get;
  BackupPost? post;

  /// Shows the restore screen; completes when the user restored or skipped.
  Future<void> Function(Map<String, dynamic> meta)? presenter;

  String lastEvent = '';

  static Future<List<Uint8List>> _isolateDerive(
      String pin, Uint8List salt, KdfParams k) async {
    try {
      return await Isolate.run(
          () => deriveBackupKeys(pin, salt, k.n, k.r, k.p));
    } catch (_) {
      return deriveBackupKeys(pin, salt, k.n, k.r, k.p);
    }
  }

  Uint8List _random(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  Future<BackupSecret> secretFor(String pin, Uint8List salt, KdfParams k) async {
    final ks = await _derive(pin, salt, k);
    return BackupSecret(salt, k, ks[0], ks[1]);
  }

  // ------------------------------------------------------------- sealing
  String _sealRing(List<IdentityKeyPair> ring, Uint8List enc, Uint8List nonce) {
    final body = jsonEncode({
      'v': 1,
      'current': ring.isEmpty ? '' : ring.first.keyId,
      'keys': [for (final k in ring) jsonDecode(IdentityVault.encodeKey(k))],
    });
    return base64Encode(ChaCha20Poly1305.encrypt(
        enc, nonce, Uint8List.fromList(utf8.encode(body)),
        aad: utf8.encode(_aad)));
  }

  /// (current, keys) of a sealed ring, or null on a wrong key / tamper.
  (IdentityKeyPair?, List<IdentityKeyPair>)? openRing(
      String blobB64, String nonceB64, Uint8List enc) {
    try {
      final pt = ChaCha20Poly1305.decrypt(
          enc, base64Decode(nonceB64), base64Decode(blobB64),
          aad: utf8.encode(_aad));
      if (pt == null) return null;
      final j = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      final keys = <IdentityKeyPair>[];
      for (final e in (j['keys'] as List? ?? const [])) {
        final k = IdentityVault.decodeKey(jsonEncode(e));
        if (k != null) keys.add(k);
      }
      final cur = keys.where((k) => k.keyId == '${j['current'] ?? ''}');
      return (cur.isEmpty ? (keys.isEmpty ? null : keys.first) : cur.first, keys);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- upload
  Future<bool> _upload(BackupSecret s, {Uint8List? prevAuth}) async {
    final p = post;
    if (p == null) return false;
    final ring = await vault.ring();
    if (ring.isEmpty) return false;
    final nonce = _random(12);
    await p('/e2/backup', {
      'salt': base64Encode(s.salt),
      'kdf': s.kdf.toJson(),
      'auth_key': base64Encode(s.auth),
      'blob': _sealRing(ring, s.enc, nonce),
      'nonce': base64Encode(nonce),
      'key_ids': [for (final k in ring) k.keyId],
      'current_key_id': ring.first.keyId,
      if (prevAuth != null) 'prev_auth': base64Encode(prevAuth),
    }).timeout(const Duration(seconds: 20));
    lastEvent = 'saved ${ring.length}';
    return true;
  }

  /// Silent refresh with the keys cached on this phone after the user last
  /// entered the PIN here (first key / re-key / restore). False when this
  /// phone never had the PIN (nothing is sent). Never throws.
  Future<bool> backupNow() async {
    try {
      final s = BackupSecret.fromStore(await _s.read(secretSlot));
      if (s == null) return false;
      return await _upload(s);
    } catch (_) {
      return false;
    }
  }

  /// The PIN was just set / changed / confirmed. If a backup sealed under
  /// [oldPin] (or this PIN) exists, its keys are merged in first so nothing
  /// is lost; then the ring is sealed under [pin] and uploaded.
  Future<bool> backupWithPin(String pin, {String? oldPin}) async {
    try {
      final g = get;
      if (g == null || post == null) return false;
      final meta = await g('/e2/backup').timeout(const Duration(seconds: 10));
      final slot0 = _slot0(meta);
      var cached = BackupSecret.fromStore(await _s.read(secretSlot));
      bool cachedIsLive() =>
          slot0 != null &&
          cached != null &&
          base64Encode(cached.salt) == '${slot0['salt']}';
      if (slot0 != null && !cachedIsLive()) {
        // Merge what the existing backup holds (e.g. a skipped restore).
        for (final cand in {if (oldPin != null) oldPin, pin}) {
          final r = await restore(cand, meta: meta, adoptOnly: true);
          if (r.outcome == RestoreOutcome.restored) break;
          if (r.outcome == RestoreOutcome.locked) break;
        }
        cached = BackupSecret.fromStore(await _s.read(secretSlot));
      }
      // PIN unchanged + live backup known -> in-place refresh (same salt);
      // otherwise seal under the new PIN, replacing the live backup when we
      // can prove we opened it.
      final live = cachedIsLive() ? cached : null;
      BackupSecret? same;
      if (live != null) {
        final check = await secretFor(pin, live.salt, live.kdf);
        if (_eq(check.auth, live.auth)) same = live;
      }
      final s = same ?? await secretFor(pin, _random(16), params);
      await _s.write(secretSlot, s.toStore());
      return await _upload(s, prevAuth: live?.auth);
    } catch (_) {
      return false;
    }
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  static Map<String, dynamic>? _slot0(Map<String, dynamic> meta) {
    if (meta['exists'] != true) return null;
    final slots = (meta['slots'] as List? ?? const []);
    for (final s in slots) {
      if (s is Map && (s['slot'] as num?)?.toInt() == 0) {
        return s.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// GET e2/backup (never the blob). Null when unreachable.
  Future<Map<String, dynamic>?> meta() async {
    final g = get;
    if (g == null) return null;
    try {
      return await g('/e2/backup').timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  /// Restore the key ring with [pin]. On success the restored current key
  /// becomes this phone's identity when it has none yet (SAME key id: peers
  /// see no change), otherwise the keys join the ring.
  Future<RestoreResult> restore(String pin,
      {Map<String, dynamic>? meta, bool adoptOnly = false}) async {
    try {
      final m = meta ?? await this.meta();
      final p = post;
      if (m == null || p == null) return const RestoreResult(RestoreOutcome.failed);
      if (m['exists'] != true) return const RestoreResult(RestoreOutcome.noBackup);
      final secrets = <int, BackupSecret>{};
      for (final s in (m['slots'] as List? ?? const [])) {
        if (s is! Map) continue;
        final kdf = KdfParams.fromJson(s['kdf']);
        final slot = (s['slot'] as num?)?.toInt();
        if (kdf == null || slot == null) continue;
        try {
          secrets[slot] =
              await secretFor(pin, base64Decode('${s['salt']}'), kdf);
        } catch (_) {}
        if (secrets.length >= 4) break;
      }
      if (secrets.isEmpty) return const RestoreResult(RestoreOutcome.failed);
      Map<String, dynamic> r;
      try {
        r = await p('/e2/backup/open', {
          'proofs': [
            for (final e in secrets.entries)
              {'slot': e.key, 'auth_key': base64Encode(e.value.auth)}
          ],
        }).timeout(const Duration(seconds: 20));
      } on BackupHttpError catch (e) {
        final left = (e.body['attempts_left'] as num?)?.toInt() ?? 0;
        final until = DateTime.tryParse('${e.body['locked_until'] ?? ''}');
        if (e.status == 429 || e.body['locked'] == true) {
          return RestoreResult(RestoreOutcome.locked,
              lockedUntil: until?.toLocal());
        }
        if (e.status == 403) {
          return RestoreResult(RestoreOutcome.wrongPin,
              attemptsLeft: left, lockedUntil: until?.toLocal());
        }
        return const RestoreResult(RestoreOutcome.failed);
      }
      if (r['ok'] != true) return const RestoreResult(RestoreOutcome.failed);
      IdentityKeyPair? current;
      final keys = <IdentityKeyPair>[];
      for (final s in (r['slots'] as List? ?? const [])) {
        if (s is! Map) continue;
        final slot = (s['slot'] as num?)?.toInt();
        final sec = secrets[slot];
        if (sec == null) continue;
        final opened = openRing('${s['blob']}', '${s['nonce']}', sec.enc);
        if (opened == null) continue;
        if (slot == 0 || current == null) current = opened.$1 ?? current;
        keys.addAll(opened.$2);
        if (slot == 0) await _s.write(secretSlot, sec.toStore());
      }
      if (keys.isEmpty) return const RestoreResult(RestoreOutcome.failed);
      final n = await vault.adoptRing(keys, current: adoptOnly ? null : current);
      lastEvent = 'restored ${keys.length}';
      return RestoreResult(RestoreOutcome.restored, keys: n);
    } catch (_) {
      return const RestoreResult(RestoreOutcome.failed);
    }
  }

  // ---------------------------------------------------- new-install gate
  /// [IdentityVault.beforeCreate]: this phone has NO key yet. If a backup
  /// exists, show the restore screen BEFORE a new key is made/published.
  /// Time-boxed: messaging is never blocked for long.
  Future<void> gate() async {
    final show = presenter;
    if (show == null || get == null) return;
    final m = await meta();
    if (m == null || m['exists'] != true) return;
    try {
      await show(m).timeout(const Duration(minutes: 10));
    } catch (_) {}
  }
}
