import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// x2-ticks (A3) — profile photos everywhere (chat list, chat header, contact
/// info, message notifications), CACHED and REFRESHED when the contact
/// changes their photo.
///
/// The server hands out avatars as short-lived signed media links
/// (/api/v1/m/<file>?e=<expiry>&s=<sig>, media_sign.py) whose query rotates
/// every hour, plus a stable `photo_v` tag (views_module5.x2_photo_v). The
/// CACHE KEY is the stable part — the file path (a fresh name per upload) or
/// `photo_v` — so:
///   * an hourly URL rotation never re-downloads or flickers;
///   * a NEW photo has a new key → fetched once, shown everywhere.
/// Bytes live in memory (LRU) and on disk (app support dir), so the
/// background isolate can draw the notification Person icon offline.

/// A relative server path ('/api/v1/m/…') → absolute on our API host.
String resolveAvatarUrl(String src) {
  final s = src.trim();
  if (s.startsWith('/')) return '${AppConfig.apiBase}$s';
  return s;
}

/// The stable cache key of an avatar URL (+ optional server `photo_v`).
String avatarStableKey(String url, {String photoV = ''}) {
  if (photoV.isNotEmpty) return 'v:$photoV';
  final u = resolveAvatarUrl(url);
  final q = u.indexOf('?');
  // signed media links: the ?e=&s= part rotates hourly, the path does not
  if (q > 0 && u.contains('/api/v1/m/')) return u.substring(0, q);
  return u;
}

int _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c & 0xff;
    h = (h * 0x01000193) & 0xffffffff;
    h ^= c >> 8;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

class AvatarCache {
  AvatarCache({http.Client? client, Future<Directory?> Function()? dir})
      : _client = client,
        _dirFn = dir ?? _defaultDir;
  static AvatarCache instance = AvatarCache();

  static const memCap = 80;
  final http.Client? _client;
  final Future<Directory?> Function() _dirFn;
  final LinkedHashMap<String, Uint8List> _mem = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _inflight = {};
  Directory? _dir;
  bool _dirTried = false;

  static Future<Directory?> _defaultDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/x2_avatars');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _cacheDir() async {
    if (_dirTried) return _dir;
    _dirTried = true;
    _dir = await _dirFn();
    return _dir;
  }

  String fileNameFor(String key) =>
      'a_${_fnv(key).toRadixString(16)}_${key.length}.img';

  Uint8List? peek(String key) {
    final b = _mem.remove(key);
    if (b != null) _mem[key] = b; // LRU touch
    return b;
  }

  void _put(String key, Uint8List b) {
    _mem.remove(key);
    _mem[key] = b;
    while (_mem.length > memCap) {
      _mem.remove(_mem.keys.first);
    }
  }

  /// Bytes for [url] under [key]: memory → disk → network (then stored).
  /// Null when there is no network copy either (caller shows initials).
  Future<Uint8List?> bytes(String url, String key,
      {Map<String, String>? headers}) {
    final m = peek(key);
    if (m != null) return Future.value(m);
    return _inflight[key] ??= _load(url, key, headers).whenComplete(() {
      _inflight.remove(key);
    });
  }

  Future<Uint8List?> _load(
      String url, String key, Map<String, String>? headers) async {
    final dir = await _cacheDir();
    final f = dir == null ? null : File('${dir.path}/${fileNameFor(key)}');
    try {
      if (f != null && f.existsSync()) {
        final b = await f.readAsBytes();
        if (b.isNotEmpty) {
          _put(key, b);
          return b;
        }
      }
    } catch (_) {}
    final abs = resolveAvatarUrl(url);
    if (!abs.startsWith('http')) return null;
    final c = _client ?? http.Client();
    try {
      final r = await c
          .get(Uri.parse(abs), headers: headers ?? AppConfig.authHeadersFor(abs))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      final b = r.bodyBytes;
      _put(key, b);
      try {
        await f?.writeAsBytes(b, flush: true);
      } catch (_) {}
      return b;
    } catch (_) {
      return null;
    } finally {
      if (_client == null) c.close();
    }
  }

  /// A disk file with the avatar cropped to a circle (PNG) for a
  /// notification Person icon / large icon. Null if unavailable.
  Future<String?> circleFile(String url, String key, {int size = 192}) async {
    try {
      final dir = await _cacheDir();
      if (dir == null) return null;
      final out = File('${dir.path}/c${size}_${fileNameFor(key)}.png');
      if (out.existsSync() && out.lengthSync() > 0) return out.path;
      final b = await bytes(url, key);
      if (b == null) return null;
      final png = await circleCropPng(b, size: size);
      await out.writeAsBytes(png ?? b, flush: true);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  int get memCount => _mem.length;
}

/// Crop image bytes to a circle and encode PNG (dart:ui — works in the FCM
/// background isolate too). Null on any decode failure.
Future<Uint8List?> circleCropPng(Uint8List bytes, {int size = 192}) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes,
        targetWidth: size, targetHeight: size);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    final s = size.toDouble();
    canvas.clipPath(ui.Path()..addOval(ui.Rect.fromLTWH(0, 0, s, s)));
    canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, s, s),
        ui.Paint()..filterQuality = ui.FilterQuality.medium);
    final out = await rec.endRecording().toImage(size, size);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// ImageProvider keyed by the STABLE avatar key (not the rotating URL), so
/// Flutter's image cache and our disk cache agree: same photo → no refetch,
/// new photo → new key → fresh image.
@immutable
class CachedAvatarImage extends ImageProvider<CachedAvatarImage> {
  final String url;
  final String cacheKey;
  final AvatarCache? cache;
  CachedAvatarImage(this.url, {String photoV = '', this.cache})
      : cacheKey = avatarStableKey(url, photoV: photoV);

  @override
  Future<CachedAvatarImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedAvatarImage>(this);

  @override
  ImageStreamCompleter loadImage(
          CachedAvatarImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final b = await (cache ?? AvatarCache.instance).bytes(url, cacheKey);
    if (b == null) throw StateError('avatar unavailable');
    final buf = await ui.ImmutableBuffer.fromUint8List(b);
    final codec = await decode(buf);
    final f = await codec.getNextFrame();
    return ImageInfo(image: f.image);
  }

  @override
  bool operator ==(Object other) =>
      other is CachedAvatarImage && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;
}
