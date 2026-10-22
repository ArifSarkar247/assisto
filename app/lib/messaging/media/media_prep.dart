import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_report.dart';
import '../msg_native.dart';
import 'media_store.dart';

/// md1 — preparing a file to send, ON THE PHONE, before it is encrypted.
///
///   photo:    image_picker resizes to <= 1600 px long edge at JPEG q 80; we
///             then drop every metadata segment (EXIF incl. GPS location, XMP,
///             IPTC, comments) and keep ONLY the orientation, so the picture
///             stays upright but carries no location / camera details.
///   document: the phone's own document picker copies the file into the app.
///   voice:    see voice_recorder_sheet.dart (AAC-LC .m4a, mono).
class MediaDraft {
  final String kind; // photo | voice | document
  final String path; // app-owned plaintext copy
  final String name;
  final String mime;
  final int size;
  final int? width, height, durationMs;
  final List<int> wave;
  final String thumbB64;
  const MediaDraft({
    required this.kind,
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
    this.width,
    this.height,
    this.durationMs,
    this.wave = const [],
    this.thumbB64 = '',
  });
}

const int kPhotoMaxEdge = 1600;
const int kPhotoQuality = 80;
const int kThumbEdge = 32;

// ---------------------------------------------------------------- JPEG
bool isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;
bool isPng(Uint8List b) =>
    b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

/// EXIF orientation (1..8) of a JPEG, or 1.
int jpegOrientation(Uint8List b) {
  if (!isJpeg(b)) return 1;
  var i = 2;
  while (i + 4 <= b.length && b[i] == 0xFF) {
    final m = b[i + 1];
    if (m == 0xDA || m == 0xD9) break;
    final len = (b[i + 2] << 8) | b[i + 3];
    if (m == 0xE1 && i + 4 + 6 <= b.length &&
        String.fromCharCodes(b.sublist(i + 4, i + 8)) == 'Exif') {
      final o = _exifOrientation(b, i + 10, i + 2 + len);
      if (o != null) return o;
    }
    i += 2 + len;
  }
  return 1;
}

int? _exifOrientation(Uint8List b, int tiff, int end) {
  try {
    if (tiff + 8 > end) return null;
    final le = b[tiff] == 0x49; // 'II'
    int u16(int o) => le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1];
    int u32(int o) => le
        ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
        : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    final ifd = tiff + u32(tiff + 4);
    if (ifd + 2 > end) return null;
    final n = u16(ifd);
    for (var e = 0; e < n; e++) {
      final p = ifd + 2 + e * 12;
      if (p + 12 > end) break;
      if (u16(p) == 0x0112) {
        final v = u16(p + 8);
        return (v >= 1 && v <= 8) ? v : null;
      }
    }
  } catch (_) {}
  return null;
}

/// A JPEG with NO metadata except a minimal EXIF block carrying the
/// orientation. Location, camera, time, XMP, IPTC and comments are gone.
Uint8List scrubJpeg(Uint8List b) {
  if (!isJpeg(b)) return b;
  final orient = jpegOrientation(b);
  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var i = 2;
  var wroteExif = false;
  void exif() {
    if (wroteExif || orient == 1) {
      wroteExif = true;
      return;
    }
    wroteExif = true;
    out.add([
      0xFF, 0xE1, 0x00, 0x22, // APP1, length 34
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // Exif\0\0
      0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // II*, IFD0 at 8
      0x01, 0x00, // one entry
      0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, orient, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, // no next IFD
    ]);
  }

  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return b; // not a sane JPEG: send as picked
    final m = b[i + 1];
    if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01) {
      out.add(b.sublist(i, i + 2));
      i += 2;
      continue;
    }
    if (m == 0xDA) {
      exif();
      out.add(Uint8List.sublistView(b, i)); // scan data to the end
      return out.toBytes();
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) return b;
    final keep = m == 0xE0 || // JFIF
        (m == 0xE2 && _startsWith(b, i + 4, 'ICC_PROFILE')) || // colours
        (m < 0xE0 && m != 0xFE); // tables, SOF, DRI … (not APPn / COM)
    if (keep) {
      if (m != 0xE0) exif(); // after JFIF, before everything else
      out.add(Uint8List.sublistView(b, i, i + 2 + len));
    }
    i += 2 + len;
  }
  return b;
}

bool _startsWith(Uint8List b, int o, String s) {
  if (o + s.length > b.length) return false;
  for (var k = 0; k < s.length; k++) {
    if (b[o + k] != s.codeUnitAt(k)) return false;
  }
  return true;
}

/// (width, height) from the JPEG frame header, as DISPLAYED (orientation
/// 5..8 swaps them), or null.
(int, int)? jpegSize(Uint8List b) {
  if (!isJpeg(b)) return null;
  var i = 2;
  while (i + 9 <= b.length && b[i] == 0xFF) {
    final m = b[i + 1];
    if ((m >= 0xD0 && m <= 0xD7) || m == 0x01) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    final sof = (m >= 0xC0 && m <= 0xCF) && m != 0xC4 && m != 0xC8 && m != 0xCC;
    if (sof) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      final o = jpegOrientation(b);
      return o >= 5 ? (h, w) : (w, h);
    }
    if (m == 0xDA) break;
    i += 2 + len;
  }
  return null;
}

/// PNG without text / EXIF / time chunks (tEXt, zTXt, iTXt, eXIf, tIME).
Uint8List scrubPng(Uint8List b) {
  if (!isPng(b)) return b;
  const drop = {'tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME'};
  final out = BytesBuilder(copy: false)..add(b.sublist(0, 8));
  var i = 8;
  while (i + 12 <= b.length) {
    final len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
    final end = i + 12 + len;
    if (len < 0 || end > b.length) return b;
    if (!drop.contains(type)) out.add(Uint8List.sublistView(b, i, end));
    i = end;
    if (type == 'IEND') break;
  }
  return out.toBytes();
}

/// A tiny (<= 32 px) PNG preview that travels INSIDE the E2E message, shown
/// blurred until the real photo has downloaded. '' if the phone can't decode.
Future<String> tinyThumbB64(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: kThumbEdge);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    if (png == null) return '';
    return base64Encode(png.buffer.asUint8List());
  } catch (e) {
    reportNonFatal('md1_thumb', e);
    return '';
  }
}

String newMediaId() => 'local-${DateTime.now().microsecondsSinceEpoch}';

// ---------------------------------------------------------------- permissions
/// Ask for a permission at the moment of use: our bn/en reason first, then
/// the system prompt; if it is blocked, an honest line + "Open settings".
Future<bool> ensureMediaPermission(BuildContext context, Permission p,
    {required String title, required String body, required String denied}) async {
  try {
    var st = await p.status;
    if (st.isGranted || st.isLimited) return true;
    if (!context.mounted) return false;
    final t = AppLocalizations.of(context);
    if (!st.isPermanentlyDenied && !st.isRestricted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1PermNotNow)),
            FilledButton(
                key: const Key('md1-perm-continue'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.md1PermContinue)),
          ],
        ),
      );
      if (go != true) return false;
      st = await p.request();
      if (st.isGranted || st.isLimited) return true;
    }
    if (!context.mounted) return false;
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(denied),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1PermNotNow)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.md1OpenSettings)),
        ],
      ),
    );
    if (open == true) await openAppSettings();
    return false;
  } catch (e) {
    reportNonFatal('md1_permission', e);
    return false;
  }
}

// ---------------------------------------------------------------- pickers
/// Pick (gallery) or take (camera) a photo and prepare it. null = cancelled.
/// Throws a [MediaPickError] with an honest code on failure.
Future<MediaDraft?> pickPhoto(BuildContext context, {required bool camera}) async {
  final t = AppLocalizations.of(context);
  if (camera) {
    final ok = await ensureMediaPermission(context, Permission.camera,
        title: t.md1PermCameraTitle, body: t.md1PermCameraBody, denied: t.md1PermDeniedCamera);
    if (!ok) return null;
  }
  final x = await ImagePicker().pickImage(
    source: camera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: kPhotoMaxEdge.toDouble(),
    maxHeight: kPhotoMaxEdge.toDouble(),
    imageQuality: kPhotoQuality,
    requestFullMetadata: false,
  );
  if (x == null) return null;
  return preparePhotoBytes(await x.readAsBytes(), x.name);
}

/// Shared by the picker and tests: scrub metadata, measure, thumbnail, and
/// write the app-owned copy that will be encrypted.
Future<MediaDraft> preparePhotoBytes(Uint8List raw, String pickedName) async {
  Uint8List bytes;
  String mime, ext;
  if (isJpeg(raw)) {
    bytes = scrubJpeg(raw);
    mime = 'image/jpeg';
    ext = 'jpg';
  } else if (isPng(raw)) {
    bytes = scrubPng(raw);
    mime = 'image/png';
    ext = 'png';
  } else {
    bytes = raw; // webp/gif: no EXIF GPS in what image_picker returns
    final lower = pickedName.toLowerCase();
    ext = lower.endsWith('.gif') ? 'gif' : lower.endsWith('.webp') ? 'webp' : 'jpg';
    mime = ext == 'gif' ? 'image/gif' : ext == 'webp' ? 'image/webp' : 'image/jpeg';
  }
  int? w, h;
  final sz = jpegSize(bytes);
  if (sz != null) {
    w = sz.$1;
    h = sz.$2;
  }
  final thumb = await tinyThumbB64(bytes);
  final id = newMediaId();
  final out = File('${(await MediaDirs.sub('out')).path}/$id.$ext');
  await out.writeAsBytes(bytes, flush: true);
  return MediaDraft(
    kind: 'photo',
    path: out.path,
    name: 'IMG-$id.$ext'.replaceFirst('local-', ''),
    mime: mime,
    size: bytes.length,
    width: w,
    height: h,
    thumbB64: thumb,
  );
}

class MediaPickError implements Exception {
  final String code; // too_big | failed
  final int size;
  const MediaPickError(this.code, [this.size = 0]);
}

/// The phone's document picker (any type). null = cancelled.
Future<MediaDraft?> pickDocument(int maxBytes) async {
  final r = await MsgNative.pickDocument(maxBytes);
  if (r == null) return null;
  if (r['error'] == 'too_big') {
    throw MediaPickError('too_big', (r['size'] as num?)?.toInt() ?? 0);
  }
  if (r['error'] != null) throw const MediaPickError('failed');
  final path = '${r['path'] ?? ''}';
  if (path.isEmpty || !File(path).existsSync()) throw const MediaPickError('failed');
  // move into our out/ dir (the native copy sits in the app cache)
  final id = newMediaId();
  final name = '${r['name'] ?? 'file'}';
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : 'bin';
  final dst = '${(await MediaDirs.sub('out')).path}/$id.${RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext) ? ext : 'bin'}';
  try {
    await File(path).rename(dst);
  } catch (_) {
    await File(path).copy(dst);
    await File(path).delete();
  }
  final size = File(dst).lengthSync();
  if (size > maxBytes) {
    File(dst).deleteSync();
    throw MediaPickError('too_big', size);
  }
  return MediaDraft(
    kind: 'document',
    path: dst,
    name: name,
    mime: '${r['mime'] ?? 'application/octet-stream'}',
    size: size,
  );
}
