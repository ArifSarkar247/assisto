// md1 — E2E media crypto: RFC 8439 vector, agreement with crypto/e2e.dart,
// chunked round trip (memory + file), tamper / truncation / reorder / wrong
// key / swapped blob detection, sha256 of the ciphertext.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/messaging/media/media_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String h) {
  h = h.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)
  ]);
}

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('RFC 8439 2.8.2 AEAD vector', () {
    final key = _hex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
    final nonce = _hex('070000004041424344454647');
    final aad = _hex('50515253c0c1c2c3c4c5c6c7');
    final pt = Uint8List.fromList(
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
            .codeUnits);
    final out = FastAead.seal(key, nonce, pt, aad);
    expect(_toHex(out.sublist(out.length - 16)), '1ae10b594f09e26a7e902ecbd0600691');
    expect(_toHex(out.sublist(0, 16)), 'd31a8d34648e60db7b86afbc53ef7ec2');
    expect(FastAead.open(key, nonce, out, aad), pt);
  });

  test('fast AEAD == crypto/e2e.dart ChaCha20Poly1305 (random sizes)', () {
    final r = Random(7);
    for (final n in [0, 1, 15, 16, 17, 63, 64, 65, 1000, 4096 + 3]) {
      final key = randomBytes(32, r);
      final nonce = randomBytes(12, r);
      final pt = randomBytes(n, r);
      final aad = randomBytes(r.nextInt(30), r);
      final slow = ChaCha20Poly1305.encrypt(key, nonce, pt, aad: aad);
      final fast = FastAead.seal(key, nonce, pt, aad);
      expect(fast, slow, reason: 'size $n');
      expect(ChaCha20Poly1305.decrypt(key, nonce, fast, aad: aad), pt);
    }
  });

  test('chunked round trip in memory incl. exact chunk boundaries', () {
    final r = Random(1);
    for (final n in [0, 1, kMediaChunk - 1, kMediaChunk, kMediaChunk + 1,
        3 * kMediaChunk, 3 * kMediaChunk + 77]) {
      final key = randomBytes(32, r), nonce = randomBytes(12, r);
      final pt = randomBytes(n, r);
      final ct = sealBytes(key, nonce, pt);
      expect(ct.length, mediaCipherSize(n));
      expect(openBytes(key, nonce, ct), pt, reason: 'size $n');
    }
  });

  test('tamper, truncation, reorder and wrong key are all rejected', () {
    final r = Random(2);
    final key = randomBytes(32, r), nonce = randomBytes(12, r);
    final pt = randomBytes(2 * kMediaChunk + 500, r);
    final ct = sealBytes(key, nonce, pt);
    final flip = Uint8List.fromList(ct)..[10] ^= 1;
    expect(openBytes(key, nonce, flip), isNull);
    // drop the last chunk (truncation at a chunk boundary)
    expect(openBytes(key, nonce, Uint8List.sublistView(ct, 0, 2 * kMediaCipherChunk)),
        isNull);
    // swap chunk 0 and 1
    final sw = Uint8List.fromList(ct);
    sw.setRange(0, kMediaCipherChunk, ct.sublist(kMediaCipherChunk, 2 * kMediaCipherChunk));
    sw.setRange(kMediaCipherChunk, 2 * kMediaCipherChunk, ct.sublist(0, kMediaCipherChunk));
    expect(openBytes(key, nonce, sw), isNull);
    expect(openBytes(randomBytes(32, r), nonce, ct), isNull);
    expect(openBytes(key, randomBytes(12, r), ct), isNull);
  });

  test('file seal/open with sha256 of the ciphertext; swapped blob refused', () async {
    final dir = await Directory.systemTemp.createTemp('md1c');
    final r = Random(3);
    final pt = randomBytes(5 * kMediaChunk + 123, r);
    final inF = File('${dir.path}/in.bin')..writeAsBytesSync(pt);
    final seal = sealFileSync(inF.path, '${dir.path}/out.enc', randomBytes(32, r),
        randomBytes(12, r));
    final ct = File('${dir.path}/out.enc').readAsBytesSync();
    expect(seal.cipherSize, ct.length);
    expect(seal.plainSize, pt.length);
    expect(seal.sha256Hex, sha256Hex(ct));
    // the ciphertext never contains the plaintext
    expect(ct.sublist(0, 64), isNot(pt.sublist(0, 64)));
    expect(openFileSync('${dir.path}/out.enc', '${dir.path}/dec.bin', seal.key,
        seal.nonce, seal.sha256Hex), isTrue);
    expect(File('${dir.path}/dec.bin').readAsBytesSync(), pt);
    // wrong expected hash -> refused before decrypting, no output left
    expect(openFileSync('${dir.path}/out.enc', '${dir.path}/dec2.bin', seal.key,
        seal.nonce, '0' * 64), isFalse);
    expect(File('${dir.path}/dec2.bin').existsSync(), isFalse);
    // tampered file with the right hash claim -> tag fails, output deleted
    final bad = Uint8List.fromList(ct)..[100] ^= 0x40;
    File('${dir.path}/bad.enc').writeAsBytesSync(bad);
    expect(openFileSync('${dir.path}/bad.enc', '${dir.path}/dec3.bin', seal.key,
        seal.nonce, ''), isFalse);
    expect(File('${dir.path}/dec3.bin').existsSync(), isFalse);
    await dir.delete(recursive: true);
  });

  test('a 3 MB file seals fast enough for low-end phones (sanity)', () {
    final r = Random(4);
    final pt = randomBytes(3 * 1024 * 1024, r);
    final sw = Stopwatch()..start();
    final ct = sealBytes(randomBytes(32, r), randomBytes(12, r), pt);
    sw.stop();
    expect(ct.length, mediaCipherSize(pt.length));
    // desktop VM; generous bound only to catch an accidental O(n^2) / BigInt
    expect(sw.elapsedMilliseconds, lessThan(8000));
  });
}
