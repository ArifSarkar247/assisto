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

class ChannelPhotoNative implements PhotoNative {
  ChannelPhotoNative();
  static const _ch = MethodChannel('com.assisto/photo_native');
  bool _probed = false;
  bool _up = false, _faces = false;
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
    }
  }

  Future<String> _tmp(Uint8List bytes, String tag) async {
    final d = await getTemporaryDirectory();
    final f = File('${d.path}/ps_${tag}_${DateTime.now().microsecondsSinceEpoch}.img');
    await f.writeAsBytes(bytes, flush: true);
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
