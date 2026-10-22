/// Photo Studio — the REAL one-tap enhance engine (p2-photo).
///
///  1. decode (at most the free-preview size when one is set);
///  2. optional AI restore/upscale: Real-ESRGAN realesr-general-x4v3
///     (denoise 0.5 blend) through ONNX Runtime on the phone (NNAPI when it
///     is faster and agrees with the CPU, else CPU/XNNPACK), tiled so memory
///     stays small. Only for small or old photos (long edge ≤
///     [StudioEnhanceEngine.aiMaxSourceLong]). Only LUMINANCE detail is taken
///     from the model (colours stay the original's) and faces get just
///     [StudioEnhanceEngine.faceAi] of it (face-lock). The result must still
///     pass the IDENTITY CHECK against the original or it is thrown away and
///     the classical-only result is used;
///  3. the instant classical pipeline (ps_classic.dart) in a background
///     isolate, with the ML Kit face boxes for the skin mask;
///  4. encode PNG.
/// Works offline once the model is on the phone; nothing is sent anywhere.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:path_provider/path_provider.dart';

import 'ps_classic.dart';
import 'ps_engines.dart';
import 'ps_model.dart';
import 'ps_native.dart';

/// RGBA image in memory.
class RgbaImage {
  const RgbaImage(this.rgba, this.w, this.h);
  final Uint8List rgba;
  final int w, h;
  int get long => math.max(w, h);
}

/// Decode/encode seam (dart:ui on the phone; fakes in tests).
abstract class ImageCodecPort {
  /// Decode, shrinking so the long edge is at most [maxLong] when given.
  Future<RgbaImage> decode(Uint8List encoded, {int? maxLong});
  Future<({int w, int h})> size(Uint8List encoded);
  Future<Uint8List> encodePng(RgbaImage img);
}

class UiImageCodec implements ImageCodecPort {
  const UiImageCodec();

  @override
  Future<({int w, int h})> size(Uint8List encoded) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(encoded);
    final d = await ui.ImageDescriptor.encoded(buf);
    final r = (w: d.width, h: d.height);
    d.dispose();
    buf.dispose();
    return r;
  }

  @override
  Future<RgbaImage> decode(Uint8List encoded, {int? maxLong}) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(encoded);
    final d = await ui.ImageDescriptor.encoded(buf);
    int? tw, th;
    final long = math.max(d.width, d.height);
    if (maxLong != null && long > maxLong) {
      final f = maxLong / long;
      tw = math.max(1, (d.width * f).round());
      th = math.max(1, (d.height * f).round());
    }
    final codec = await d.instantiateCodec(targetWidth: tw, targetHeight: th);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final out = RgbaImage(bd!.buffer.asUint8List(), img.width, img.height);
    img.dispose();
    codec.dispose();
    d.dispose();
    buf.dispose();
    return out;
  }

  @override
  Future<Uint8List> encodePng(RgbaImage img) async {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(img.rgba, img.w, img.h, ui.PixelFormat.rgba8888, c.complete);
    final im = await c.future;
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    return bd!.buffer.asUint8List();
  }
}

/// Runs the classical pipeline off the UI thread. Tests pass a synchronous
/// runner.
typedef ClassicRunner = Future<Uint8List> Function(
    Uint8List rgba, int w, int h, ClassicParams p, List<ClassicFace> faces);

Future<Uint8List> isolateClassicRunner(
    Uint8List rgba, int w, int h, ClassicParams p, List<ClassicFace> faces) {
  final t = TransferableTypedData.fromList([rgba]);
  return Isolate.run(() {
    final data = t.materialize().asUint8List();
    final out = enhanceClassic(data, w, h, p, faces: faces);
    return out;
  });
}

Future<Uint8List> syncClassicRunner(
        Uint8List rgba, int w, int h, ClassicParams p, List<ClassicFace> faces) async =>
    enhanceClassic(rgba, w, h, p, faces: faces);

/// Pure sizing rules for the AI step (mirrored by PhotoNativeChannel.kt,
/// which obeys the numbers it is given).
class AiPlan {
  const AiPlan(this.maxInputLong, this.targetLong);
  final int maxInputLong;
  final int targetLong;

  /// [srcLong] = original long edge; [maxLongEdge] = free-preview cap.
  /// Target: 2x the original, at most 2560 px (or the preview cap). The
  /// model input is at most 640 px on the long edge (≈ 20–30 tiles), and
  /// never more than half the target (the x4 output is then shrunk).
  static AiPlan of(int srcLong, {int? maxLongEdge, int fullCap = 2560}) {
    var target = math.min(srcLong * 2, fullCap);
    if (maxLongEdge != null) target = math.min(target, maxLongEdge);
    target = math.max(target, 1);
    final input = math.max(32, math.min(srcLong, math.min(640, (target / 2).ceil())));
    return AiPlan(input, target);
  }

  /// Model tiles for an input of w×h at [tile] valid px per side.
  static int tiles(int w, int h, int tile) => ((w + tile - 1) ~/ tile) * ((h + tile - 1) ~/ tile);
}

class StudioEnhanceEngine implements EnhanceEngine {
  StudioEnhanceEngine({
    required this.native,
    required this.guard,
    this.model = AiModelInfo.none,
    ModelDownloader? downloader,
    Future<Directory> Function()? modelDir,
    this.codec = const UiImageCodec(),
    this.runner = isolateClassicRunner,
    this.aiMaxSourceLong = 1600,
    this.faceAi = 0.25,
  })  : _downloader = downloader,
        _modelDir = modelDir ?? _defaultModelDir;

  final PhotoNative native;
  final IdentityGuard guard;
  AiModelInfo model;
  final ImageCodecPort codec;
  final ClassicRunner runner;

  /// Above this the photo already has enough pixels: the AI step is not
  /// offered (it would upscale a downscaled copy).
  final int aiMaxSourceLong;

  /// Share of the AI detail allowed INSIDE face ellipses (face-lock): a
  /// general super-resolution model repaints small eyes/skin, so faces keep
  /// mostly their own pixels; colours always stay the original's.
  final double faceAi;
  ModelDownloader? _downloader;
  final Future<Directory> Function() _modelDir;
  String? _modelPath;
  AiState _ai = AiState.notOffered;
  double _progress = 0;
  EnhanceReport _last = EnhanceReport.none;
  Future<EnhanceAvailability>? _preparing;

  static bool _licenceAdded = false;

  /// BSD-3-Clause asks for the notice wherever the weights are
  /// redistributed: added to the app's licence page (Settings -> About ->
  /// Licences) once the model is offered on this phone.
  static void _addLicence() {
    if (_licenceAdded) return;
    _licenceAdded = true;
    try {
      LicenseRegistry.addLicense(() => Stream.value(const LicenseEntryWithLineBreaks(
          ['Real-ESRGAN (realesr-general-x4v3 weights)'], _bsd3)));
    } catch (_) {}
  }

  static Future<Directory> _defaultModelDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/photo_models');

  Future<ModelDownloader> _dl() async =>
      _downloader ??= ModelDownloader(http: IoRangeHttp(), dir: await _modelDir());

  bool get _offered => model.usable && native.upscaleAvailable && guard.available;

  EnhanceAvailability get _now => EnhanceAvailability(EnhanceState.ready,
      ai: _ai, progress: _progress, aiBytes: model.file?.size ?? 0, maxScale: 2);

  @override
  EnhanceReport get lastReport => _last;

  /// Is the AI step useful for this photo? (small / old photos only)
  Future<bool> aiEligible(Uint8List encoded) async {
    if (_ai != AiState.ready && _ai != AiState.needsDownload && _ai != AiState.failed &&
        _ai != AiState.downloading) {
      return false;
    }
    try {
      final s = await codec.size(encoded);
      return math.max(s.w, s.h) <= aiMaxSourceLong;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<EnhanceAvailability> availability() async {
    await native.probe();
    if (!_offered) {
      _ai = AiState.notOffered;
      return _now;
    }
    _addLicence();
    if (_ai == AiState.downloading) return _now;
    final p = await (await _dl()).cached(model.file!);
    _modelPath = p;
    _ai = p != null ? AiState.ready : (_ai == AiState.failed ? AiState.failed : AiState.needsDownload);
    return _now;
  }

  @override
  Future<EnhanceAvailability> prepare({void Function(EnhanceAvailability)? onProgress}) =>
      _preparing ??= _prepare(onProgress).whenComplete(() => _preparing = null);

  Future<EnhanceAvailability> _prepare(void Function(EnhanceAvailability)? onProgress) async {
    await native.probe();
    if (!_offered) {
      _ai = AiState.notOffered;
      return _now;
    }
    _ai = AiState.downloading;
    _progress = 0;
    onProgress?.call(_now);
    try {
      _modelPath = await (await _dl()).ensure(model.file!, onProgress: (got, total) {
        _progress = total <= 0 ? 0 : (got / total).clamp(0, 1).toDouble();
        onProgress?.call(_now);
      });
      _ai = AiState.ready;
      _progress = 1;
    } catch (_) {
      _ai = AiState.failed;
    }
    onProgress?.call(_now);
    return _now;
  }

  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) async {
    final sw = Stopwatch()..start();
    var aiUsed = false, aiRejected = false;
    var ep = '';
    final src = await codec.size(encoded);
    final srcLong = math.max(src.w, src.h);
    RgbaImage? base;
    // faces (ML Kit, cached per photo): skin mask + AI face-lock
    List<NativeFace>? found;
    try {
      found = await native.faces(encoded);
    } catch (_) {}
    // ---- AI restore/upscale (optional, guarded)
    if (req.ai && _ai == AiState.ready && _modelPath != null && srcLong <= aiMaxSourceLong) {
      final plan = AiPlan.of(srcLong, maxLongEdge: req.maxLongEdge);
      final r = await native.upscale(
          faces: [for (final f in found ?? const <NativeFace>[]) f.box],
          faceAi: faceAi,
          encoded: encoded,
          modelPath: _modelPath!,
          scale: model.scale,
          tile: model.tile,
          pad: model.pad,
          maxInputLong: plan.maxInputLong,
          targetLong: plan.targetLong);
      if (r.ok) {
        final aiBytes = await File(r.path).readAsBytes();
        unawaited(File(r.path).delete().then((_) {}, onError: (_) {}));
        final v = await guard.check(encoded, aiBytes);
        if (v.pass) {
          base = await codec.decode(aiBytes);
          aiUsed = true;
          ep = r.ep;
        } else {
          aiRejected = true;
        }
      }
    }
    base ??= await codec.decode(encoded, maxLong: req.maxLongEdge);
    final faces = [
      for (final x in found ?? const <NativeFace>[])
        ClassicFace(x.box.x, x.box.y, x.box.w, x.box.h)
    ];
    final out = await runner(base.rgba, base.w, base.h, ClassicParams.of(req.strength), faces);
    final png = await codec.encodePng(RgbaImage(out, base.w, base.h));
    sw.stop();
    _last = EnhanceReport(aiUsed: aiUsed, aiRejected: aiRejected, ms: sw.elapsedMilliseconds, ep: ep);
    return png;
  }
}

const _bsd3 = '''BSD 3-Clause License

Copyright (c) 2021, Xintao Wang
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.''';
