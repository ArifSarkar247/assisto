import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../../services/error_report.dart';
import '../msg_native.dart';
import 'media_prep.dart';
import 'media_store.dart';
import 'video_ctl.dart';

/// mc-media2 — preparing a VIDEO to send, on the phone, before encryption.
///
/// The clip is sent as picked (no transcoding: no heavy encoder on low-RAM
/// phones), under its own owner-editable cap (default 32 MB). Before it is
/// encrypted, the container's metadata boxes that can carry the recording
/// PLACE and device details (`udta` — e.g. Android's ©xyz location — and
/// `meta` inside `moov` / `trak`) are renamed to `free` and blanked in
/// place: players skip them, the picture and sound are untouched.

const _kStrip = {'udta', 'meta'};

int _u32(Uint8List b) => (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

/// Rename location-bearing metadata boxes of an MP4/3GP/MOV file to `free`,
/// IN PLACE. Returns how many were neutralised (0 = none / not an MP4).
Future<int> scrubMp4InPlace(File f) async {
  RandomAccessFile? opened;
  var n = 0;
  try {
    final raf = opened = await f.open(mode: FileMode.append);
    final len = await raf.length();
    Future<void> walk(int start, int end, int depth) async {
      var pos = start;
      while (pos + 8 <= end) {
        await raf.setPosition(pos);
        final hdr = await raf.read(8);
        if (hdr.length < 8) return;
        var size = _u32(hdr);
        final type = latin1.decode(hdr.sublist(4, 8), allowInvalid: true);
        var head = 8;
        if (size == 1) {
          final ext = await raf.read(8);
          if (ext.length < 8) return;
          size = (_u32(ext.sublist(0, 4)) << 32) | _u32(ext.sublist(4, 8));
          head = 16;
        } else if (size == 0) {
          size = end - pos;
        }
        if (size < head || pos + size > end) return; // damaged: stop, never guess
        if (depth > 0 && _kStrip.contains(type)) {
          // rename to `free` AND blank the payload: the place must not stay
          // readable in the bytes either
          await raf.setPosition(pos + 4);
          await raf.writeFrom(latin1.encode('free'));
          await raf.setPosition(pos + head);
          var left = size - head;
          final zeros = Uint8List(64 * 1024);
          while (left > 0) {
            final k = left < zeros.length ? left : zeros.length;
            await raf.writeFrom(zeros, 0, k);
            left -= k;
          }
          n++;
        } else if (type == 'moov' || type == 'trak') {
          await walk(pos + head, pos + size, depth + 1);
        }
        pos += size;
      }
    }

    await walk(0, len, 0);
  } catch (e) {
    reportNonFatal('mc2_mp4_scrub', e);
  } finally {
    await opened?.close();
  }
  return n;
}

String videoMime(String ext) => switch (ext) {
      '3gp' => 'video/3gpp',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'mkv' => 'video/x-matroska',
      _ => 'video/mp4',
    };

/// Seam for tests (image_picker's video picker).
Future<String?> Function() pickVideoPath = () async {
  final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
  return x?.path;
};

/// Pick a video from the gallery (the Photo Picker: no media permission).
/// null = cancelled; throws [MediaPickError] ('too_big' / 'failed').
Future<MediaDraft?> pickVideo(int maxBytes) async {
  final path = await pickVideoPath();
  if (path == null) return null;
  final src = File(path);
  if (!src.existsSync()) throw const MediaPickError('failed');
  final size = src.lengthSync();
  if (size > maxBytes) {
    try {
      src.deleteSync();
    } catch (_) {}
    throw MediaPickError('too_big', size);
  }
  return prepareVideoFile(src);
}

/// Shared by the picker and tests: move into our out/ dir, strip metadata,
/// read size / duration / a tiny first frame.
Future<MediaDraft> prepareVideoFile(File src) async {
  final id = newMediaId();
  final dot = src.path.lastIndexOf('.');
  var ext = dot > 0 ? src.path.substring(dot + 1).toLowerCase() : 'mp4';
  if (!RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) ext = 'mp4';
  final dst = '${(await MediaDirs.sub('out')).path}/$id.$ext';
  try {
    await src.rename(dst);
  } catch (_) {
    await src.copy(dst);
    try {
      await src.delete();
    } catch (_) {}
  }
  final out = File(dst);
  await scrubMp4InPlace(out);
  int? w, h, ms;
  var thumb = '';
  final meta = await MsgNative.videoMeta(dst);
  if (meta != null) {
    int? i(Object? v) => v is num && v > 0 ? v.toInt() : null;
    w = i(meta['w']);
    h = i(meta['h']);
    ms = i(meta['ms']);
    final png = meta['png'];
    if (png is Uint8List && png.isNotEmpty && png.length < 32 * 1024) thumb = base64Encode(png);
  }
  if (ms == null) {
    final s = await VideoCtls.probe(out);
    if (s != null) {
      ms = s.duration.inMilliseconds > 0 ? s.duration.inMilliseconds : null;
      if (w == null && s.size.width > 0) {
        w = s.size.width.round();
        h = s.size.height.round();
      }
    }
  }
  final name = 'VID-${id.replaceFirst('local-', '')}.$ext';
  return MediaDraft(
    kind: 'video',
    path: dst,
    name: name,
    mime: videoMime(ext),
    size: out.lengthSync(),
    width: w,
    height: h,
    durationMs: ms,
    thumbB64: thumb,
  );
}
