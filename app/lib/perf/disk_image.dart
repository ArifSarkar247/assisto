// faststart (owner 10 Nov, item 6): a small on-disk picture cache for
// pictures that come from the server (Home Discover cards, sponsor cards).
// Before this, Image.network kept them only in memory, so every cold start
// downloaded them again and offline they were blank boxes.
//
// Pure Dart (package:http + path_provider), no plugin init at launch: the
// cache folder is resolved on the first picture. Files live in the app's
// temporary (cache) folder, so Android can clear them under storage pressure;
// at most [maxFiles] are kept (oldest removed). In Low-data mode an optional
// picture that is not on the phone yet is NOT downloaded (the widget's
// errorBuilder shows its icon instead).
import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'low_data.dart';

class DiskImageCache {
  DiskImageCache._();

  static const maxFiles = 300;
  static const maxBytes = 5 * 1024 * 1024; // one picture

  /// test seams
  static Future<Directory> Function() dirProvider = _defaultDir;
  static Future<Uint8List?> Function(String url) fetch = _defaultFetch;

  static Future<Directory>? _dir;
  static int _writes = 0;

  /// The latest background save (tests await it).
  @visibleForTesting
  static Future<void>? lastSave;

  static Future<Directory> _defaultDir() async {
    final base = await getTemporaryDirectory();
    final d = Directory('${base.path}/img_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<Uint8List?> _defaultFetch(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
    if (r.bodyBytes.length > maxBytes) return null;
    return r.bodyBytes;
  }

  static String fileName(String url) => '${sha1.convert(utf8.encode(url))}.img';

  /// Bytes for [url]: from the phone if saved, else downloaded and saved
  /// (unless [optional] and Low-data mode is on). Throws when unavailable
  /// (so the Image's errorBuilder runs).
  static Future<Uint8List> bytes(String url, {bool optional = true}) async {
    final dir = await (_dir ??= dirProvider());
    final f = File('${dir.path}/${fileName(url)}');
    try {
      if (await f.exists()) {
        final b = await f.readAsBytes();
        if (b.isNotEmpty) return b;
      }
    } catch (_) {}
    if (optional && LowDataMode.on.value) {
      throw StateError('low-data mode: not downloading $url');
    }
    final b = await fetch(url);
    if (b == null || b.isEmpty) throw StateError('picture unavailable');
    unawaited(lastSave = _save(dir, f, b));
    return b;
  }

  static Future<void> _save(Directory dir, File f, Uint8List b) async {
    try {
      final tmp = File('${f.path}.part');
      await tmp.writeAsBytes(b, flush: true);
      await tmp.rename(f.path);
      if (++_writes % 20 == 0) await prune(dir);
    } catch (_) {}
  }

  /// Keep at most [maxFiles] pictures (oldest by modified time go first).
  static Future<void> prune(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.img'))
          .cast<File>()
          .toList();
      if (files.length <= maxFiles) return;
      final stamped = <MapEntry<File, DateTime>>[];
      for (final f in files) {
        stamped.add(MapEntry(f, await f.lastModified()));
      }
      stamped.sort((a, b) => a.value.compareTo(b.value));
      for (final e in stamped.take(files.length - maxFiles)) {
        try {
          await e.key.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTest() {
    _dir = null;
    _writes = 0;
    dirProvider = _defaultDir;
    fetch = _defaultFetch;
  }
}

/// ImageProvider over [DiskImageCache] — a drop-in for `NetworkImage(url)`.
@immutable
class DiskCachedImage extends ImageProvider<DiskCachedImage> {
  const DiskCachedImage(this.url, {this.optional = true});

  final String url;

  /// Optional pictures are not downloaded in Low-data mode.
  final bool optional;

  @override
  Future<DiskCachedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<DiskCachedImage>(this);

  @override
  ImageStreamCompleter loadImage(DiskCachedImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1.0,
        debugLabel: url,
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final b = await DiskImageCache.bytes(url, optional: optional);
    return decode(await ui.ImmutableBuffer.fromUint8List(b));
  }

  @override
  bool operator ==(Object other) =>
      other is DiskCachedImage && other.url == url && other.optional == optional;

  @override
  int get hashCode => Object.hash(url, optional);

  @override
  String toString() => 'DiskCachedImage("$url")';
}
