/// Photo Studio — Dart side of the native parts (p2-photo).
///
/// `com.assisto/photo_native` (PhotoNativeChannel.kt): ONNX Runtime upscaler
/// and ML Kit face detection. Nothing here runs at app launch: the bridge is
/// created by Photo Studio and only probes the platform when the studio opens.
/// Every call is crash-guarded; a missing channel (tests, iOS, an older APK)
/// simply reports "not available" and the studio hides that option.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'ps_engines.dart';

class NativeFace {
  const NativeFace(this.box, this.points);
  final FaceBox box;

  /// Landmarks in ORIGINAL pixels, eyes first (see ps_identity.dart order).
  /// Empty when ML Kit could not place all eight.
  final List<math.Point<double>> points;
}

class NativeUpscaleResult {
  const NativeUpscaleResult(
      {required this.ok, this.path = '', this.w = 0, this.h = 0, this.ms = 0,
       this.ep = '', this.error = '', this.tiles = 0});
  final bool ok;
  final String path;
  final int w, h, ms;
  final String ep;

  /// Short native error code ('cancelled', 'model_shape', 'ort_session: …',
  /// 'decode', 'oom', …) — never a path or message text.
  final String error;
  final int tiles;
  bool get cancelled => error == 'cancelled';
}

/// d1-photo: background mask from the U²-Net-p model ([side]×[side], 0..255,
/// 255 = foreground/person).
class NativeMaskResult {
  const NativeMaskResult({required this.ok, this.mask, this.side = 0, this.ms = 0,
      this.error = ''});
  final bool ok;
  final Uint8List? mask;
  final int side, ms;
  final String error;
}

/// Seam over the platform channel (fakes in tests).
abstract class PhotoNative {
  /// Probe once (cheap: class lookups only). Safe to call many times.
  Future<void> probe();
  bool get upscaleAvailable;
  bool get facesAvailable;
  Future<List<NativeFace>?> faces(Uint8List encoded);
  Future<NativeUpscaleResult> upscale({
    required Uint8List encoded,
    required String modelPath,
    required int scale,
    required int tile,
    required int pad,
    required int maxInputLong,
    required int targetLong,
    List<FaceBox> faces = const [],
    double faceAi = 0.25,
    void Function(int done, int total)? onProgress,
  });

  /// d1-photo: run the background-mask model (fixed [side]×[side] input).
  Future<NativeMaskResult> segment(
      {required Uint8List encoded, required String modelPath, required int side});
  Future<void> cancel();
}

/// photoperf: frees the native parts (ML Kit detector, ONNX Runtime
/// sessions) when Photo Studio closes or the phone is low on memory. A
/// separate interface so test fakes of [PhotoNative] stay valid; they are
/// recreated lazily on the next use.
abstract class PhotoNativeRelease {
  Future<void> release();
}

/// photoperf2: band decoding of a big photo for the export (Android
/// BitmapRegionDecoder, EXIF orientation applied) — the full-size RGBA image
/// never exists at once. A separate interface (like [PhotoNativeRelease]) so
/// fakes of [PhotoNative] stay valid; null / any failure = the caller falls
/// back to decoding the whole photo.
abstract class PhotoNativeRegions {
  Future<PsRegionSource?> openRegions(Uint8List encoded);
}

/// One open photo. [band] decodes output rows [top, bottom) as raw RGBA
/// (8 bit, opaque, w*4 bytes per row) into a temp file and returns its path
/// (null = failed). The caller deletes the files; [close] frees the decoder.
abstract class PsRegionSource {
  int get w;
  int get h;
  Future<String?> band(int top, int bottom);
  Future<void> close();
}

/// Only JPEG and opaque PNG go through band decoding (PNG with an alpha
/// channel or tRNS transparency, WebP, HEIC, BMP keep the old path: the band
/// decoder premultiplies alpha).
bool psRegionFormatOk(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
  if (b.length < 33 || b[0] != 0x89 || b[1] != 0x50 || b[2] != 0x4E || b[3] != 0x47) return false;
  final ct = b[25];
  if (b[24] != 8 || !(ct == 0 || ct == 2) || b[28] != 0) return false; // 8-bit grey/RGB, not interlaced
  // no tRNS before the first IDAT
  var p = 8;
  while (p + 8 <= b.length) {
    final len = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    final t = String.fromCharCodes(b, p + 4, p + 8);
    if (t == 'tRNS') return false;
    if (t == 'IDAT' || t == 'IEND') return true;
    p += 12 + len;
  }
  return false;
}

/// photoperf2: write [bytes] in 1 MB pieces. `File.writeAsBytes` hands the
/// whole list to the IO thread as ONE native copy — for a 12 MP photo
/// (~34 MB PNG / ~5 MB JPEG) that was a second full copy of the file in
/// memory while the export started (2 GB run 40673196464: +170 MB peak).
Future<void> psWriteChunked(File f, Uint8List bytes, {int chunk = 1 << 20}) async {
  final raf = await f.open(mode: FileMode.write);
  try {
    for (var i = 0; i < bytes.length; i += chunk) {
      await raf.writeFrom(bytes, i, math.min(bytes.length, i + chunk));
    }
    await raf.flush();
  } finally {
    await raf.close();
  }
}

class _ChannelRegions implements PsRegionSource {
  _ChannelRegions(this._ch, this.handle, this.w, this.h, this._input);
  final MethodChannel _ch;
  final int handle;
  @override
  final int w, h;
  final String _input;
  int _n = 0;
  bool _closed = false;

  @override
  Future<String?> band(int top, int bottom) async {
    if (_closed) return null;
    try {
      final out = '$_input.b${_n++}';
      final r = await _ch.invokeMethod<Map>(
          'regionBand', {'handle': handle, 'top': top, 'bottom': bottom, 'out': out});
      if (r == null || r['ok'] != true || r['w'] != w || r['rows'] != bottom - top) {
        unawaited(File(out).delete().then((_) {}, onError: (_) {}));
        return null;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _ch.invokeMethod('regionClose', {'handle': handle}).timeout(const Duration(seconds: 5));
    } catch (_) {}
    unawaited(File(_input).delete().then((_) {}, onError: (_) {}));
  }
}

class ChannelPhotoNative implements PhotoNative, PhotoNativeRelease, PhotoNativeRegions {
  ChannelPhotoNative();
  static const _ch = MethodChannel('com.assisto/photo_native');
  bool _probed = false;
  bool _up = false, _faces = false, _regions = false;
  void Function(int, int)? _progress;
  final _faceCache = Expando<Future<List<NativeFace>?>>('ps_faces');

  @override
  bool get upscaleAvailable => _up;
  @override
  bool get facesAvailable => _faces;

  @override
  Future<void> probe() async {
    if (_probed) return;
    _probed = true;
    if (!Platform.isAndroid) return;
    try {
      final r = await _ch.invokeMethod<Map>('capabilities');
      _up = r?['upscale'] == true;
      _faces = r?['faces'] == true;
      _regions = r?['regions'] == true; // older APKs: absent -> old export path
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'upscaleProgress') {
          final a = call.arguments;
          if (a is Map) {
            _progress?.call((a['done'] as num?)?.toInt() ?? 0, (a['total'] as num?)?.toInt() ?? 0);
          }
        }
        return null;
      });
    } catch (_) {
      _up = false; // MissingPluginException: an APK without the native part
      _faces = false;
      _regions = false;
    }
  }

  Future<String> _tmp(Uint8List bytes, String tag) async {
    final d = await getTemporaryDirectory();
    final f = File('${d.path}/ps_${tag}_${DateTime.now().microsecondsSinceEpoch}.img');
    await psWriteChunked(f, bytes);
    return f.path;
  }

  @override
  Future<List<NativeFace>?> faces(Uint8List encoded) =>
      _faceCache[encoded] ??= _faces0(encoded);

  Future<List<NativeFace>?> _faces0(Uint8List encoded) async {
    if (!_faces) return null;
    String? path;
    try {
      path = await _tmp(encoded, 'face');
      final r = await _ch.invokeMethod<Map>('faces', {'path': path});
      if (r == null || r['ok'] != true) return null;
      final out = <NativeFace>[];
      for (final f in (r['faces'] as List? ?? const [])) {
        if (f is! Map) continue;
        final b = (f['box'] as List?)?.map((e) => (e as num).toDouble()).toList();
        if (b == null || b.length != 4) continue;
        final p = (f['points'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? const [];
        out.add(NativeFace(FaceBox(b[0], b[1], b[2], b[3]), [
          for (var i = 0; i + 1 < p.length; i += 2) math.Point(p[i], p[i + 1]),
        ]));
      }
      // stable order for before/after comparison: left to right
      out.sort((a, b) => (a.box.x + a.box.w / 2).compareTo(b.box.x + b.box.w / 2));
      return out;
    } catch (_) {
      return null;
    } finally {
      if (path != null) unawaited(File(path).delete().then((_) {}, onError: (_) {}));
    }
  }

  @override
  Future<NativeUpscaleResult> upscale({
    required Uint8List encoded,
    required String modelPath,
    required int scale,
    required int tile,
    required int pad,
    required int maxInputLong,
    required int targetLong,
    List<FaceBox> faces = const [],
    double faceAi = 0.25,
    void Function(int done, int total)? onProgress,
  }) async {
    if (!_up) return const NativeUpscaleResult(ok: false, error: 'unavailable');
    String? inPath;
    try {
      inPath = await _tmp(encoded, 'in');
      final out = '${(await getTemporaryDirectory()).path}/ps_ai_${DateTime.now().microsecondsSinceEpoch}.jpg';
      _progress = onProgress;
      final r = await _ch.invokeMethod<Map>('upscale', {
        'input': inPath,
        'model': modelPath,
        'out': out,
        'scale': scale,
        'tile': tile,
        'pad': pad,
        'maxInputLong': maxInputLong,
        'targetLong': targetLong,
        'faces': [for (final f in faces) f.toList()],
        'faceAi': faceAi,
      });
      if (r == null || r['ok'] != true) {
        return NativeUpscaleResult(ok: false, error: '${r?['error'] ?? 'failed'}');
      }
      return NativeUpscaleResult(
          ok: true,
          path: '${r['path']}',
          w: (r['w'] as num?)?.toInt() ?? 0,
          h: (r['h'] as num?)?.toInt() ?? 0,
          ms: (r['ms'] as num?)?.toInt() ?? 0,
          tiles: (r['tiles'] as num?)?.toInt() ?? 0,
          ep: '${r['ep'] ?? ''}');
    } catch (e) {
      // PlatformException / MissingPluginException: the TYPE only
      return NativeUpscaleResult(ok: false, error: 'channel: ${e.runtimeType}');
    } finally {
      _progress = null;
      if (inPath != null) unawaited(File(inPath).delete().then((_) {}, onError: (_) {}));
    }
  }

  @override
  Future<NativeMaskResult> segment(
      {required Uint8List encoded, required String modelPath, required int side}) async {
    if (!_up) return const NativeMaskResult(ok: false, error: 'unavailable');
    String? inPath;
    try {
      inPath = await _tmp(encoded, 'seg');
      final r = await _ch.invokeMethod<Map>('segment', {
        'input': inPath,
        'model': modelPath,
        'side': side,
      });
      if (r == null || r['ok'] != true) {
        return NativeMaskResult(ok: false, error: '${r?['error'] ?? 'failed'}');
      }
      final m = r['mask'];
      final sd = (r['side'] as num?)?.toInt() ?? 0;
      if (m is! Uint8List || sd <= 0 || m.length != sd * sd) {
        return const NativeMaskResult(ok: false, error: 'bad_mask');
      }
      return NativeMaskResult(ok: true, mask: m, side: sd, ms: (r['ms'] as num?)?.toInt() ?? 0);
    } catch (e) {
      return NativeMaskResult(ok: false, error: 'channel: ${e.runtimeType}');
    } finally {
      if (inPath != null) unawaited(File(inPath).delete().then((_) {}, onError: (_) {}));
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _ch.invokeMethod('cancel');
    } catch (_) {}
  }

  @override
  Future<PsRegionSource?> openRegions(Uint8List encoded) async {
    await probe();
    if (!_regions || !psRegionFormatOk(encoded)) return null;
    String? path;
    try {
      path = await _tmp(encoded, 'rgn');
      final r = await _ch.invokeMethod<Map>('regionOpen', {'input': path});
      final w = (r?['w'] as num?)?.toInt() ?? 0, h = (r?['h'] as num?)?.toInt() ?? 0;
      final handle = (r?['handle'] as num?)?.toInt() ?? 0;
      if (r == null || r['ok'] != true || w <= 0 || h <= 0 || handle <= 0) {
        unawaited(File(path).delete().then((_) {}, onError: (_) {}));
        return null;
      }
      return _ChannelRegions(_ch, handle, w, h, path);
    } catch (_) {
      if (path != null) unawaited(File(path).delete().then((_) {}, onError: (_) {}));
      return null;
    }
  }

  /// Only if the studio actually talked to the platform (never wakes ML Kit
  /// or ORT up just to close them); an older APK without the method = no-op.
  @override
  Future<void> release() async {
    if (!_probed || !Platform.isAndroid || !(_up || _faces || _regions)) return;
    try {
      await _ch.invokeMethod('release').timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}

/// No native part (tests / iOS / desktop): everything reports unavailable.
class NoPhotoNative implements PhotoNative {
  const NoPhotoNative();
  @override
  Future<void> probe() async {}
  @override
  bool get upscaleAvailable => false;
  @override
  bool get facesAvailable => false;
  @override
  Future<List<NativeFace>?> faces(Uint8List encoded) async => null;
  @override
  Future<NativeUpscaleResult> upscale({
    required Uint8List encoded,
    required String modelPath,
    required int scale,
    required int tile,
    required int pad,
    required int maxInputLong,
    required int targetLong,
    List<FaceBox> faces = const [],
    double faceAi = 0.25,
    void Function(int done, int total)? onProgress,
  }) async =>
      const NativeUpscaleResult(ok: false, error: 'unavailable');
  @override
  Future<NativeMaskResult> segment(
          {required Uint8List encoded, required String modelPath, required int side}) async =>
      const NativeMaskResult(ok: false, error: 'unavailable');
  @override
  Future<void> cancel() async {}
}

/// ML Kit face boxes (FACE-LOCK + skin mask).
class NativeFaceDetector implements FaceDetector {
  NativeFaceDetector(this.native);
  final PhotoNative native;
  @override
  bool get available => native.facesAvailable;
  @override
  Future<List<FaceBox>> detect(Uint8List encoded) async =>
      (await native.faces(encoded))?.map((f) => f.box).toList() ?? const [];
}

/// ML Kit landmarks for the identity check. A failed detection throws so
/// the guard reports "cannot verify" (never "no faces" by accident).
class NativeLandmarks implements LandmarkProvider {
  NativeLandmarks(this.native);
  final PhotoNative native;
  @override
  bool get available => native.facesAvailable;
  @override
  Future<List<List<math.Point<double>>>> landmarks(Uint8List encoded) async {
    final f = await native.faces(encoded);
    if (f == null) throw StateError('face detection failed');
    return [for (final x in f) x.points];
  }
}
