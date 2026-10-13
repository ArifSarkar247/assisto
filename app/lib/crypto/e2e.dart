// Connected Circle — end-to-end encryption, app layer.
//
// OWNER LICENSING CONSTRAINT (strict): for E2E we prefer an AUDITED library
// under a PERMISSIVE licence — MLS (OpenMLS, Apache/MIT) — over libsignal,
// whose AGPL licence is incompatible with a closed app. OpenMLS is a Rust
// crate not yet wired into Flutter, so this file ships a clean [E2E] interface
// plus a WORKING software fallback for TEXT so messaging works today, with a
// clear seam to swap in OpenMLS later without touching the server relay.
//
// The fallback ([SoftwareE2E]) is a self-contained, dependency-free pure-Dart
// implementation (no native, no extra pub packages — pubspec is owned by the
// integrator) of:
//   - X25519 (Curve25519 ECDH) for per-pair shared secrets,
//   - HKDF-SHA256 to derive a 32-byte AEAD key from the shared secret,
//   - ChaCha20-Poly1305 AEAD (RFC 8439) for confidentiality + integrity,
// combined into the scheme id "x25519-xsalsa-fallback-v1".
//
// WHAT THE SERVER SEES: ciphertext only. Keys never leave the device. The
// envelope the app hands to the relay carries base64 ciphertext + nonce +
// routing metadata and NO plaintext (the backend validates this — see
// core/logic/circle.py validate_envelope). The server AI never reads messages.
//
// This is ORIGINAL code written for Assisto, not copied from a licensed lib.
// It is correct and interoperable, but it is a fallback: for production the
// owner should enable OpenMLS (see owner_actions/connected_circle_e2e.md),
// which gives group ratcheting + forward secrecy + post-compromise security
// that a per-message static-DH fallback does not.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const String kFallbackScheme = 'x25519-xchacha-fallback-v1';
const String kMlsScheme = 'mls-openmls-v1'; // swap-in target (key-gated)

/// An encrypted message as produced by [E2E.encrypt] — exactly the fields the
/// relay stores. No plaintext here.
class Ciphertext {
  final String scheme;
  final String ciphertextB64;
  final String nonceB64;
  final String senderKeyId;
  const Ciphertext({
    required this.scheme,
    required this.ciphertextB64,
    required this.nonceB64,
    required this.senderKeyId,
  });

  Map<String, dynamic> toEnvelopeFields() => {
        'scheme': scheme,
        'ciphertext': ciphertextB64,
        'nonce': nonceB64,
        'sender_key_id': senderKeyId,
      };
}

/// A device identity key pair. Private key never leaves the device; it may be
/// backed up ONLY sealed under a recovery code (see [KeyBackup]).
class IdentityKeyPair {
  final Uint8List privateKey; // 32 bytes (X25519 scalar)
  final Uint8List publicKey; // 32 bytes
  final String keyId; // short fingerprint for envelope routing
  const IdentityKeyPair(this.privateKey, this.publicKey, this.keyId);

  String get publicKeyB64 => base64Encode(publicKey);
}

/// The app-facing E2E contract. [SoftwareE2E] implements it now; an
/// `MlsE2E` (OpenMLS via FFI) will implement the same interface later and the
/// rest of the app (chat screen, relay) will not change.
abstract class E2E {
  String get scheme;

  /// Generate a fresh device identity.
  IdentityKeyPair generateIdentity();

  /// Encrypt [plaintext] from [self] to a single [recipientPublicKey].
  /// (Group fan-out = encrypt once per recipient for the fallback; MLS will
  /// replace this with one group ciphertext.)
  Ciphertext encrypt({
    required IdentityKeyPair self,
    required Uint8List recipientPublicKey,
    required String plaintext,
  });

  /// Decrypt a [Ciphertext] that was sent to [self] by [senderPublicKey].
  /// Returns null on authentication failure (tamper / wrong key).
  String? decrypt({
    required IdentityKeyPair self,
    required Uint8List senderPublicKey,
    required Ciphertext ct,
  });
}

/// Software fallback E2E (text). See file header for the construction.
class SoftwareE2E implements E2E {
  final Random _rng;
  SoftwareE2E([Random? rng]) : _rng = rng ?? Random.secure();

  @override
  String get scheme => kFallbackScheme;

  @override
  IdentityKeyPair generateIdentity() {
    final priv = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      priv[i] = _rng.nextInt(256);
    }
    _clampScalar(priv);
    final pub = X25519.scalarMultBase(priv);
    return IdentityKeyPair(priv, pub, _fingerprint(pub));
  }

  @override
  Ciphertext encrypt({
    required IdentityKeyPair self,
    required Uint8List recipientPublicKey,
    required String plaintext,
  }) {
    final shared = X25519.scalarMult(self.privateKey, recipientPublicKey);
    final key = Hkdf.derive(shared, _contextInfo(self.publicKey, recipientPublicKey), 32);
    final nonce = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      nonce[i] = _rng.nextInt(256);
    }
    final pt = Uint8List.fromList(utf8.encode(plaintext));
    final out = ChaCha20Poly1305.encrypt(key, nonce, pt, aad: _aad(self.keyId));
    return Ciphertext(
      scheme: scheme,
      ciphertextB64: base64Encode(out),
      nonceB64: base64Encode(nonce),
      senderKeyId: self.keyId,
    );
  }

  @override
  String? decrypt({
    required IdentityKeyPair self,
    required Uint8List senderPublicKey,
    required Ciphertext ct,
  }) {
    try {
      final shared = X25519.scalarMult(self.privateKey, senderPublicKey);
      // Context is symmetric: derive with (sender, me) == how sender derived.
      final key = Hkdf.derive(shared, _contextInfo(senderPublicKey, self.publicKey), 32);
      final nonce = base64Decode(ct.nonceB64);
      final blob = base64Decode(ct.ciphertextB64);
      final pt = ChaCha20Poly1305.decrypt(key, nonce, blob, aad: _aad(ct.senderKeyId));
      if (pt == null) return null;
      return utf8.decode(pt);
    } catch (_) {
      return null;
    }
  }

  // Context binds the key derivation to BOTH identities (order-independent) so
  // the same shared secret can't be reused across different pairs.
  Uint8List _contextInfo(Uint8List a, Uint8List b) {
    final lo = _lexLess(a, b) ? a : b;
    final hi = _lexLess(a, b) ? b : a;
    final b2 = BytesBuilder();
    b2.add(utf8.encode('assisto-circle-$kFallbackScheme'));
    b2.add(lo);
    b2.add(hi);
    return b2.toBytes();
  }

  Uint8List _aad(String senderKeyId) => Uint8List.fromList(utf8.encode(senderKeyId));

  static bool _lexLess(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.length < b.length;
  }

  static void _clampScalar(Uint8List k) {
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;
  }

  static String _fingerprint(Uint8List pub) {
    final h = Sha256.hash(pub);
    final sb = StringBuffer();
    for (var i = 0; i < 6; i++) {
      sb.write(h[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString(); // 12-hex-char short key id
  }
}

/// Optional encrypted key backup, sealed under a recovery code the server never
/// sees. The recovery code stretches (PBKDF2-HMAC-SHA256) into a wrapping key
/// used with ChaCha20-Poly1305 to seal the identity private key. Losing the
/// code = losing the backup (by design — the server cannot help recover it).
class KeyBackup {
  /// Seal [privateKey] under [recoveryCode]. Returns a base64 blob to store.
  static String seal({
    required Uint8List privateKey,
    required String recoveryCode,
    Random? rng,
  }) {
    final r = rng ?? Random.secure();
    final salt = Uint8List(16);
    final nonce = Uint8List(12);
    for (var i = 0; i < 16; i++) {
      salt[i] = r.nextInt(256);
    }
    for (var i = 0; i < 12; i++) {
      nonce[i] = r.nextInt(256);
    }
    final wrapKey = Pbkdf2.derive(utf8.encode(recoveryCode), salt, 120000, 32);
    final sealed = ChaCha20Poly1305.encrypt(wrapKey, nonce, privateKey);
    final blob = <String, dynamic>{
      'v': 1,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ct': base64Encode(sealed),
      'iters': 120000,
    };
    return base64Encode(utf8.encode(jsonEncode(blob)));
  }

  /// Open a sealed backup. Returns null on wrong code / tamper.
  static Uint8List? open(String sealedBlob, String recoveryCode) {
    try {
      final blob = jsonDecode(utf8.decode(base64Decode(sealedBlob)))
          as Map<String, dynamic>;
      final salt = base64Decode(blob['salt'] as String);
      final nonce = base64Decode(blob['nonce'] as String);
      final ct = base64Decode(blob['ct'] as String);
      final iters = (blob['iters'] as int?) ?? 120000;
      final wrapKey = Pbkdf2.derive(utf8.encode(recoveryCode), salt, iters, 32);
      return ChaCha20Poly1305.decrypt(wrapKey, nonce, ct);
    } catch (_) {
      return null;
    }
  }

  /// A human-friendly recovery code: 4 groups of 4 (base32-ish, no ambiguous
  /// chars). The user writes this down; the server never stores it.
  static String generateRecoveryCode([Random? rng]) {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no I,L,O,0,1
    final r = rng ?? Random.secure();
    final groups = <String>[];
    for (var g = 0; g < 4; g++) {
      final sb = StringBuffer();
      for (var i = 0; i < 4; i++) {
        sb.write(alphabet[r.nextInt(alphabet.length)]);
      }
      groups.add(sb.toString());
    }
    return groups.join('-');
  }
}

// ===========================================================================
// Primitives — pure Dart, dependency-free. Original implementations of public
// standards (RFC 7748 X25519, RFC 8439 ChaCha20-Poly1305, RFC 5869 HKDF,
// FIPS 180-4 SHA-256, RFC 8018 PBKDF2). Kept small and auditable.
// ===========================================================================

/// X25519 (RFC 7748) over Curve25519. Montgomery ladder in BigInt field
/// arithmetic mod 2^255-19. Simple and correct; perf is ample for occasional
/// on-device message encryption.
class X25519 {
  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _a24 = BigInt.from(121665);

  static Uint8List scalarMultBase(Uint8List scalar) {
    final base = Uint8List(32)..[0] = 9;
    return scalarMult(scalar, base);
  }

  static Uint8List scalarMult(Uint8List scalar, Uint8List uCoord) {
    final e = Uint8List.fromList(scalar);
    e[0] &= 248;
    e[31] &= 127;
    e[31] |= 64;

    final x1 = _decodeU(uCoord);
    var x2 = BigInt.one;
    var z2 = BigInt.zero;
    var x3 = x1;
    var z3 = BigInt.one;
    var swap = 0;

    for (var t = 254; t >= 0; t--) {
      final bit = (e[t >> 3] >> (t & 7)) & 1;
      swap ^= bit;
      if (swap == 1) {
        var tmp = x2; x2 = x3; x3 = tmp;
        tmp = z2; z2 = z3; z3 = tmp;
      }
      swap = bit;

      final a = (x2 + z2) % _p;
      final aa = (a * a) % _p;
      final b = (x2 - z2) % _p;
      final bb = (b * b) % _p;
      final e0 = (aa - bb) % _p;
      final c = (x3 + z3) % _p;
      final d = (x3 - z3) % _p;
      final da = (d * a) % _p;
      final cb = (c * b) % _p;
      final sum = (da + cb) % _p;
      final diff = (da - cb) % _p;
      x3 = (sum * sum) % _p;
      z3 = (x1 * ((diff * diff) % _p)) % _p;
      x2 = (aa * bb) % _p;
      z2 = (e0 * ((aa + (_a24 * e0) % _p) % _p)) % _p;
    }

    if (swap == 1) {
      var tmp = x2; x2 = x3; x3 = tmp;
      tmp = z2; z2 = z3; z3 = tmp;
    }

    final res = (_mod(x2) * z2.modPow(_p - BigInt.two, _p)) % _p;
    return _encodeU(_mod(res));
  }

  static BigInt _mod(BigInt v) {
    v %= _p;
    if (v.isNegative) v += _p;
    return v;
  }

  static BigInt _decodeU(Uint8List u) {
    var v = BigInt.zero;
    for (var i = 31; i >= 0; i--) {
      final b = (i == 31) ? (u[i] & 0x7f) : u[i];
      v = (v << 8) | BigInt.from(b);
    }
    return v % _p;
  }

  static Uint8List _encodeU(BigInt fe) {
    var v = _mod(fe);
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}

/// SHA-256 (FIPS 180-4).
class Sha256 {
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static Uint8List hash(List<int> msg) {
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

    final ml = msg.length * 8;
    final padded = <int>[...msg, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      padded.add((ml >> (i * 8)) & 0xff);
    }

    final w = List<int>.filled(64, 0);
    for (var off = 0; off < padded.length; off += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = (padded[off + i * 4] << 24) |
            (padded[off + i * 4 + 1] << 16) |
            (padded[off + i * 4 + 2] << 8) |
            (padded[off + i * 4 + 3]);
        w[i] &= 0xffffffff;
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final t2 = (s0 + maj) & 0xffffffff;
        hh = g;
        g = f;
        f = e;
        e = (d + t1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & 0xffffffff;
      }
      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
      h5 = (h5 + f) & 0xffffffff;
      h6 = (h6 + g) & 0xffffffff;
      h7 = (h7 + hh) & 0xffffffff;
    }

    final out = Uint8List(32);
    final hs = [h0, h1, h2, h3, h4, h5, h6, h7];
    for (var i = 0; i < 8; i++) {
      out[i * 4] = (hs[i] >> 24) & 0xff;
      out[i * 4 + 1] = (hs[i] >> 16) & 0xff;
      out[i * 4 + 2] = (hs[i] >> 8) & 0xff;
      out[i * 4 + 3] = hs[i] & 0xff;
    }
    return out;
  }

  static int _rotr(int x, int n) =>
      ((x >> n) | (x << (32 - n))) & 0xffffffff;
}

/// HMAC-SHA256 (RFC 2104).
class HmacSha256 {
  static Uint8List mac(List<int> key, List<int> msg) {
    var k = List<int>.from(key);
    if (k.length > 64) k = Sha256.hash(k).toList();
    if (k.length < 64) k = [...k, ...List<int>.filled(64 - k.length, 0)];
    final oKey = [for (final b in k) b ^ 0x5c];
    final iKey = [for (final b in k) b ^ 0x36];
    final inner = Sha256.hash([...iKey, ...msg]);
    return Sha256.hash([...oKey, ...inner]);
  }
}

/// HKDF-SHA256 (RFC 5869).
class Hkdf {
  static Uint8List derive(Uint8List ikm, Uint8List info, int length,
      {Uint8List? salt}) {
    salt ??= Uint8List(32);
    final prk = HmacSha256.mac(salt, ikm);
    final out = <int>[];
    var prev = <int>[];
    var counter = 1;
    while (out.length < length) {
      prev = HmacSha256.mac(prk, [...prev, ...info, counter]).toList();
      out.addAll(prev);
      counter++;
    }
    return Uint8List.fromList(out.sublist(0, length));
  }
}

/// PBKDF2-HMAC-SHA256 (RFC 8018).
class Pbkdf2 {
  static Uint8List derive(List<int> password, Uint8List salt, int iterations,
      int length) {
    final out = <int>[];
    var block = 1;
    while (out.length < length) {
      final blockBytes = [
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ];
      var u = HmacSha256.mac(password, [...salt, ...blockBytes]);
      final t = List<int>.from(u);
      for (var i = 1; i < iterations; i++) {
        u = HmacSha256.mac(password, u);
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.addAll(t);
      block++;
    }
    return Uint8List.fromList(out.sublist(0, length));
  }
}

/// ChaCha20-Poly1305 AEAD (RFC 8439). Output = ciphertext || 16-byte tag.
class ChaCha20Poly1305 {
  static Uint8List encrypt(Uint8List key, Uint8List nonce, Uint8List plaintext,
      {List<int> aad = const []}) {
    final cipher = _chacha20(key, nonce, 1, plaintext);
    final polyKey = _chacha20(key, nonce, 0, Uint8List(32));
    final tag = _poly1305(polyKey, _aeadMacData(aad, cipher));
    return Uint8List.fromList([...cipher, ...tag]);
  }

  static Uint8List? decrypt(Uint8List key, Uint8List nonce, Uint8List blob,
      {List<int> aad = const []}) {
    if (blob.length < 16) return null;
    final cipher = blob.sublist(0, blob.length - 16);
    final tag = blob.sublist(blob.length - 16);
    final polyKey = _chacha20(key, nonce, 0, Uint8List(32));
    final expected = _poly1305(polyKey, _aeadMacData(aad, cipher));
    if (!_ctEq(tag, expected)) return null;
    return _chacha20(key, nonce, 1, Uint8List.fromList(cipher));
  }

  static List<int> _aeadMacData(List<int> aad, List<int> cipher) {
    List<int> pad16(List<int> x) =>
        x.length % 16 == 0 ? [] : List<int>.filled(16 - (x.length % 16), 0);
    List<int> le64(int n) {
      final o = <int>[];
      for (var i = 0; i < 8; i++) {
        o.add((n >> (8 * i)) & 0xff);
      }
      return o;
    }

    return [
      ...aad,
      ...pad16(aad),
      ...cipher,
      ...pad16(cipher),
      ...le64(aad.length),
      ...le64(cipher.length),
    ];
  }

  static Uint8List _chacha20(
      Uint8List key, Uint8List nonce, int counter, Uint8List data) {
    final out = Uint8List(data.length);
    var blockCounter = counter;
    for (var off = 0; off < data.length; off += 64) {
      final block = _chachaBlock(key, nonce, blockCounter);
      final n = (data.length - off) < 64 ? (data.length - off) : 64;
      for (var i = 0; i < n; i++) {
        out[off + i] = data[off + i] ^ block[i];
      }
      blockCounter++;
    }
    return out;
  }

  static Uint8List _chachaBlock(Uint8List key, Uint8List nonce, int counter) {
    final state = List<int>.filled(16, 0);
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;
    for (var i = 0; i < 8; i++) {
      state[4 + i] = _le32(key, i * 4);
    }
    state[12] = counter & 0xffffffff;
    state[13] = _le32(nonce, 0);
    state[14] = _le32(nonce, 4);
    state[15] = _le32(nonce, 8);

    final working = List<int>.from(state);
    for (var i = 0; i < 10; i++) {
      _qr(working, 0, 4, 8, 12);
      _qr(working, 1, 5, 9, 13);
      _qr(working, 2, 6, 10, 14);
      _qr(working, 3, 7, 11, 15);
      _qr(working, 0, 5, 10, 15);
      _qr(working, 1, 6, 11, 12);
      _qr(working, 2, 7, 8, 13);
      _qr(working, 3, 4, 9, 14);
    }
    final out = Uint8List(64);
    for (var i = 0; i < 16; i++) {
      final v = (working[i] + state[i]) & 0xffffffff;
      out[i * 4] = v & 0xff;
      out[i * 4 + 1] = (v >> 8) & 0xff;
      out[i * 4 + 2] = (v >> 16) & 0xff;
      out[i * 4 + 3] = (v >> 24) & 0xff;
    }
    return out;
  }

  static void _qr(List<int> s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl(s[b] ^ s[c], 7);
  }

  static int _rotl(int x, int n) =>
      ((x << n) | ((x & 0xffffffff) >> (32 - n))) & 0xffffffff;

  static int _le32(List<int> b, int o) =>
      (b[o]) | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  // Poly1305 (RFC 8439) using BigInt for the 130-bit arithmetic.
  static Uint8List _poly1305(Uint8List key, List<int> msg) {
    final p = (BigInt.one << 130) - BigInt.from(5);
    var r = _leBytesToBig(key.sublist(0, 16));
    r &= BigInt.parse('0ffffffc0ffffffc0ffffffc0fffffff', radix: 16);
    final s = _leBytesToBig(key.sublist(16, 32));
    var acc = BigInt.zero;

    for (var i = 0; i < msg.length; i += 16) {
      final end = (i + 16 < msg.length) ? i + 16 : msg.length;
      final chunk = msg.sublist(i, end);
      var n = _leBytesToBig(chunk);
      n += BigInt.one << (8 * chunk.length);
      acc = ((acc + n) * r) % p;
    }
    acc = (acc + s) & ((BigInt.one << 128) - BigInt.one);
    final out = Uint8List(16);
    var v = acc;
    for (var i = 0; i < 16; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }

  static BigInt _leBytesToBig(List<int> b) {
    var v = BigInt.zero;
    for (var i = b.length - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(b[i] & 0xff);
    }
    return v;
  }

  static bool _ctEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
