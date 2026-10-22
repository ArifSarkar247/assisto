// md1 — My Circle E2E media: per-file encryption ON THE PHONE.
//
// Each file gets a fresh random 32-byte key + 12-byte nonce (Random.secure).
// The file is sealed with ChaCha20-Poly1305 (RFC 8439 — the same AEAD as the
// message layer in crypto/e2e.dart) in 64 KiB chunks so RAM stays small on
// low-memory phones (a 25 MB document never sits in memory):
//
//   chunk i  = ChaCha20-Poly1305(key, nonce_i, plain_i, aad_i) = ct_i || tag_i
//   nonce_i  = nonce with bytes 4..11 XOR little-endian(i)
//   aad_i    = "assisto-md1" || le64(i) || final(1 byte)
//
// Reordering, dropping or truncating chunks fails the tag (the final flag
// binds the last chunk). The SHA-256 of the WHOLE ciphertext travels in the
// E2E message so the receiver rejects a swapped blob before decrypting.
//
// The primitives here are fast pure-Dart versions (Uint32 state, 26-bit-limb
// Poly1305) of the ones in crypto/e2e.dart, which use BigInt and are far too
// slow for megabytes. Tests prove both agree byte-for-byte on one chunk.
// Encryption/decryption of files runs in a background isolate (Isolate.run).

import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hc;

const int kMediaChunk = 64 * 1024;
const int kMediaTag = 16;
const int kMediaCipherChunk = kMediaChunk + kMediaTag;
final Uint8List _aadPrefix = Uint8List.fromList('assisto-md1'.codeUnits);

/// The secret + integrity facts of one sealed file (all go INSIDE the E2E
/// message; none ever reach the server in clear).
class MediaSeal {
  final Uint8List key; // 32
  final Uint8List nonce; // 12
  final String sha256Hex; // of the ciphertext
  final int cipherSize;
  final int plainSize;
  const MediaSeal(
      {required this.key,
      required this.nonce,
      required this.sha256Hex,
      required this.cipherSize,
      required this.plainSize});
}

Uint8List randomBytes(int n, [Random? rng]) {
  final r = rng ?? Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

/// Ciphertext size for [plainSize] bytes.
int mediaCipherSize(int plainSize) {
  final chunks = plainSize == 0 ? 1 : (plainSize + kMediaChunk - 1) ~/ kMediaChunk;
  return plainSize + chunks * kMediaTag;
}

Uint8List _chunkNonce(Uint8List nonce, int i) {
  final n = Uint8List.fromList(nonce);
  var v = i;
  for (var b = 4; b < 12; b++) {
    n[b] ^= v & 0xff;
    v >>= 8;
  }
  return n;
}

Uint8List _chunkAad(int i, bool last) {
  final a = Uint8List(_aadPrefix.length + 9);
  a.setAll(0, _aadPrefix);
  var v = i;
  for (var b = 0; b < 8; b++) {
    a[_aadPrefix.length + b] = v & 0xff;
    v >>= 8;
  }
  a[_aadPrefix.length + 8] = last ? 1 : 0;
  return a;
}

/// Seal one chunk: returns ct || tag.
Uint8List sealChunk(Uint8List key, Uint8List nonce, int index, bool last,
    Uint8List plain) {
  return FastAead.seal(key, _chunkNonce(nonce, index), plain,
      _chunkAad(index, last));
}

/// Open one chunk; null on tamper.
Uint8List? openChunk(Uint8List key, Uint8List nonce, int index, bool last,
    Uint8List sealed) {
  return FastAead.open(key, _chunkNonce(nonce, index), sealed,
      _chunkAad(index, last));
}

/// In-memory seal (small files / tests). Returns the whole ciphertext.
Uint8List sealBytes(Uint8List key, Uint8List nonce, Uint8List plain) {
  final out = BytesBuilder(copy: false);
  final n = plain.isEmpty ? 1 : (plain.length + kMediaChunk - 1) ~/ kMediaChunk;
  for (var i = 0; i < n; i++) {
    final s = i * kMediaChunk;
    final e = min(s + kMediaChunk, plain.length);
    out.add(sealChunk(key, nonce, i, i == n - 1,
        Uint8List.sublistView(plain, s, e)));
  }
  return out.toBytes();
}

/// In-memory open; null on any tamper / truncation.
Uint8List? openBytes(Uint8List key, Uint8List nonce, Uint8List cipher) {
  if (cipher.length < kMediaTag) return null;
  final n = (cipher.length + kMediaCipherChunk - 1) ~/ kMediaCipherChunk;
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < n; i++) {
    final s = i * kMediaCipherChunk;
    final e = min(s + kMediaCipherChunk, cipher.length);
    if (e - s < kMediaTag) return null;
    final p = openChunk(key, nonce, i, i == n - 1,
        Uint8List.sublistView(cipher, s, e));
    if (p == null) return null;
    out.add(p);
  }
  return out.toBytes();
}

String sha256Hex(List<int> bytes) => hc.sha256.convert(bytes).toString();

/// Seal [inPath] into [outPath] chunk by chunk (sync; call via [sealFile]).
MediaSeal sealFileSync(String inPath, String outPath, Uint8List key,
    Uint8List nonce) {
  final src = File(inPath).openSync();
  final dst = File(outPath).openSync(mode: FileMode.write);
  final sink = _ShaSink();
  final hasher = hc.sha256.startChunkedConversion(sink);
  try {
    final size = src.lengthSync();
    final n = size == 0 ? 1 : (size + kMediaChunk - 1) ~/ kMediaChunk;
    var written = 0;
    for (var i = 0; i < n; i++) {
      final plain = src.readSync(kMediaChunk);
      final sealed = sealChunk(key, nonce, i, i == n - 1, plain);
      dst.writeFromSync(sealed);
      hasher.add(sealed);
      written += sealed.length;
    }
    hasher.close();
    return MediaSeal(
        key: key,
        nonce: nonce,
        sha256Hex: sink.value.toString(),
        cipherSize: written,
        plainSize: size);
  } finally {
    src.closeSync();
    dst.closeSync();
  }
}

/// Verify sha256 + open [inPath] into [outPath]. Returns false (and deletes
/// the partial output) on a wrong hash or any tampered chunk.
bool openFileSync(String inPath, String outPath, Uint8List key, Uint8List nonce,
    String expectSha) {
  final f = File(inPath);
  final size = f.lengthSync();
  if (size < kMediaTag) return false;
  // 1) hash first: never decrypt a blob that is not the one in the message
  final sink = _ShaSink();
  final hasher = hc.sha256.startChunkedConversion(sink);
  final r1 = f.openSync();
  try {
    while (true) {
      final b = r1.readSync(256 * 1024);
      if (b.isEmpty) break;
      hasher.add(b);
    }
  } finally {
    r1.closeSync();
  }
  hasher.close();
  if (expectSha.isNotEmpty && sink.value.toString() != expectSha.toLowerCase()) {
    return false;
  }
  // 2) open chunk by chunk
  final n = (size + kMediaCipherChunk - 1) ~/ kMediaCipherChunk;
  final src = f.openSync();
  final out = File(outPath);
  final dst = out.openSync(mode: FileMode.write);
  var ok = true;
  try {
    for (var i = 0; i < n; i++) {
      final sealed = src.readSync(kMediaCipherChunk);
      if (sealed.length < kMediaTag) {
        ok = false;
        break;
      }
      final p = openChunk(key, nonce, i, i == n - 1, sealed);
      if (p == null) {
        ok = false;
        break;
      }
      dst.writeFromSync(p);
    }
  } finally {
    src.closeSync();
    dst.closeSync();
  }
  if (!ok) {
    try {
      out.deleteSync();
    } catch (_) {}
  }
  return ok;
}

/// Background-isolate wrappers (the UI never stalls on a big file).
Future<MediaSeal> sealFile(String inPath, String outPath,
    {Uint8List? key, Uint8List? nonce}) {
  final k = key ?? randomBytes(32);
  final n = nonce ?? randomBytes(12);
  return Isolate.run(() => sealFileSync(inPath, outPath, k, n));
}

Future<bool> openFile(String inPath, String outPath, Uint8List key,
    Uint8List nonce, String expectSha) {
  return Isolate.run(() => openFileSync(inPath, outPath, key, nonce, expectSha));
}

class _ShaSink implements Sink<hc.Digest> {
  late hc.Digest value;
  @override
  void add(hc.Digest data) => value = data;
  @override
  void close() {}
}

// ===========================================================================
// Fast ChaCha20-Poly1305 (RFC 8439). Same output as crypto/e2e.dart's
// ChaCha20Poly1305 (proven in test/md1_media_crypto_test.dart).
// ===========================================================================
class FastAead {
  static Uint8List seal(
      Uint8List key, Uint8List nonce, Uint8List plain, List<int> aad) {
    final c = _ChaCha(key, nonce);
    final polyKey = c.block(0).sublist(0, 32);
    final out = Uint8List(plain.length + 16);
    c.xor(plain, out, 1);
    final tag = _tag(polyKey, aad, Uint8List.sublistView(out, 0, plain.length));
    out.setAll(plain.length, tag);
    return out;
  }

  static Uint8List? open(
      Uint8List key, Uint8List nonce, Uint8List sealed, List<int> aad) {
    if (sealed.length < 16) return null;
    final ctLen = sealed.length - 16;
    final ct = Uint8List.sublistView(sealed, 0, ctLen);
    final c = _ChaCha(key, nonce);
    final polyKey = c.block(0).sublist(0, 32);
    final expect = _tag(polyKey, aad, ct);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= expect[i] ^ sealed[ctLen + i];
    }
    if (diff != 0) return null;
    final out = Uint8List(ctLen);
    c.xor(ct, out, 1);
    return out;
  }

  static Uint8List _tag(Uint8List polyKey, List<int> aad, Uint8List ct) {
    final p = Poly1305(polyKey);
    final a = aad is Uint8List ? aad : Uint8List.fromList(aad);
    p.update(a);
    p.pad16(a.length);
    p.update(ct);
    p.pad16(ct.length);
    final lens = Uint8List(16);
    var x = a.length, y = ct.length;
    for (var i = 0; i < 8; i++) {
      lens[i] = x & 0xff;
      lens[8 + i] = y & 0xff;
      x >>= 8;
      y >>= 8;
    }
    p.update(lens);
    return p.finish();
  }
}

class _ChaCha {
  final Uint32List _s = Uint32List(16);
  final Uint32List _w = Uint32List(16);
  final Uint8List _ks = Uint8List(64);

  _ChaCha(Uint8List key, Uint8List nonce) {
    _s[0] = 0x61707865;
    _s[1] = 0x3320646e;
    _s[2] = 0x79622d32;
    _s[3] = 0x6b206574;
    for (var i = 0; i < 8; i++) {
      _s[4 + i] = _le32(key, i * 4);
    }
    _s[13] = _le32(nonce, 0);
    _s[14] = _le32(nonce, 4);
    _s[15] = _le32(nonce, 8);
  }

  static int _le32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  Uint8List block(int counter) {
    _run(counter);
    return Uint8List.fromList(_ks);
  }

  void _run(int counter) {
    _s[12] = counter;
    final w = _w;
    for (var i = 0; i < 16; i++) {
      w[i] = _s[i];
    }
    var x0 = w[0], x1 = w[1], x2 = w[2], x3 = w[3];
    var x4 = w[4], x5 = w[5], x6 = w[6], x7 = w[7];
    var x8 = w[8], x9 = w[9], x10 = w[10], x11 = w[11];
    var x12 = w[12], x13 = w[13], x14 = w[14], x15 = w[15];
    for (var r = 0; r < 10; r++) {
      // column rounds
      x0 = (x0 + x4) & 0xffffffff; x12 = _rl(x12 ^ x0, 16);
      x8 = (x8 + x12) & 0xffffffff; x4 = _rl(x4 ^ x8, 12);
      x0 = (x0 + x4) & 0xffffffff; x12 = _rl(x12 ^ x0, 8);
      x8 = (x8 + x12) & 0xffffffff; x4 = _rl(x4 ^ x8, 7);
      x1 = (x1 + x5) & 0xffffffff; x13 = _rl(x13 ^ x1, 16);
      x9 = (x9 + x13) & 0xffffffff; x5 = _rl(x5 ^ x9, 12);
      x1 = (x1 + x5) & 0xffffffff; x13 = _rl(x13 ^ x1, 8);
      x9 = (x9 + x13) & 0xffffffff; x5 = _rl(x5 ^ x9, 7);
      x2 = (x2 + x6) & 0xffffffff; x14 = _rl(x14 ^ x2, 16);
      x10 = (x10 + x14) & 0xffffffff; x6 = _rl(x6 ^ x10, 12);
      x2 = (x2 + x6) & 0xffffffff; x14 = _rl(x14 ^ x2, 8);
      x10 = (x10 + x14) & 0xffffffff; x6 = _rl(x6 ^ x10, 7);
      x3 = (x3 + x7) & 0xffffffff; x15 = _rl(x15 ^ x3, 16);
      x11 = (x11 + x15) & 0xffffffff; x7 = _rl(x7 ^ x11, 12);
      x3 = (x3 + x7) & 0xffffffff; x15 = _rl(x15 ^ x3, 8);
      x11 = (x11 + x15) & 0xffffffff; x7 = _rl(x7 ^ x11, 7);
      // diagonal rounds
      x0 = (x0 + x5) & 0xffffffff; x15 = _rl(x15 ^ x0, 16);
      x10 = (x10 + x15) & 0xffffffff; x5 = _rl(x5 ^ x10, 12);
      x0 = (x0 + x5) & 0xffffffff; x15 = _rl(x15 ^ x0, 8);
      x10 = (x10 + x15) & 0xffffffff; x5 = _rl(x5 ^ x10, 7);
      x1 = (x1 + x6) & 0xffffffff; x12 = _rl(x12 ^ x1, 16);
      x11 = (x11 + x12) & 0xffffffff; x6 = _rl(x6 ^ x11, 12);
      x1 = (x1 + x6) & 0xffffffff; x12 = _rl(x12 ^ x1, 8);
      x11 = (x11 + x12) & 0xffffffff; x6 = _rl(x6 ^ x11, 7);
      x2 = (x2 + x7) & 0xffffffff; x13 = _rl(x13 ^ x2, 16);
      x8 = (x8 + x13) & 0xffffffff; x7 = _rl(x7 ^ x8, 12);
      x2 = (x2 + x7) & 0xffffffff; x13 = _rl(x13 ^ x2, 8);
      x8 = (x8 + x13) & 0xffffffff; x7 = _rl(x7 ^ x8, 7);
      x3 = (x3 + x4) & 0xffffffff; x14 = _rl(x14 ^ x3, 16);
      x9 = (x9 + x14) & 0xffffffff; x4 = _rl(x4 ^ x9, 12);
      x3 = (x3 + x4) & 0xffffffff; x14 = _rl(x14 ^ x3, 8);
      x9 = (x9 + x14) & 0xffffffff; x4 = _rl(x4 ^ x9, 7);
    }
    final o = [x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15];
    final ks = _ks;
    for (var i = 0; i < 16; i++) {
      final v = (o[i] + _s[i]) & 0xffffffff;
      final j = i << 2;
      ks[j] = v & 0xff;
      ks[j + 1] = (v >> 8) & 0xff;
      ks[j + 2] = (v >> 16) & 0xff;
      ks[j + 3] = (v >> 24) & 0xff;
    }
  }

  static int _rl(int v, int n) =>
      ((v << n) & 0xffffffff) | ((v & 0xffffffff) >> (32 - n));

  void xor(Uint8List src, Uint8List dst, int counter) {
    var c = counter;
    for (var off = 0; off < src.length; off += 64) {
      _run(c++);
      final n = min(64, src.length - off);
      for (var i = 0; i < n; i++) {
        dst[off + i] = src[off + i] ^ _ks[i];
      }
    }
  }
}

/// Poly1305 with 26-bit limbs in native 64-bit ints (poly1305-donna style).
class Poly1305 {
  static const int _m = 0x3ffffff;
  late final int _r0, _r1, _r2, _r3, _r4, _s1, _s2, _s3, _s4;
  late final int _p0, _p1, _p2, _p3;
  int _h0 = 0, _h1 = 0, _h2 = 0, _h3 = 0, _h4 = 0;
  final Uint8List _buf = Uint8List(16);
  int _bufLen = 0;

  Poly1305(Uint8List key) {
    int le(int o) =>
        key[o] | (key[o + 1] << 8) | (key[o + 2] << 16) | (key[o + 3] << 24);
    _r0 = le(0) & 0x3ffffff;
    _r1 = (le(3) >> 2) & 0x3ffff03;
    _r2 = (le(6) >> 4) & 0x3ffc0ff;
    _r3 = (le(9) >> 6) & 0x3f03fff;
    _r4 = (le(12) >> 8) & 0x00fffff;
    _s1 = _r1 * 5;
    _s2 = _r2 * 5;
    _s3 = _r3 * 5;
    _s4 = _r4 * 5;
    _p0 = le(16);
    _p1 = le(20);
    _p2 = le(24);
    _p3 = le(28);
  }

  void _block(Uint8List m, int o, int hibit) {
    int le(int x) =>
        m[o + x] | (m[o + x + 1] << 8) | (m[o + x + 2] << 16) | (m[o + x + 3] << 24);
    var h0 = _h0 + (le(0) & _m);
    var h1 = _h1 + ((le(3) >> 2) & _m);
    var h2 = _h2 + ((le(6) >> 4) & _m);
    var h3 = _h3 + ((le(9) >> 6) & _m);
    var h4 = _h4 + ((le(12) >> 8) | hibit);
    final d0 = h0 * _r0 + h1 * _s4 + h2 * _s3 + h3 * _s2 + h4 * _s1;
    var d1 = h0 * _r1 + h1 * _r0 + h2 * _s4 + h3 * _s3 + h4 * _s2;
    var d2 = h0 * _r2 + h1 * _r1 + h2 * _r0 + h3 * _s4 + h4 * _s3;
    var d3 = h0 * _r3 + h1 * _r2 + h2 * _r1 + h3 * _r0 + h4 * _s4;
    var d4 = h0 * _r4 + h1 * _r3 + h2 * _r2 + h3 * _r1 + h4 * _r0;
    var c = d0 >> 26;
    h0 = d0 & _m;
    d1 += c;
    c = d1 >> 26;
    h1 = d1 & _m;
    d2 += c;
    c = d2 >> 26;
    h2 = d2 & _m;
    d3 += c;
    c = d3 >> 26;
    h3 = d3 & _m;
    d4 += c;
    c = d4 >> 26;
    h4 = d4 & _m;
    h0 += c * 5;
    c = h0 >> 26;
    h0 &= _m;
    h1 += c;
    _h0 = h0;
    _h1 = h1;
    _h2 = h2;
    _h3 = h3;
    _h4 = h4;
  }

  void update(Uint8List data) {
    var i = 0;
    final n = data.length;
    if (_bufLen > 0) {
      while (_bufLen < 16 && i < n) {
        _buf[_bufLen++] = data[i++];
      }
      if (_bufLen < 16) return;
      _block(_buf, 0, 1 << 24);
      _bufLen = 0;
    }
    while (n - i >= 16) {
      _block(data, i, 1 << 24);
      i += 16;
    }
    while (i < n) {
      _buf[_bufLen++] = data[i++];
    }
  }

  /// Zero padding to a 16-byte boundary for a field of [len] bytes (AEAD).
  void pad16(int len) {
    final r = len % 16;
    if (r != 0) update(Uint8List(16 - r));
  }

  Uint8List finish() {
    if (_bufLen > 0) {
      _buf[_bufLen] = 1;
      for (var i = _bufLen + 1; i < 16; i++) {
        _buf[i] = 0;
      }
      _block(_buf, 0, 0);
      _bufLen = 0;
    }
    var h0 = _h0, h1 = _h1, h2 = _h2, h3 = _h3, h4 = _h4;
    var c = h1 >> 26;
    h1 &= _m;
    h2 += c;
    c = h2 >> 26;
    h2 &= _m;
    h3 += c;
    c = h3 >> 26;
    h3 &= _m;
    h4 += c;
    c = h4 >> 26;
    h4 &= _m;
    h0 += c * 5;
    c = h0 >> 26;
    h0 &= _m;
    h1 += c;
    // h - p
    var g0 = h0 + 5;
    c = g0 >> 26;
    g0 &= _m;
    var g1 = h1 + c;
    c = g1 >> 26;
    g1 &= _m;
    var g2 = h2 + c;
    c = g2 >> 26;
    g2 &= _m;
    var g3 = h3 + c;
    c = g3 >> 26;
    g3 &= _m;
    final g4 = h4 + c - (1 << 26);
    if (g4 >= 0) {
      h0 = g0;
      h1 = g1;
      h2 = g2;
      h3 = g3;
      h4 = g4;
    }
    final w0 = (h0 | (h1 << 26)) & 0xffffffff;
    final w1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff;
    final w2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff;
    final w3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff;
    var f = w0 + _p0;
    final o0 = f & 0xffffffff;
    f = w1 + _p1 + (f >> 32);
    final o1 = f & 0xffffffff;
    f = w2 + _p2 + (f >> 32);
    final o2 = f & 0xffffffff;
    f = w3 + _p3 + (f >> 32);
    final o3 = f & 0xffffffff;
    final out = Uint8List(16);
    final ws = [o0, o1, o2, o3];
    for (var i = 0; i < 4; i++) {
      out[i * 4] = ws[i] & 0xff;
      out[i * 4 + 1] = (ws[i] >> 8) & 0xff;
      out[i * 4 + 2] = (ws[i] >> 16) & 0xff;
      out[i * 4 + 3] = (ws[i] >> 24) & 0xff;
    }
    return out;
  }
}
