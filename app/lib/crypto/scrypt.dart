// scrypt (RFC 7914) — pure Dart, dependency-free. Original implementation of
// the public standard, used to stretch the Security PIN before it protects
// the encrypted E2E key-ring backup (e2e-recover). Verified against the RFC
// 7914 §12 test vectors in test/e2e_recover_crypto_test.dart.
//
// Memory-hard: N * r * 128 bytes of RAM (N=2^14, r=8 -> 16 MiB), so a GPU
// farm gets far less advantage than with PBKDF2 alone.

import 'dart:typed_data';

import 'e2e.dart' show HmacSha256;

class Scrypt {
  /// Derive [dkLen] bytes. [n] must be a power of two > 1.
  static Uint8List derive(List<int> password, List<int> salt,
      {required int n, required int r, required int p, int dkLen = 64}) {
    if (n < 2 || (n & (n - 1)) != 0) {
      throw ArgumentError('scrypt N must be a power of two');
    }
    final blockLen = 128 * r;
    final b = _pbkdf2Once(password, salt, p * blockLen);
    final words = 32 * r;
    final x = Uint32List(words);
    final v = Uint32List(words * n);
    final y = Uint32List(words);
    final bd = ByteData.sublistView(b);
    for (var i = 0; i < p; i++) {
      final off = i * blockLen;
      for (var k = 0; k < words; k++) {
        x[k] = bd.getUint32(off + 4 * k, Endian.little);
      }
      _roMix(x, v, y, n, r);
      for (var k = 0; k < words; k++) {
        bd.setUint32(off + 4 * k, x[k], Endian.little);
      }
    }
    return _pbkdf2Once(password, b, dkLen);
  }

  /// PBKDF2-HMAC-SHA256 with ONE iteration (all scrypt needs).
  static Uint8List _pbkdf2Once(List<int> password, List<int> salt, int len) {
    final out = Uint8List(len);
    var pos = 0;
    for (var block = 1; pos < len; block++) {
      final u = HmacSha256.mac(password, [
        ...salt,
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ]);
      for (var j = 0; j < u.length && pos < len; j++) {
        out[pos++] = u[j];
      }
    }
    return out;
  }

  static void _roMix(Uint32List x, Uint32List v, Uint32List y, int n, int r) {
    final words = 32 * r;
    for (var i = 0; i < n; i++) {
      v.setRange(i * words, (i + 1) * words, x);
      _blockMix(x, y, r);
    }
    final last = (2 * r - 1) * 16;
    for (var i = 0; i < n; i++) {
      final j = x[last] & (n - 1);
      final base = j * words;
      for (var k = 0; k < words; k++) {
        x[k] ^= v[base + k];
      }
      _blockMix(x, y, r);
    }
  }

  static final Uint32List _t = Uint32List(16);
  static final Uint32List _s = Uint32List(16);

  /// BlockMix_salsa20/8: x <- BlockMix(x), y is scratch of the same size.
  static void _blockMix(Uint32List b, Uint32List y, int r) {
    final t = _t;
    t.setRange(0, 16, b, (2 * r - 1) * 16);
    for (var i = 0; i < 2 * r; i++) {
      final o = i * 16;
      for (var k = 0; k < 16; k++) {
        t[k] ^= b[o + k];
      }
      _salsa8(t);
      // even blocks first, then odd blocks
      final dst = ((i & 1) == 0 ? (i >> 1) : (r + (i >> 1))) * 16;
      y.setRange(dst, dst + 16, t);
    }
    b.setRange(0, 32 * r, y);
  }

  static int _rotl(int v, int c) =>
      ((v << c) | (v >> (32 - c))) & 0xffffffff;

  static void _salsa8(Uint32List b) {
    final x = _s;
    x.setAll(0, b);
    for (var i = 0; i < 8; i += 2) {
      x[4] ^= _rotl((x[0] + x[12]) & 0xffffffff, 7);
      x[8] ^= _rotl((x[4] + x[0]) & 0xffffffff, 9);
      x[12] ^= _rotl((x[8] + x[4]) & 0xffffffff, 13);
      x[0] ^= _rotl((x[12] + x[8]) & 0xffffffff, 18);
      x[9] ^= _rotl((x[5] + x[1]) & 0xffffffff, 7);
      x[13] ^= _rotl((x[9] + x[5]) & 0xffffffff, 9);
      x[1] ^= _rotl((x[13] + x[9]) & 0xffffffff, 13);
      x[5] ^= _rotl((x[1] + x[13]) & 0xffffffff, 18);
      x[14] ^= _rotl((x[10] + x[6]) & 0xffffffff, 7);
      x[2] ^= _rotl((x[14] + x[10]) & 0xffffffff, 9);
      x[6] ^= _rotl((x[2] + x[14]) & 0xffffffff, 13);
      x[10] ^= _rotl((x[6] + x[2]) & 0xffffffff, 18);
      x[3] ^= _rotl((x[15] + x[11]) & 0xffffffff, 7);
      x[7] ^= _rotl((x[3] + x[15]) & 0xffffffff, 9);
      x[11] ^= _rotl((x[7] + x[3]) & 0xffffffff, 13);
      x[15] ^= _rotl((x[11] + x[7]) & 0xffffffff, 18);
      x[1] ^= _rotl((x[0] + x[3]) & 0xffffffff, 7);
      x[2] ^= _rotl((x[1] + x[0]) & 0xffffffff, 9);
      x[3] ^= _rotl((x[2] + x[1]) & 0xffffffff, 13);
      x[0] ^= _rotl((x[3] + x[2]) & 0xffffffff, 18);
      x[6] ^= _rotl((x[5] + x[4]) & 0xffffffff, 7);
      x[7] ^= _rotl((x[6] + x[5]) & 0xffffffff, 9);
      x[4] ^= _rotl((x[7] + x[6]) & 0xffffffff, 13);
      x[5] ^= _rotl((x[4] + x[7]) & 0xffffffff, 18);
      x[11] ^= _rotl((x[10] + x[9]) & 0xffffffff, 7);
      x[8] ^= _rotl((x[11] + x[10]) & 0xffffffff, 9);
      x[9] ^= _rotl((x[8] + x[11]) & 0xffffffff, 13);
      x[10] ^= _rotl((x[9] + x[8]) & 0xffffffff, 18);
      x[12] ^= _rotl((x[15] + x[14]) & 0xffffffff, 7);
      x[13] ^= _rotl((x[12] + x[15]) & 0xffffffff, 9);
      x[14] ^= _rotl((x[13] + x[12]) & 0xffffffff, 13);
      x[15] ^= _rotl((x[14] + x[13]) & 0xffffffff, 18);
    }
    for (var i = 0; i < 16; i++) {
      b[i] = (b[i] + x[i]) & 0xffffffff;
    }
  }
}
