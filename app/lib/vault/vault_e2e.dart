// p3docs — the vault's END-TO-END layer (owner PART 3, 3 Nov 2026).
//
// The server must never be able to read a sealed document, so every key and
// every seal/unseal happens HERE, on the phone. Backend half and the exact
// shapes it accepts: backend/core/vault_e2e.py.
//
//   DMK        32 random bytes — the document master key.
//   PIN wrap   DMK sealed under PBKDF2(PIN)       -> this phone only
//   bio wrap   DMK sealed under a random device key kept in the Keystore-
//              backed SecretStore; opened after a fingerprint match (honest:
//              app-level gate, not a Keystore auth-bound key) -> phone only
//   recovery   DMK sealed under PBKDF2(16-char code, 120k) -> server (so a
//              NEW phone can recover); the code is shown once, never sent
//   helper     DMK sealed to a trusted My Circle person's X25519 public key
//              -> server; only their phone can open it, and it re-seals the
//              DMK to OUR new public key after they approve (+24 h wait)
//
// Lose the PIN, this phone's fingerprint wrap, the recovery code AND the
// trusted person: the sealed documents are gone for good. Nobody — Assisto
// included — can open them. That is the point; the app says it in plain words
// before the lock is switched on.
//
// Sealed document on the server:
//   file    "AVE1" || ChaCha20-Poly1305 chunks (media_crypto, per-doc key fk)
//   box     "AVB1" || nonce || sealBytes(DMK, json{title,note,details,
//           expiry,fk,fn,mime,name})
// Share link copy: "AVS1" || nonce || sealBytes(K, u32 hlen || header || file)
// with K only in the URL #fragment (web/views_vault_share.py decrypts in the
// browser).
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hc;

import '../crypto/e2e.dart';
import '../messaging/media/media_crypto.dart' show openBytes, randomBytes, sealBytes;
import 'vault_lock.dart' show SecretKv, VaultKv, VaultLock;

class E2ESlots {
  static const on = 'vault_e2e_on';
  static const pinWrap = 'vault_e2e_pinwrap';
  static const devKey = 'vault_e2e_devkey';
  static const bioWrap = 'vault_e2e_biowrap';
  // the same recovery-code wrap the server holds, kept here too so the
  // OFFLINE "forgot PIN -> recovery code" path also re-opens the documents
  static const recLocal = 'vault_e2e_rcwrap';
}

/// A sealed document ready for upload.
class SealedDoc {
  final String box; // base64 of "AVB1"||nonce||sealed json
  final Uint8List? file; // "AVE1"||ciphertext
  const SealedDoc(this.box, this.file);
}

/// A sealed share-link copy.
class ShareSeal {
  final Uint8List blob; // "AVS1"||nonce||ciphertext — what the server gets
  final String fragment; // base64url key — ONLY in the link's #fragment
  const ShareSeal(this.blob, this.fragment);
}

class VaultE2E {
  VaultE2E({VaultKv? kv, this.pinIters = 100000, this.codeIters = 120000, Random? rng})
      : kv = kv ?? const SecretKv(),
        _rng = rng ?? Random.secure();

  /// The app-wide instance (tests build their own with a MemoryKv).
  static VaultE2E instance = VaultE2E();

  final VaultKv kv;
  final int pinIters;
  final int codeIters;
  final Random _rng;

  static final Uint8List fileMagic = Uint8List.fromList('AVE1'.codeUnits);
  static final Uint8List boxMagic = Uint8List.fromList('AVB1'.codeUnits);
  static final Uint8List shareMagic = Uint8List.fromList('AVS1'.codeUnits);
  static const int maxShareBytes = 10 * 1024 * 1024;

  /// The unlocked master key, in memory only while the vault is open.
  Uint8List? _dmk;
  bool get unlocked => _dmk != null;
  Uint8List? get dmkForTests => _dmk;

  /// Forget the key (vault closed / app paused).
  void lock() {
    final k = _dmk;
    if (k != null) k.fillRange(0, k.length, 0);
    _dmk = null;
  }

  Future<bool> isSetUp() async => (await kv.read(E2ESlots.on)) == '1';
  Future<bool> hasBioWrap() async => (await kv.read(E2ESlots.bioWrap)) != null;
  Future<bool> hasPinWrap() async => (await kv.read(E2ESlots.pinWrap)) != null;

  // ------------------------------------------------------------ setup
  /// First switch-on: make the DMK and its PIN wrap (and bio wrap when asked).
  /// Returns the recovery CODE (shown once) and its server WRAP.
  Future<({String code, String recoveryWrap})> setUp(String pin, {bool bio = false}) async {
    final dmk = randomBytes(32, _rng);
    _dmk = dmk;
    await kv.write(E2ESlots.pinWrap, await sealWithSecret(dmk, pin, pinIters, _rng));
    if (bio) await enableBio(true);
    await kv.write(E2ESlots.on, '1');
    return newRecovery();
  }

  /// A fresh recovery code + its wrap (needs the vault unlocked).
  Future<({String code, String recoveryWrap})> newRecovery() async {
    _need();
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final code = List.generate(16, (_) => alphabet[_rng.nextInt(alphabet.length)]).join();
    final wrap = (await wrapForCode(code))!;
    return (code: VaultLock.formatCode(code), recoveryWrap: wrap);
  }

  /// Wrap the open key under an existing recovery [code] (the vault100 code
  /// the user already wrote down). Stores the local copy; returns the wrap
  /// for the server, or null when the vault key is not open.
  Future<String?> wrapForCode(String code) async {
    final dmk = _dmk;
    if (dmk == null) return null;
    final wrap = await sealWithSecret(dmk, VaultLock.normalizeCode(code), codeIters, _rng);
    await kv.write(E2ESlots.recLocal, wrap);
    return wrap;
  }

  /// Offline recovery: the code opens the LOCAL copy of the recovery wrap.
  Future<bool> unlockWithLocalRecovery(String code) async {
    final w = await kv.read(E2ESlots.recLocal);
    if (w == null) return false;
    final k = await openWithSecret(w, VaultLock.normalizeCode(code));
    if (k == null) return false;
    _dmk = k;
    return true;
  }

  /// Adopt a DMK recovered elsewhere (code / trusted person) on THIS phone:
  /// store fresh local wraps under the new PIN.
  Future<void> adopt(Uint8List dmk, String newPin) async {
    _dmk = Uint8List.fromList(dmk);
    await kv.write(E2ESlots.pinWrap, await sealWithSecret(_dmk!, newPin, pinIters, _rng));
    await kv.write(E2ESlots.on, '1');
  }

  // ------------------------------------------------------------ unlock
  Future<bool> unlockWithPin(String pin) async {
    final w = await kv.read(E2ESlots.pinWrap);
    if (w == null) return false;
    final k = await openWithSecret(w, pin);
    if (k == null) return false;
    _dmk = k;
    return true;
  }

  /// Call ONLY after the fingerprint matched (ChatLockAuth.biometric).
  Future<bool> unlockWithBio() async {
    final w = await kv.read(E2ESlots.bioWrap);
    final dk = await kv.read(E2ESlots.devKey);
    if (w == null || dk == null) return false;
    final k = openRaw(w, base64Decode(dk));
    if (k == null) return false;
    _dmk = k;
    return true;
  }

  /// Unlock with the recovery code via the SERVER-held wrap (new phone ok).
  Future<Uint8List?> openRecovery(String wrap, String code) =>
      openWithSecret(wrap, VaultLock.normalizeCode(code));

  /// PIN changed (or set after a reset) while the vault is unlocked.
  Future<bool> rewrapPin(String newPin) async {
    final dmk = _dmk;
    if (dmk == null) return false;
    return kv.write(E2ESlots.pinWrap, await sealWithSecret(dmk, newPin, pinIters, _rng));
  }

  Future<void> enableBio(bool on) async {
    if (!on) {
      await kv.delete(E2ESlots.bioWrap);
      await kv.delete(E2ESlots.devKey);
      return;
    }
    final dmk = _need();
    final dev = randomBytes(32, _rng);
    await kv.write(E2ESlots.devKey, base64Encode(dev));
    await kv.write(E2ESlots.bioWrap, sealRaw(dmk, dev, _rng));
  }

  /// Turn the lock off on THIS phone (server wraps are removed by the caller).
  Future<void> forgetLocal() async {
    lock();
    for (final s in [E2ESlots.on, E2ESlots.pinWrap, E2ESlots.devKey, E2ESlots.bioWrap, E2ESlots.recLocal]) {
      await kv.delete(s);
    }
  }

  Uint8List _need() {
    final k = _dmk;
    if (k == null) throw StateError('vault locked');
    return k;
  }

  // ------------------------------------------------------------ helpers
  /// Seal the DMK to a trusted person's X25519 public key.
  String sealForHelper(Uint8List helperPub, {String kid = ''}) =>
      sealToPublicKey(_need(), helperPub, kid: kid, rng: _rng);

  // ------------------------------------------------------------ documents
  /// Seal metadata (+ optional file) for upload. Runs the file in an isolate.
  Future<SealedDoc> sealDocument(Map<String, dynamic> meta, {Uint8List? file, String? mime, String? name}) async {
    final dmk = _need();
    Uint8List? fileOut;
    final m = Map<String, dynamic>.from(meta);
    final plain = file;
    if (plain != null) {
      final fk = randomBytes(32, _rng), fn = randomBytes(12, _rng);
      final ct = plain.length > 256 * 1024
          ? await Isolate.run(() => sealBytes(fk, fn, plain))
          : sealBytes(fk, fn, plain);
      fileOut = _concat([fileMagic, ct]);
      m['fk'] = base64Encode(fk);
      m['fn'] = base64Encode(fn);
      if (mime != null) m['mime'] = mime;
      if (name != null) m['name'] = name;
    }
    return SealedDoc(sealBox(dmk, m, _rng), fileOut);
  }

  /// The decrypted metadata of a sealed document, or null (locked / tamper).
  Map<String, dynamic>? openDocBox(String box) {
    final dmk = _dmk;
    if (dmk == null) return null;
    return openBox(dmk, box);
  }

  /// Decrypt a sealed file with the key from its opened [meta].
  static Future<Uint8List?> openDocFile(Map<String, dynamic> meta, List<int> sealed) async {
    try {
      final fk = base64Decode('${meta['fk']}');
      final fn = base64Decode('${meta['fn']}');
      final b = Uint8List.fromList(sealed);
      if (b.length < 4 + 16 || !_startsWith(b, fileMagic)) return null;
      final body = Uint8List.sublistView(b, 4);
      return body.length > 256 * 1024
          ? await Isolate.run(() => openBytes(fk, fn, body))
          : openBytes(fk, fn, body);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ share links
  /// Seal a copy for a time-limited link. [title] is shown on the web page
  /// AFTER decryption only.
  static Future<ShareSeal> sealForShare(Uint8List file,
      {required String mime, required String name, String title = '', Random? rng}) async {
    final r = rng ?? Random.secure();
    final key = randomBytes(32, r), nonce = randomBytes(12, r);
    final header = utf8.encode(jsonEncode({'m': mime, 'n': name, 't': title}));
    final hl = ByteData(4)..setUint32(0, header.length, Endian.little);
    final payload = _concat([hl.buffer.asUint8List(), Uint8List.fromList(header), file]);
    final ct = payload.length > 256 * 1024
        ? await Isolate.run(() => sealBytes(key, nonce, payload))
        : sealBytes(key, nonce, payload);
    return ShareSeal(_concat([shareMagic, nonce, ct]),
        base64Url.encode(key).replaceAll('=', ''));
  }

  /// Inverse of [sealForShare] (what the web page does) — used by tests.
  static ({Map<String, dynamic> header, Uint8List file})? openShare(Uint8List blob, String fragment) {
    try {
      if (blob.length < 4 + 12 + 16 || !_startsWith(blob, shareMagic)) return null;
      final pad = '=' * ((4 - fragment.length % 4) % 4);
      final key = base64Url.decode(fragment + pad);
      final p = openBytes(key, Uint8List.sublistView(blob, 4, 16), Uint8List.sublistView(blob, 16));
      if (p == null) return null;
      final hl = ByteData.sublistView(p, 0, 4).getUint32(0, Endian.little);
      final header = jsonDecode(utf8.decode(p.sublist(4, 4 + hl))) as Map<String, dynamic>;
      return (header: header, file: Uint8List.sublistView(p, 4 + hl));
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ primitives
  /// base64(JSON{v,alg:pbkdf2-c20p,salt,iters,nonce,ct}) — the server's shape.
  static Future<String> sealWithSecret(Uint8List dmk, String secret, int iters, [Random? rng]) async {
    final r = rng ?? Random.secure();
    final salt = randomBytes(16, r), nonce = randomBytes(12, r);
    final k = await VaultLock.derive(utf8.encode(secret), salt, iters);
    final ct = ChaCha20Poly1305.encrypt(k, nonce, dmk);
    return base64Encode(utf8.encode(jsonEncode({
      'v': 1, 'alg': 'pbkdf2-c20p', 'salt': base64Encode(salt), 'iters': iters,
      'nonce': base64Encode(nonce), 'ct': base64Encode(ct),
    })));
  }

  static Future<Uint8List?> openWithSecret(String wrap, String secret) async {
    try {
      final j = jsonDecode(utf8.decode(base64Decode(wrap))) as Map<String, dynamic>;
      if (j['alg'] != 'pbkdf2-c20p') return null;
      final k = await VaultLock.derive(
          utf8.encode(secret), base64Decode('${j['salt']}'), (j['iters'] as num).toInt());
      return ChaCha20Poly1305.decrypt(k, base64Decode('${j['nonce']}'), base64Decode('${j['ct']}'));
    } catch (_) {
      return null;
    }
  }

  /// Local-only wrap under a random 32-byte key (bio wrap).
  static String sealRaw(Uint8List dmk, Uint8List key, [Random? rng]) {
    final nonce = randomBytes(12, rng);
    final ct = ChaCha20Poly1305.encrypt(key, nonce, dmk);
    return base64Encode(utf8.encode(jsonEncode(
        {'v': 1, 'alg': 'raw-c20p', 'nonce': base64Encode(nonce), 'ct': base64Encode(ct)})));
  }

  static Uint8List? openRaw(String wrap, Uint8List key) {
    try {
      final j = jsonDecode(utf8.decode(base64Decode(wrap))) as Map<String, dynamic>;
      return ChaCha20Poly1305.decrypt(key, base64Decode('${j['nonce']}'), base64Decode('${j['ct']}'));
    } catch (_) {
      return null;
    }
  }

  static Uint8List _helperInfo(Uint8List epk, Uint8List pub) =>
      _concat([Uint8List.fromList(utf8.encode('assisto-vault-helper-v1')), epk, pub]);

  /// ECIES: ephemeral X25519 + HKDF-SHA256 + ChaCha20-Poly1305.
  static String sealToPublicKey(Uint8List dmk, Uint8List pub, {String kid = '', Random? rng}) {
    final eph = SoftwareE2E(rng).generateIdentity();
    final shared = X25519.scalarMult(eph.privateKey, pub);
    final key = Hkdf.derive(shared, _helperInfo(eph.publicKey, pub), 32);
    final nonce = randomBytes(12, rng);
    final ct = ChaCha20Poly1305.encrypt(key, nonce, dmk);
    return base64Encode(utf8.encode(jsonEncode({
      'v': 1, 'alg': 'x25519-c20p', 'epk': base64Encode(eph.publicKey),
      'nonce': base64Encode(nonce), 'ct': base64Encode(ct), 'kid': kid,
    })));
  }

  static Uint8List? openFromPublicKey(String wrap, IdentityKeyPair me) {
    try {
      final j = jsonDecode(utf8.decode(base64Decode(wrap))) as Map<String, dynamic>;
      if (j['alg'] != 'x25519-c20p') return null;
      final epk = base64Decode('${j['epk']}');
      final shared = X25519.scalarMult(me.privateKey, epk);
      final key = Hkdf.derive(shared, _helperInfo(epk, me.publicKey), 32);
      return ChaCha20Poly1305.decrypt(key, base64Decode('${j['nonce']}'), base64Decode('${j['ct']}'));
    } catch (_) {
      return null;
    }
  }

  static String sealBox(Uint8List dmk, Map<String, dynamic> meta, [Random? rng]) {
    final nonce = randomBytes(12, rng);
    final ct = sealBytes(dmk, nonce, Uint8List.fromList(utf8.encode(jsonEncode(meta))));
    return base64Encode(_concat([boxMagic, nonce, ct]));
  }

  static Map<String, dynamic>? openBox(Uint8List dmk, String box) {
    try {
      final b = base64Decode(box);
      if (b.length < 4 + 12 + 16 || !_startsWith(b, boxMagic)) return null;
      final p = openBytes(dmk, Uint8List.sublistView(b, 4, 16), Uint8List.sublistView(b, 16));
      if (p == null) return null;
      return jsonDecode(utf8.decode(p)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 8-digit match code both people compare on a phone call, so a server
  /// can't swap in its own key: SHA-256(public key) -> "1234 5678".
  static String matchCode(Uint8List pub) {
    final h = hc.sha256.convert(pub).bytes;
    final v = ((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) % 100000000;
    final s = v.toString().padLeft(8, '0');
    return '${s.substring(0, 4)} ${s.substring(4)}';
  }

  static bool _startsWith(Uint8List b, Uint8List p) {
    if (b.length < p.length) return false;
    for (var i = 0; i < p.length; i++) {
      if (b[i] != p[i]) return false;
    }
    return true;
  }

  static Uint8List _concat(List<Uint8List> parts) {
    final bb = BytesBuilder(copy: false);
    for (final p in parts) {
      bb.add(p);
    }
    return bb.toBytes();
  }
}
