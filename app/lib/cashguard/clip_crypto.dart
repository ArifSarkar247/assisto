// cashguard — open a Smart Cash Guard clip ON THIS PHONE.
//
// The Shop Box / Guard Box cuts a 3-5 s clip from the shop's local stream and
// seals it before upload (edge/shopbox/shopbox/clip.py):
//   * the clip ("ACG1": JSON header + JPEG frames) is ChaCha20-Poly1305
//     encrypted with a fresh per-event key K (aad "assisto-cashguard-clip-v1");
//   * K (as base64 text) is wrapped for each recipient with the SAME
//     construction as our chat E2E ([SoftwareE2E], scheme
//     x25519-xchacha-fallback-v1): an ephemeral X25519 key on the edge,
//     HKDF-SHA256, ChaCha20-Poly1305, aad = the ephemeral key id.
// So opening it is exactly [SoftwareE2E.decrypt] with the ephemeral public
// key as the "sender" — the server only ever holds ciphertext.
//
// Pure Dart, no plugins: runs in a background isolate ([openClipInIsolate])
// so a ~1 MB clip never janks the UI. Nothing is written to disk.

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../crypto/e2e.dart';

const String kClipAad = 'assisto-cashguard-clip-v1';
const String kClipScheme = kFallbackScheme;

/// A decoded clip: JPEG frames + their timing.
class CashClip {
  final double fps;
  final List<Uint8List> frames;
  final List<double> times; // seconds from the first frame
  const CashClip(this.fps, this.frames, this.times);

  double get durationS => frames.isEmpty ? 0 : (times.isEmpty ? frames.length / fps : times.last + 1 / fps);
}

class ClipOpenError implements Exception {
  /// 'no_key' (none of my keys matches the wrap), 'bad_wrap', 'bad_clip'
  /// (tampered / damaged), 'bad_format'.
  final String code;
  const ClipOpenError(this.code);
  @override
  String toString() => 'ClipOpenError($code)';
}

/// Parse the "ACG1" container: MAGIC, u32 BE header length, JSON header,
/// then n x (u32 BE length + JPEG bytes).
CashClip decodeContainer(Uint8List raw) {
  if (raw.length < 8 || raw[0] != 0x41 || raw[1] != 0x43 || raw[2] != 0x47 || raw[3] != 0x31) {
    throw const ClipOpenError('bad_format');
  }
  final bd = ByteData.sublistView(raw);
  final hl = bd.getUint32(4, Endian.big);
  if (8 + hl > raw.length) throw const ClipOpenError('bad_format');
  final Map<String, dynamic> head;
  try {
    head = (jsonDecode(utf8.decode(raw.sublist(8, 8 + hl))) as Map).cast<String, dynamic>();
  } catch (_) {
    throw const ClipOpenError('bad_format');
  }
  final n = (head['n'] as num?)?.toInt() ?? 0;
  if (n <= 0 || n > 400) throw const ClipOpenError('bad_format');
  var off = 8 + hl;
  final frames = <Uint8List>[];
  for (var i = 0; i < n; i++) {
    if (off + 4 > raw.length) throw const ClipOpenError('bad_format');
    final len = bd.getUint32(off, Endian.big);
    if (off + 4 + len > raw.length) throw const ClipOpenError('bad_format');
    frames.add(Uint8List.sublistView(raw, off + 4, off + 4 + len));
    off += 4 + len;
  }
  final ts = [for (final t in (head['ts'] as List? ?? const [])) (t as num).toDouble()];
  final fps = ((head['fps'] as num?) ?? 5).toDouble();
  return CashClip(fps <= 0 ? 5 : fps, frames, ts.length == frames.length ? ts : const []);
}

/// Unwrap the per-event content key (32 bytes) with one of [keys] (current
/// key first). The edge's wrap uses its ephemeral key as the "sender"; a
/// wrap the OWNER's phone made when sharing (cctvx) carries `sender_pub` /
/// `sender_key_id` — the owner's identity key. Throws [ClipOpenError].
Uint8List unwrapClipKey({
  required Map<String, dynamic> meta,
  required List<IdentityKeyPair> keys,
}) {
  final wrap = meta['wrap'] is Map ? (meta['wrap'] as Map).cast<String, dynamic>() : null;
  if (wrap == null || keys.isEmpty) throw const ClipOpenError('no_key');
  final Uint8List senderPub;
  try {
    senderPub = base64Decode((wrap['sender_pub'] ?? meta['eph_pub']) as String);
  } catch (_) {
    throw const ClipOpenError('bad_wrap');
  }
  final ct = Ciphertext(
    scheme: kClipScheme,
    ciphertextB64: (wrap['ct'] ?? '').toString(),
    nonceB64: (wrap['nonce'] ?? '').toString(),
    senderKeyId: (wrap['sender_key_id'] ?? meta['eph_key_id'] ?? '').toString(),
  );
  final want = (wrap['key_id'] ?? '').toString();
  final ordered = [
    ...keys.where((k) => k.keyId == want),
    ...keys.where((k) => k.keyId != want),
  ];
  final e2e = SoftwareE2E();
  String? kB64;
  for (final k in ordered) {
    kB64 = e2e.decrypt(self: k, senderPublicKey: senderPub, ct: ct);
    if (kB64 != null) break;
  }
  if (kB64 == null) throw const ClipOpenError('no_key');
  final Uint8List key;
  try {
    key = base64Decode(kB64);
  } catch (_) {
    throw const ClipOpenError('bad_wrap');
  }
  if (key.length != 32) throw const ClipOpenError('bad_wrap');
  return key;
}

/// cctvx — share a clip with ONE Circle member: wrap the content key again
/// for the member's PUBLIC key, with this phone's identity key as the
/// sender (the chat E2E construction). The server only relays the wrap.
Map<String, String> wrapClipKeyFor({
  required Uint8List contentKey,
  required IdentityKeyPair me,
  required Uint8List memberPublicKey,
  required String memberKeyId,
}) {
  final ct = SoftwareE2E().encrypt(
      self: me, recipientPublicKey: memberPublicKey, plaintext: base64Encode(contentKey));
  return {
    'key_id': memberKeyId,
    'nonce': ct.nonceB64,
    'ct': ct.ciphertextB64,
    'sender_pub': me.publicKeyB64,
    'sender_key_id': me.keyId,
  };
}

/// Unwrap the per-event key with one of [keys] (current key first), then
/// decrypt + parse. [meta] is the server's envelope for ME (`wrap` = my
/// wrapped key). Throws [ClipOpenError].
CashClip openClip({
  required Map<String, dynamic> meta,
  required Uint8List ciphertext,
  required List<IdentityKeyPair> keys,
}) {
  final key = unwrapClipKey(meta: meta, keys: keys);
  final Uint8List nonce;
  try {
    nonce = base64Decode(meta['nonce'] as String);
  } catch (_) {
    throw const ClipOpenError('bad_wrap');
  }
  final aad = utf8.encode((meta['aad'] ?? kClipAad).toString());
  final plain = ChaCha20Poly1305.decrypt(key, nonce, ciphertext, aad: aad);
  if (plain == null) throw const ClipOpenError('bad_clip');
  return decodeContainer(plain);
}

/// [openClip] in a background isolate. Keys travel as plain bytes.
Future<CashClip> openClipInIsolate({
  required Map<String, dynamic> meta,
  required Uint8List ciphertext,
  required List<IdentityKeyPair> keys,
}) {
  final rawKeys = [for (final k in keys) (k.privateKey, k.publicKey, k.keyId)];
  final m = Map<String, dynamic>.from(meta);
  return Isolate.run(() => openClip(
        meta: m,
        ciphertext: ciphertext,
        keys: [for (final r in rawKeys) IdentityKeyPair(r.$1, r.$2, r.$3)],
      ));
}
