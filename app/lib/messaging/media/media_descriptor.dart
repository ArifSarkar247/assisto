import 'dart:convert';
import 'dart:typed_data';

/// md1 — what a My Circle media message carries INSIDE its E2E envelope.
///
/// The JSON below is the PLAINTEXT of the normal per-recipient message
/// encryption (crypto/e2e.dart), so only the chat's phones can read it. The
/// server only ever sees `blob_ref` (to route + retain the ciphertext) and the
/// opaque envelope; it never gets the file key, nonce, name, mime, caption or
/// thumbnail.
///
///   {"md1":1, "kind":"photo|voice|document", "ref":<blob ref>,
///    "k":<file key b64>, "n":<nonce b64>, "sha":<sha256 of ciphertext>,
///    "size":<ciphertext bytes>, "psize":<plain bytes>, "mime":..., "name":...,
///    "w":..,"h":.. (photo), "ms":.. (voice), "wave":[0..31,...] (voice),
///    "thumb":<tiny PNG b64, photo>, "cap":<caption>}
class MediaDescriptor {
  static const int version = 1;
  static const kinds = {'photo', 'voice', 'document', 'video'}; // mc-media2: + video

  final String kind;
  final String ref;
  final Uint8List key;
  final Uint8List nonce;
  final String sha256;
  final int size; // ciphertext
  final int plainSize;
  final String mime;
  final String name;
  final int? width;
  final int? height;
  final int? durationMs;
  final List<int> wave;
  final Uint8List? thumb;
  final String caption;

  const MediaDescriptor({
    required this.kind,
    required this.ref,
    required this.key,
    required this.nonce,
    required this.sha256,
    required this.size,
    required this.plainSize,
    this.mime = 'application/octet-stream',
    this.name = '',
    this.width,
    this.height,
    this.durationMs,
    this.wave = const [],
    this.thumb,
    this.caption = '',
  });

  Map<String, dynamic> toJson() => {
        'md1': version,
        'kind': kind,
        'ref': ref,
        'k': base64Encode(key),
        'n': base64Encode(nonce),
        'sha': sha256,
        'size': size,
        'psize': plainSize,
        'mime': mime,
        if (name.isNotEmpty) 'name': name,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (durationMs != null) 'ms': durationMs,
        if (wave.isNotEmpty) 'wave': wave,
        if (thumb != null) 'thumb': base64Encode(thumb!),
        if (caption.isNotEmpty) 'cap': caption,
      };

  /// The plaintext that goes through the per-recipient E2E encryption.
  String encode() => jsonEncode(toJson());

  /// Parse a decrypted message body; null when it is not a valid md1 media
  /// descriptor (wrong shape, bad key length, unknown kind).
  static MediaDescriptor? tryParse(String plaintext) {
    if (!plaintext.startsWith('{')) return null;
    try {
      final j = jsonDecode(plaintext);
      if (j is! Map || j['md1'] == null) return null;
      final kind = '${j['kind'] ?? ''}';
      if (!kinds.contains(kind)) return null;
      final key = base64Decode('${j['k'] ?? ''}');
      final nonce = base64Decode('${j['n'] ?? ''}');
      final ref = '${j['ref'] ?? ''}';
      final sha = '${j['sha'] ?? ''}';
      if (key.length != 32 || nonce.length != 12 || ref.isEmpty || sha.length != 64) {
        return null;
      }
      int? i(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
      Uint8List? thumb;
      final t = j['thumb'];
      if (t is String && t.isNotEmpty && t.length < 64 * 1024) {
        try {
          thumb = base64Decode(t);
        } catch (_) {}
      }
      final wave = <int>[
        for (final w in (j['wave'] is List ? j['wave'] as List : const []))
          if (w is num) w.toInt().clamp(0, 31)
      ];
      return MediaDescriptor(
        kind: kind,
        ref: ref,
        key: Uint8List.fromList(key),
        nonce: Uint8List.fromList(nonce),
        sha256: sha.toLowerCase(),
        size: i(j['size']) ?? 0,
        plainSize: i(j['psize']) ?? 0,
        mime: '${j['mime'] ?? 'application/octet-stream'}',
        name: _safeName('${j['name'] ?? ''}'),
        width: i(j['w']),
        height: i(j['h']),
        durationMs: i(j['ms']),
        wave: wave.length > 128 ? wave.sublist(0, 128) : wave,
        thumb: thumb,
        caption: '${j['cap'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// A received file name is shown + used for "save" — strip any path.
  static String _safeName(String n) {
    final base = n.split(RegExp(r'[\\/]')).last.trim();
    final clean = base.replaceAll(RegExp(r'[\x00-\x1f]'), '');
    return clean.length > 120 ? clean.substring(clean.length - 120) : clean;
  }

  /// File extension for the decrypted cache copy.
  String get ext {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      final e = name.substring(dot + 1).toLowerCase();
      if (RegExp(r'^[a-z0-9]{1,8}$').hasMatch(e)) return e;
    }
    switch (mime) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      case 'audio/mp4':
      case 'audio/aac':
        return 'm4a';
      case 'application/pdf':
        return 'pdf';
      case 'video/mp4':
        return 'mp4';
      case 'video/3gpp':
        return '3gp';
      case 'video/webm':
        return 'webm';
      case 'video/quicktime':
        return 'mov';
    }
    return kind == 'photo' ? 'jpg' : kind == 'voice' ? 'm4a' : kind == 'video' ? 'mp4' : 'bin';
  }
}

/// "1.2 MB" style size (Latin digits; callers localize digits).
String mediaSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// "0:42" / "12:05".
String mediaDurationLabel(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

// e-gaps: view-once photos (see messaging/view_once.dart).
/// Whether a decrypted descriptor JSON is a view-once one (`"vo":1`).
bool descriptorIsViewOnce(String plaintext) {
  if (!plaintext.startsWith('{') || !plaintext.contains('"vo"')) return false;
  try {
    final j = jsonDecode(plaintext);
    return j is Map && (j['vo'] == 1 || j['vo'] == true);
  } catch (_) {
    return false;
  }
}

/// Mark a descriptor JSON as view-once (and drop the thumbnail: nothing of
/// the photo may stay in the chat).
String markViewOnce(String descriptorJson) {
  final j = jsonDecode(descriptorJson) as Map<String, dynamic>;
  j['vo'] = 1;
  j.remove('thumb');
  return jsonEncode(j);
}
