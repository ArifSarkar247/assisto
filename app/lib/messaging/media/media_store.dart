import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/error_report.dart';
import '../msg_native.dart';
import 'media_api.dart';
import 'media_crypto.dart';
import 'media_descriptor.dart';

/// md1 — where decrypted media + upload scratch files live: the app's
/// private support directory (never shared storage; other apps cannot read
/// it). "Save" / "Share" copy out on the user's tap only.
class MediaDirs {
  MediaDirs._();

  /// Tests point this at a temp dir.
  static String? override;
  static String? _root;

  static Future<String> root() async {
    final o = override;
    if (o != null) return o;
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    _root = '${base.path}/md1';
    return _root!;
  }

  /// Synchronous view (null until [root] resolved once).
  static String? get rootSync => override ?? _root;

  static Future<Directory> sub(String name) async {
    final d = Directory('${await root()}/$name');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }
}

/// Device-level auto-download policy (WhatsApp-like): on Wi-Fi everything
/// downloads by itself; on mobile data nothing does unless the user turns a
/// kind on (Settings → Storage and data).
class MediaPrefs {
  MediaPrefs._();
  static const kWifi = 'md1_auto_wifi';
  static String mobileKey(String kind) => 'md1_auto_mobile_$kind';

  static Future<SharedPreferences?> _p() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> wifiAuto() async => (await _p())?.getBool(kWifi) ?? true;
  static Future<void> setWifiAuto(bool v) async => (await _p())?.setBool(kWifi, v);
  static Future<bool> mobileAuto(String kind) async =>
      (await _p())?.getBool(mobileKey(kind)) ?? false;
  static Future<void> setMobileAuto(String kind, bool v) async =>
      (await _p())?.setBool(mobileKey(kind), v);

  /// Seam for tests: is the current network metered? null = unknown.
  static Future<bool?> Function() metered = MsgNative.isMetered;

  static Future<bool> shouldAutoDownload(String kind) async {
    try {
      final m = await metered();
      if (m == false) return await wifiAuto();
      return await mobileAuto(kind); // metered or unknown: be careful with data
    } catch (_) {
      return false;
    }
  }
}

/// Download state of one blob, for the bubbles.
class MediaDl {
  final double progress; // 0..1, -1 = decrypting
  final String error; // '' | gone | network | damaged
  const MediaDl({this.progress = 0, this.error = ''});
}

/// md1 — received media: signed download -> sha256 check -> decrypt on the
/// phone -> private cache file. One download per blob at a time.
class MediaCache {
  MediaCache({MediaTransport? transport})
      : transport = transport ?? HttpMediaTransport();

  static MediaCache instance = MediaCache();

  MediaTransport transport;

  /// ref -> state while downloading / after a failure.
  final ValueNotifier<Map<String, MediaDl>> states =
      ValueNotifier<Map<String, MediaDl>>(const {});

  final Map<String, Future<File?>> _inflight = {};
  final Set<String> _cancel = {};

  static String fileName(String ref, String ext) => '$ref.$ext';

  Future<File> fileFor(MediaDescriptor d) async =>
      File('${(await MediaDirs.sub('files')).path}/${fileName(d.ref, d.ext)}');

  /// The decrypted copy when this phone already has it (sync, for build()).
  File? cachedSync(MediaDescriptor d) {
    final r = MediaDirs.rootSync;
    if (r == null) return null;
    final f = File('$r/files/${fileName(d.ref, d.ext)}');
    return f.existsSync() ? f : null;
  }

  Future<File?> cached(MediaDescriptor d) async {
    try {
      final f = await fileFor(d);
      return f.existsSync() ? f : null;
    } catch (e) {
      reportNonFatal('md1_cache_dir', e);
      return null;
    }
  }

  /// The sender's own file becomes the cache copy (no re-download).
  Future<void> adopt(String ref, String ext, String srcPath) async {
    try {
      final dst = File('${(await MediaDirs.sub('files')).path}/${fileName(ref, ext)}');
      final src = File(srcPath);
      if (!src.existsSync()) return;
      try {
        await src.rename(dst.path);
      } catch (_) {
        await src.copy(dst.path);
        await src.delete();
      }
      _set(ref, null);
    } catch (e, st) {
      reportNonFatal('md1_adopt', e, st);
    }
  }

  void _set(String ref, MediaDl? s) {
    final m = Map<String, MediaDl>.from(states.value);
    if (s == null) {
      m.remove(ref);
    } else {
      m[ref] = s;
    }
    states.value = m;
  }

  void cancel(String ref) {
    if (_inflight.containsKey(ref)) _cancel.add(ref);
  }

  /// Download + decrypt. Returns the file, or null (state carries the
  /// honest reason). Never throws.
  Future<File?> fetch(MediaDescriptor d) {
    final have = cachedSync(d);
    if (have != null) return Future.value(have);
    return _inflight[d.ref] ??= _fetch(d).whenComplete(() {
      _inflight.remove(d.ref);
      _cancel.remove(d.ref);
    });
  }

  Future<File?> _fetch(MediaDescriptor d) async {
    final ref = d.ref;
    _set(ref, const MediaDl(progress: 0));
    File? tmp;
    try {
      final out = await fileFor(d);
      if (out.existsSync()) {
        _set(ref, null);
        return out;
      }
      tmp = File('${(await MediaDirs.sub('dl')).path}/$ref.enc');
      final u = await transport.downloadUrl(ref);
      final url = '${u['url'] ?? ''}';
      if (url.isEmpty) throw const MediaHttpError(404);
      final sink = tmp.openWrite();
      try {
        final total = d.size > 0 ? d.size : ((u['size'] as num?)?.toInt() ?? 0);
        await transport.download(url, sink,
            cancelled: () => _cancel.contains(ref),
            onBytes: (got) {
              if (total > 0) {
                _set(ref, MediaDl(progress: (got / total).clamp(0, 1).toDouble()));
              }
            });
      } finally {
        await sink.close();
      }
      _set(ref, const MediaDl(progress: -1));
      final part = '${out.path}.part';
      final ok = await openFile(tmp.path, part, d.key, d.nonce, d.sha256);
      if (!ok) {
        _set(ref, const MediaDl(error: 'damaged'));
        return null;
      }
      await File(part).rename(out.path);
      _set(ref, null);
      return out;
    } on MediaHttpError catch (e) {
      if (e.reason == 'cancelled') {
        _set(ref, null);
      } else {
        _set(ref, MediaDl(error: e.status == 404 ? 'gone' : 'network'));
      }
      return null;
    } catch (e) {
      _set(ref, const MediaDl(error: 'network'));
      return null;
    } finally {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (e) {
        reportNonFatal('md1_dl_cleanup', e);
      }
    }
  }
}

/// Seal a plain file for upload (background isolate). Exposed for tests.
Future<MediaSeal> sealForUpload(String plainPath, String encPath) =>
    sealFile(plainPath, encPath);
