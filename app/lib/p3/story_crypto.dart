// P3 — E2E for Stories and profile Notes.
//
// A story / note is sealed ON THIS PHONE once per allowed viewer (pairwise
// X25519 + ChaCha20-Poly1305, crypto/e2e.dart) plus one self copy. The server
// stores the per-viewer ciphertext map and hands each viewer only their own
// entry — it never sees the text, the photo, or the photo's key.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/e2e.dart';
import '../messaging/media/media_api.dart';
import '../messaging/media/media_descriptor.dart';
import '../messaging/media/media_prep.dart';
import '../messaging/media/media_store.dart';

/// Privacy modes (WhatsApp): My contacts / My contacts except… / Only share with…
class StoryPrivacy {
  static const everyone = 'everyone';
  static const except = 'except';
  static const chosen = 'chosen';

  final String mode;
  final List<int> allow; // user ids (chosen)
  final List<int> exclude; // user ids (except)
  const StoryPrivacy(this.mode, {this.allow = const [], this.exclude = const []});

  static const contacts = StoryPrivacy(everyone);

  static StoryPrivacy fromJson(Object? j) {
    if (j is! Map) return contacts;
    List<int> ids(Object? x) => [
          for (final v in (x is List ? x : const []))
            if (int.tryParse('$v') != null) int.parse('$v')
        ];
    final m = '${j['mode'] ?? everyone}';
    return StoryPrivacy(
        (m == except || m == chosen) ? m : everyone,
        allow: ids(j['allow_ids']),
        exclude: ids(j['except_ids']));
  }

  Map<String, dynamic> toJson() =>
      {'mode': mode, 'allow_ids': allow, 'except_ids': exclude};

  bool allows(int userId) => switch (mode) {
        chosen => allow.contains(userId),
        except => !exclude.contains(userId),
        _ => true,
      };
}

int? peerUserId(Map<String, dynamic> m) {
  final v = m['peer_user_id'];
  return v is int ? v : int.tryParse('${v ?? ''}');
}

/// Members this story / note will be sealed for: accepted contacts with a
/// published key that the privacy choice allows.
List<Map<String, dynamic>> audienceOf(
        List<Map<String, dynamic>> members, StoryPrivacy p) =>
    [
      for (final m in members)
        if (peerUserId(m) != null &&
            '${m['public_key'] ?? ''}'.isNotEmpty &&
            p.allows(peerUserId(m)!))
          m
    ];

/// {str(userId): {ciphertext, nonce}} for every audience member + me.
Map<String, dynamic> sealForAudience({
  required E2E e2e,
  required IdentityKeyPair me,
  required int myUserId,
  required List<Map<String, dynamic>> audience,
  required String plaintext,
}) {
  final out = <String, dynamic>{};
  void put(int uid, Uint8List pub) {
    final ct = e2e.encrypt(self: me, recipientPublicKey: pub, plaintext: plaintext);
    out['$uid'] = {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64};
  }

  put(myUserId, me.publicKey);
  for (final m in audience) {
    final uid = peerUserId(m);
    if (uid == null || uid == myUserId) continue;
    try {
      put(uid, Uint8List.fromList(base64Decode('${m['public_key']}')));
    } catch (_) {
      // a malformed key: that one contact is skipped (logged nowhere)
    }
  }
  return out;
}

/// Open my copy of a story / note. [senderPub] = the author's key (my own key
/// for my own items). Older keys of the author are tried too.
String? openSealed({
  required E2E e2e,
  required IdentityKeyPair me,
  required List<Uint8List> senderKeys,
  required Map<String, dynamic> row,
}) {
  final ct = '${row['ciphertext'] ?? ''}';
  final nonce = '${row['nonce'] ?? ''}';
  if (ct.isEmpty || nonce.isEmpty) return null;
  final c = Ciphertext(
      scheme: '${row['scheme'] ?? kFallbackScheme}',
      ciphertextB64: ct,
      nonceB64: nonce,
      senderKeyId: '${row['sender_key_id'] ?? ''}');
  for (final k in senderKeys) {
    try {
      final pt = e2e.decrypt(self: me, senderPublicKey: k, ct: c);
      if (pt != null) return pt;
    } catch (_) {}
  }
  return null;
}

Uint8List? keyOf(Map<String, dynamic>? member) {
  final b = '${member?['public_key'] ?? ''}';
  if (b.isEmpty) return null;
  try {
    return Uint8List.fromList(base64Decode(b));
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- content
/// A decrypted story: text (with a background index) or a photo descriptor.
class StoryContent {
  final String text;
  final int bg;
  final MediaDescriptor? photo;
  const StoryContent({this.text = '', this.bg = 0, this.photo});

  static String encodeText(String text, int bg) =>
      jsonEncode({'p3s': 1, 'text': text, 'bg': bg});

  static StoryContent? parse(String plaintext) {
    final d = MediaDescriptor.tryParse(plaintext);
    if (d != null) return StoryContent(photo: d, text: d.caption);
    try {
      final j = jsonDecode(plaintext);
      if (j is Map && j['p3s'] == 1) {
        return StoryContent(
            text: '${j['text'] ?? ''}', bg: (j['bg'] as num?)?.toInt() ?? 0);
      }
    } catch (_) {}
    // legacy plain-text story
    return plaintext.isEmpty ? null : StoryContent(text: plaintext);
  }
}

/// Encrypt + upload a photo through the existing E2E media path
/// (circle_media_blobs: ciphertext only on the server). Returns the
/// descriptor (file key inside) that is then sealed per viewer.
Future<MediaDescriptor> uploadStoryPhoto(MediaDraft d,
    {String caption = '', MediaTransport? transport}) async {
  final tr = transport ?? HttpMediaTransport();
  final enc = '${(await MediaDirs.sub('out')).path}/${newMediaId()}.enc';
  final seal = await sealForUpload(d.path, enc);
  try {
    final b = await tr.createBlob('photo', seal.cipherSize, seal.sha256Hex);
    final ref = '${b['ref'] ?? ''}';
    if (ref.isEmpty) throw const MediaHttpError(500);
    final raf = File(enc).openSync();
    var offset = 0;
    try {
      while (offset < seal.cipherSize) {
        raf.setPositionSync(offset);
        final chunk = raf.readSync(512 * 1024);
        final r = await tr.putChunk(ref, offset, chunk);
        offset = (r['received'] as num?)?.toInt() ?? (offset + chunk.length);
      }
    } finally {
      raf.closeSync();
    }
    final fin = await tr.finish(ref);
    if (fin['complete'] != true) throw const MediaHttpError(409);
    final desc = MediaDescriptor(
      kind: 'photo',
      ref: ref,
      key: seal.key,
      nonce: seal.nonce,
      sha256: seal.sha256Hex,
      size: seal.cipherSize,
      plainSize: seal.plainSize,
      mime: d.mime,
      name: d.name,
      width: d.width,
      height: d.height,
      thumb: d.thumbB64.isEmpty ? null : base64Decode(d.thumbB64),
      caption: caption,
    );
    // my own copy: no download for the author
    await MediaCache.instance.adopt(ref, desc.ext, d.path);
    return desc;
  } finally {
    try {
      File(enc).deleteSync();
    } catch (_) {}
  }
}
