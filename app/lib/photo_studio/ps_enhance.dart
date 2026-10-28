/// Photo Studio — the REAL one-tap enhance engine (p2-photo).
///
///  1. decode (at most the free-preview size when one is set);
///  2. optional AI restore/upscale: Real-ESRGAN realesr-general-x4v3
///     (denoise 0.5 blend) through ONNX Runtime on the phone (NNAPI when it
///     is faster and agrees with the CPU, else CPU/XNNPACK), tiled so memory
///     stays small. Any photo size (d1-photo): the model input is sized by a
///     time budget from this phone's measured speed ([AiPlan]), with per-tile
///     progress and cancel. Only LUMINANCE detail is taken
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
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:path_provider/path_provider.dart';

import 'ps_classic.dart';
import 'ps_engines.dart';
import 'ps_export.dart' show MarkPainter;
import 'ps_model.dart';
import 'ps_native.dart';
import 'ps_recipe.dart';
import 'ps_report.dart';
import 'ps_session.dart' show PngMeta;
import 'ps_tools.dart';

/// RGBA image in memory.
class RgbaImage {
  const RgbaImage(this.rgba, this.w, this.h);
  RgbaImage._empty()
      : rgba = Uint8List(0),
        w = 0,
        h = 0;
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

/// photoperf: a codec that can write a FAST (uncompressed) image for the
/// interactive proxy versions. Separate so codec fakes stay valid.
abstract class FastImageCodec {
  Future<Uint8List> encodeFast(RgbaImage img);
}

class UiImageCodec implements ImageCodecPort, FastImageCodec {
  const UiImageCodec();

  @override
  Future<Uint8List> encodeFast(RgbaImage img) async => encodeBmp(img.rgba, img.w, img.h);

  @override
  Future<({int w, int h})> size(Uint8List encoded) async {
    // photoperf: PNG/BMP headers are read directly (a 12 MP PNG was copied
    // into an engine buffer just to learn its size — several times per pick)
    if (encoded.length > 3 && (encoded[0] == 0x89 || encoded[0] == 0x42)) {
      final hs = psHeaderSize(encoded);
      if (hs != null && hs.w > 0 && hs.h > 0) return hs;
    }
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
///
/// d1-photo ROOT-CAUSE FIX: the AI step used to be offered only for photos
/// with a long edge ≤ 1600 px — every normal phone-camera photo (Realme 9i:
/// 4080×3060) silently got the classical pass only and the model was never
/// even downloaded. Now every photo can use it; the model input is sized by a
/// TIME BUDGET from the speed MEASURED on this phone (ms per 144-px tile), so
/// the AI step stays within ~[budgetMs] on a mid-range phone.
class AiPlan {
  const AiPlan(this.maxInputLong, this.targetLong, {this.tileCount = 0});
  final int maxInputLong;
  final int targetLong;

  /// Model tiles this plan runs (each 128 useful px, 144 with context).
  final int tileCount;

  /// First-run estimate for a mid-range phone (4× Cortex-A73 class, ORT CPU /
  /// XNNPACK): ~1.1 s per tile — ≈ 2× the 0.53 s measured on one Xeon
  /// 8259CL core (.phaseB/D1_EVAL.md). Replaced by the phone's own measured
  /// speed after the first run.
  static const defaultMsPerTile = 1100;

  /// AI-step budget (the whole light task must stay < 10 s; the classical
  /// pass + decode/encode take the rest).
  static const budgetMs = 7500;

  static int budgetTiles(int msPerTile) =>
      math.max(2, budgetMs ~/ math.max(50, msPerTile));

  /// [w]×[h] = the photo; [maxLongEdge] = free-preview cap; [maxTiles] from
  /// [budgetTiles]. Target: 2x the photo, at most [fullCap] (or the preview
  /// cap), never more than 4x the model input. Input ≤ 640 px and ≤ half the
  /// target, then shrunk until it fits [maxTiles].
  static AiPlan of(int w, int h,
      {int? maxLongEdge, int fullCap = 2560, int maxTiles = 1 << 20, int tile = 128}) {
    final long = math.max(1, math.max(w, h));
    var want = math.min(long * 2, fullCap);
    if (maxLongEdge != null) want = math.min(want, maxLongEdge);
    want = math.max(want, 1);
    var input = math.max(32, math.min(long, math.min(640, (want / 2).ceil())));
    while (input > 32 && tilesAt(w, h, input, tile) > maxTiles) {
      input = math.max(32, (input * 0.92).floor());
    }
    final target = math.min(want, input * 4);
    return AiPlan(input, target, tileCount: tilesAt(w, h, input, tile));
  }

  /// Tiles for the photo scaled so its long edge is [inputLong] (no upscale).
  static int tilesAt(int w, int h, int inputLong, int tile) {
    final long = math.max(w, h);
    final f = long <= inputLong ? 1.0 : inputLong / long;
    final iw = math.max(1, (w * f).round()), ih = math.max(1, (h * f).round());
    return tiles(iw, ih, tile);
  }

  /// Model tiles for an input of w×h at [tile] valid px per side.
  static int tiles(int w, int h, int tile) => ((w + tile - 1) ~/ tile) * ((h + tile - 1) ~/ tile);
}

/// Measured speed of THIS phone (persisted next to the model files).
class PerfStore {
  PerfStore(this.dir);
  final Future<Directory> Function() dir;
  int msPerTile = AiPlan.defaultMsPerTile;
  int maskMs = 1500;
  bool measured = false;
  bool _loaded = false;

  Future<File> _f() async => File('${(await dir()).path}/perf.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _f();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map) {
        final t = j['ms_per_tile'], m = j['mask_ms'];
        if (t is num && t > 0) {
          msPerTile = t.toInt().clamp(50, 20000);
          measured = true;
        }
        if (m is num && m > 0) maskMs = m.toInt().clamp(50, 60000);
      }
    } catch (_) {}
  }

  /// Exponential average of the real per-tile time (native ms / tiles).
  Future<void> addUpscale(int ms, int tiles) async {
    if (ms <= 0 || tiles <= 0) return;
    final v = (ms / tiles).round().clamp(50, 20000);
    msPerTile = measured ? ((msPerTile * 2 + v) / 3).round() : v;
    measured = true;
    await _save();
  }

  Future<void> addMask(int ms) async {
    if (ms <= 0) return;
    maskMs = ms.clamp(50, 60000);
    await _save();
  }

  Future<void> _save() async {
    try {
      final f = await _f();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({'ms_per_tile': msPerTile, 'mask_ms': maskMs}));
    } catch (_) {}
  }
}

/// The face in an AI result did not stay the same person -> result refused.
class PsIdentityRejected implements Exception {
  const PsIdentityRejected(this.outcome);
  final IdentityOutcome outcome;
}

/// The background mask found no clear person/subject (or would blur a face).
class PsNoSubject implements Exception {
  const PsNoSubject();
}

/// photoperf: the proxy + recipe side of the engine (see ps_recipe.dart).
/// A separate interface so fakes of [EnhanceEngine] keep working — the
/// controller falls back to the old full-size behaviour without it.
abstract class PsProxyEngine {
  /// The editing copy of [original] (long edge ≤ [maxLong]; the original
  /// itself when it is small enough).
  Future<PsProxy> makeProxy(Uint8List original, {required int maxLong});

  /// The recipe step of the last successful [EnhanceEngine.enhance] /
  /// [PhotoToolEngine.runTool] — null when that result cannot be re-rendered
  /// at full size (AI upscale, AI restore: they ARE the result).
  PsStep? get lastStep;

  /// Tools for a photo whose FULL size is [w]×[h] (the proxy may be smaller).
  Future<ToolsAvailability> toolsAt(int w, int h);

  /// Export: [steps] on the full-resolution [anchor] in a background
  /// isolate, corner mark from [mark] (null = clean), PNG with the AI note.
  /// Progress via [PhotoToolEngine.progress] (stage export); cancel stops it.
  Future<Uint8List> renderExport(Uint8List anchor, List<PsStep> steps,
      {MarkPainter? mark, String note = '', bool generated = false});

  /// Free what the studio holds natively (ML Kit, ONNX Runtime) and stop a
  /// running job.
  Future<void> release();
}

// Job builders: top-level so the closure sent to the worker isolate only
// captures plain data (never the engine / platform channels).
// The pixels travel as TransferableTypedData: one copy into a native
// buffer, then the caller drops its own (the 12 MP export would otherwise
// keep a second 48 MB copy alive in the UI isolate for the whole job).
RecipeOut Function(void Function(int, int)) _stepsJob(
        TransferableTypedData rgba, int w, int h, List<PsStep> steps) =>
    (p) => applySteps(rgba.materialize().asUint8List(), w, h, steps, progress: p);

Uint8List Function(void Function(int, int)) _exportJob(TransferableTypedData rgba, int w,
        int h, List<PsStep> steps, MarkPatch? mark, Uint8List extra) =>
    (p) => renderRecipePng(rgba.materialize().asUint8List(), w, h, steps,
        mark: mark, extraChunks: extra, progress: p);

class StudioEnhanceEngine implements EnhanceEngine, PhotoToolEngine, PsProxyEngine {
  StudioEnhanceEngine({
    required this.native,
    required this.guard,
    this.model = AiModelInfo.none,
    ModelDownloader? downloader,
    Future<Directory> Function()? modelDir,
    this.codec = const UiImageCodec(),
    this.runner = isolateClassicRunner,
    this.blurRunner = isolateBlurRunner,
    this.faceAi = 0.25,
    PsReporter? reporter,
    PsWorker? worker,
  })  : _downloader = downloader,
        _modelDir = modelDir ?? _defaultModelDir,
        report = reporter ?? defaultPsReporter,
        // tests that pass the synchronous classic runner also get inline
        // recipe work (no isolates under fake async)
        worker = worker ?? PsWorker(inline: identical(runner, syncClassicRunner)) {
    perf = PerfStore(_modelDir);
  }

  /// photoperf: the background isolate every heavy pixel job runs in.
  final PsWorker worker;
  PsStep? _lastStep;
  @override
  PsStep? get lastStep => _lastStep;

  /// Last pixel job timings (ms) for the perf report / diagnostics.
  final Map<String, int> timings = {};

  Future<Uint8List> _encodeOut(RgbaImage img) {
    final c = codec;
    return c is FastImageCodec ? (c as FastImageCodec).encodeFast(img) : codec.encodePng(img);
  }

  Future<RecipeOut> _run(Uint8List rgba, int w, int h, List<PsStep> steps, PsStage stage) async {
    try {
      final job = worker.inline
          ? (void Function(int, int) p) => applySteps(rgba, w, h, steps, progress: p)
          : _stepsJob(TransferableTypedData.fromList([rgba]), w, h, steps);
      return await worker.run(job,
          onProgress: (d, t) => progress?.call(PsProgress(stage, done: d, total: t)));
    } on PsWorkCancelled {
      throw const PsCancelled();
    }
  }

  @override
  Future<PsProxy> makeProxy(Uint8List original, {required int maxLong}) async {
    final sw = Stopwatch()..start();
    final s = await codec.size(original);
    if (math.max(s.w, s.h) <= maxLong) return PsProxy.identity(original, s.w, s.h);
    final img = await codec.decode(original, maxLong: maxLong);
    final bytes = await _encodeOut(img);
    timings['proxy_ms'] = sw.elapsedMilliseconds;
    return PsProxy(bytes: bytes, w: img.w, h: img.h, srcW: s.w, srcH: s.h);
  }

  @override
  Future<ToolsAvailability> toolsAt(int w, int h) => _toolsFor((w: w, h: h));

  @override
  Future<Uint8List> renderExport(Uint8List anchor, List<PsStep> steps,
      {MarkPainter? mark, String note = '', bool generated = false}) async {
    _cancelled = false;
    final sw = Stopwatch()..start();
    progress?.call(const PsProgress(PsStage.export, done: 0, total: 1000));
    var img = await codec.decode(anchor);
    timings['export_decode_ms'] = sw.elapsedMilliseconds;
    _checkCancel();
    final out = psStepsSize(img.w, img.h, steps);
    MarkPatch? patch;
    if (mark != null) {
      try {
        patch = await mark.paint(out.w, out.h);
      } catch (e) {
        report(PhotoStudioFailure('export', 'mark:${psErrorCode(e)}', model: model.version));
        rethrow; // never a free user's file without the corner mark
      }
    }
    final extra = note.isEmpty ? Uint8List(0) : PngMeta.aiChunks(note: note, generated: generated);
    final w = img.w, h = img.h;
    final Uint8List Function(void Function(int, int)) job;
    if (worker.inline) {
      final rgba = img.rgba;
      job = (p) => renderRecipePng(rgba, w, h, steps, mark: patch, extraChunks: extra, progress: p);
    } else {
      job = _exportJob(TransferableTypedData.fromList([img.rgba]), w, h, steps, patch, extra);
    }
    img = RgbaImage._empty(); // the UI isolate keeps no full-size copy
    try {
      final png = await worker.run(job,
          onProgress: (d, t) => progress?.call(PsProgress(PsStage.export, done: d, total: t)));
      timings['export_ms'] = sw.elapsedMilliseconds;
      return png;
    } on PsWorkCancelled {
      throw const PsCancelled();
    }
  }

  @override
  Future<void> release() async {
    _cancelled = true;
    worker.cancel();
    final n = native;
    if (n is PhotoNativeRelease) {
      try {
        await (n as PhotoNativeRelease).release();
      } catch (_) {}
    }
  }

  final PhotoNative native;
  final IdentityGuard guard;
  AiModelInfo model;
  final ImageCodecPort codec;
  final ClassicRunner runner;
  final BlurRunner blurRunner;

  /// Share of the AI detail allowed INSIDE face ellipses (face-lock): a
  /// general super-resolution model repaints small eyes/skin, so faces keep
  /// mostly their own pixels; colours always stay the original's.
  final double faceAi;

  /// d1-photo: every failure goes to the crash-report pipe (non-PII).
  final PsReporter report;
  late final PerfStore perf;

  @override
  PsProgressFn? progress;

  ModelDownloader? _downloader;
  final Future<Directory> Function() _modelDir;
  String? _modelPath;
  String? _segPath;
  AiState _ai = AiState.notOffered;
  double _progress = 0;
  EnhanceReport _last = EnhanceReport.none;
  Future<EnhanceAvailability>? _preparing;
  bool _cancelled = false;

  static bool _licenceAdded = false;

  /// BSD-3-Clause / Apache-2.0 ask for the notice wherever the weights are
  /// redistributed: added to the app's licence page (Settings -> About ->
  /// Licences) once the models are offered on this phone.
  static void _addLicence() {
    if (_licenceAdded) return;
    _licenceAdded = true;
    try {
      LicenseRegistry.addLicense(() => Stream.fromIterable(const [
            LicenseEntryWithLineBreaks(['Real-ESRGAN (realesr-general-x4v3 weights)'], _bsd3),
            LicenseEntryWithLineBreaks(['U-2-Net (u2netp weights)'], _u2netNotice),
          ]));
    } catch (_) {}
  }

  static Future<Directory> _defaultModelDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/photo_models');

  Future<ModelDownloader> _dl() async {
    final d = _downloader ??= ModelDownloader(http: IoRangeHttp(), dir: await _modelDir());
    d.keep = model.names;
    return d;
  }

  bool get _offered => model.usable && native.upscaleAvailable && guard.available;
  bool get _segOffered => model.segmentUsable && native.upscaleAvailable;

  EnhanceAvailability get _now => EnhanceAvailability(EnhanceState.ready,
      ai: _ai, progress: _progress, aiBytes: model.file?.size ?? 0, maxScale: 4);

  @override
  EnhanceReport get lastReport => _last;

  /// Can the AI step run for this photo? (any size since d1 — big photos run
  /// on a copy sized by the time budget; see [aiPlanFor]).
  Future<bool> aiEligible(Uint8List encoded) async {
    if (_ai == AiState.notOffered) return false;
    try {
      final s = await codec.size(encoded);
      return math.max(s.w, s.h) >= 16;
    } catch (_) {
      return false;
    }
  }

  bool aiEligibleSize(({int w, int h}) s) => _ai != AiState.notOffered && math.max(s.w, s.h) >= 16;

  /// The plan the AI step would use for this photo now (for the honest
  /// "works on a N px copy, about S s" line).
  Future<AiPlan?> aiPlanFor(Uint8List encoded, {int? maxLongEdge}) async {
    try {
      return await aiPlanForSize(await codec.size(encoded), maxLongEdge: maxLongEdge);
    } catch (_) {
      return null;
    }
  }

  /// photoperf: the same plan from a known size (no second header read).
  Future<AiPlan?> aiPlanForSize(({int w, int h}) s, {int? maxLongEdge}) async {
    try {
      await perf.load();
      return AiPlan.of(s.w, s.h,
          maxLongEdge: maxLongEdge,
          maxTiles: AiPlan.budgetTiles(perf.msPerTile),
          tile: model.tile - 2 * model.pad);
    } catch (_) {
      return null;
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
    await perf.load();
    if (_ai == AiState.downloading) return _now;
    final dl = await _dl();
    final p = await dl.cached(model.file!);
    _modelPath = p;
    if (model.segment != null) _segPath = await dl.cached(model.segment!);
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
        progress?.call(PsProgress(PsStage.download, done: got, total: total));
      });
      _ai = AiState.ready;
      _progress = 1;
    } catch (e) {
      _ai = AiState.failed;
      report(PhotoStudioFailure('download', _dlCode(e), model: model.version));
    }
    onProgress?.call(_now);
    return _now;
  }

  static String _dlCode(Object e) =>
      e is ModelDownloadFailed ? psErrorCode(e.reason.split(':').first) : psErrorCode(e);

  @override
  Future<void> cancel() async {
    _cancelled = true;
    worker.cancel(); // photoperf: a running pixel job stops NOW (isolate killed)
    try {
      await native.cancel();
    } catch (_) {}
  }

  void _checkCancel() {
    if (_cancelled) throw const PsCancelled();
  }

  void _tileProgress(PsStage st, int d, int t) {
    final left = math.max(0, t - d);
    progress?.call(PsProgress(st, done: d, total: t, etaMs: left * perf.msPerTile));
  }

  /// Run the x4 model natively; null = AI not usable (reported), throws
  /// [PsCancelled] on cancel.
  Future<NativeUpscaleResult?> _upscale(Uint8List encoded, List<NativeFace>? found,
      {required int maxInputLong, required int targetLong, required String stage}) async {
    final r = await native.upscale(
        faces: [for (final f in found ?? const <NativeFace>[]) f.box],
        faceAi: faceAi,
        encoded: encoded,
        modelPath: _modelPath!,
        scale: model.scale,
        tile: model.tile,
        pad: model.pad,
        maxInputLong: maxInputLong,
        targetLong: targetLong,
        onProgress: (d, t) => _tileProgress(PsStage.ai, d, t));
    if (r.cancelled || _cancelled) {
      if (r.ok && r.path.isNotEmpty) {
        unawaited(File(r.path).delete().then((_) {}, onError: (_) {}));
      }
      throw const PsCancelled();
    }
    if (!r.ok) {
      report(PhotoStudioFailure(stage, psErrorCode(r.error), model: model.version, ep: r.ep));
      return null;
    }
    await perf.addUpscale(r.ms, r.tiles);
    return r;
  }

  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) async {
    _cancelled = false;
    _lastStep = null;
    final sw = Stopwatch()..start();
    var aiUsed = false, aiRejected = false, aiFailed = false;
    var ep = '';
    progress?.call(const PsProgress(PsStage.analyse));
    final src = await codec.size(encoded);
    RgbaImage? base;
    // faces (ML Kit, cached per photo): skin mask + AI face-lock
    List<NativeFace>? found;
    try {
      found = await native.faces(encoded);
    } catch (_) {}
    // ---- AI restore/upscale (optional, guarded)
    if (req.ai && _ai == AiState.ready && _modelPath != null) {
      await perf.load();
      final plan = AiPlan.of(src.w, src.h,
          maxLongEdge: req.maxLongEdge,
          maxTiles: AiPlan.budgetTiles(perf.msPerTile),
          tile: model.tile - 2 * model.pad);
      final r = await _upscale(encoded, found,
          maxInputLong: plan.maxInputLong, targetLong: plan.targetLong, stage: 'upscale');
      if (r == null) {
        aiFailed = true;
      } else {
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
    _checkCancel();
    progress?.call(const PsProgress(PsStage.classic));
    base ??= await codec.decode(encoded, maxLong: req.maxLongEdge);
    final faces = _classicFaces(found);
    // photoperf: the classical pass runs as a recipe step (its measured
    // statistics are kept, so the export re-renders the SAME look at full
    // size); the AI result itself cannot be re-rendered -> no step then.
    final r = await _run(base.rgba, base.w, base.h,
        [ClassicStep(ClassicParams.of(req.strength), faces: faces)], PsStage.classic);
    _checkCancel();
    final out = await _encodeOut(RgbaImage(r.rgba, r.w, r.h));
    sw.stop();
    _lastStep = aiUsed ? null : r.steps.single;
    _last = EnhanceReport(
        aiUsed: aiUsed, aiRejected: aiRejected, aiFailed: aiFailed,
        ms: sw.elapsedMilliseconds, ep: ep);
    return out;
  }

  static List<ClassicFace> _classicFaces(List<NativeFace>? found) => [
        for (final x in found ?? const <NativeFace>[])
          ClassicFace(x.box.x, x.box.y, x.box.w, x.box.h)
      ];

  // ------------------------------------------------------------------ tools
  @override
  Future<ToolsAvailability> tools(Uint8List encoded) async {
    try {
      return await _toolsFor(await codec.size(encoded));
    } catch (e) {
      report(PhotoStudioFailure('tool', psErrorCode(e), model: model.version));
      return const ToolsAvailability(classic: true);
    }
  }

  Future<ToolsAvailability> _toolsFor(({int w, int h}) s) async {
    try {
      await native.probe();
      await perf.load();
      final tile = model.tile - 2 * model.pad;
      final up2 = _offered ? UpscalePlan.of(s.w, s.h, 2, tile: tile) : null;
      final up4 = _offered ? UpscalePlan.of(s.w, s.h, 4, tile: tile) : null;
      return ToolsAvailability(
        upscale2x: up2 != null,
        upscale4x: up4 != null,
        classic: true,
        bgBlur: _segOffered,
        needsUpscaleModel: _offered && _modelPath == null,
        needsMaskModel: _segOffered && _segPath == null,
        etaMs: {
          if (up2 != null) PsTool.upscale2x: up2.tiles * perf.msPerTile,
          if (up4 != null) PsTool.upscale4x: up4.tiles * perf.msPerTile,
          if (_segOffered) PsTool.bgBlur: perf.maskMs + 1200,
        },
      );
    } catch (e) {
      report(PhotoStudioFailure('tool', psErrorCode(e), model: model.version));
      return const ToolsAvailability(classic: true);
    }
  }

  @override
  Future<bool> prepareTool(PsTool tool) async {
    if (tool.usesAi) {
      final a = await prepare();
      return a.ai == AiState.ready;
    }
    if (tool != PsTool.bgBlur) return true;
    if (!_segOffered) return false;
    if (_segPath != null) return true;
    try {
      _segPath = await (await _dl()).ensure(model.segment!, onProgress: (got, total) {
        progress?.call(PsProgress(PsStage.download, done: got, total: total));
      });
      return true;
    } catch (e) {
      report(PhotoStudioFailure('download', _dlCode(e), model: '${model.version}/seg'));
      return false;
    }
  }

  @override
  Future<Uint8List> runTool(PsTool tool, Uint8List encoded, {int? maxLongEdge}) async {
    _cancelled = false;
    _lastStep = null;
    try {
      switch (tool) {
        case PsTool.upscale2x:
        case PsTool.upscale4x:
          return await _runUpscale(encoded, tool == PsTool.upscale2x ? 2 : 4);
        case PsTool.denoise:
        case PsTool.lowLight:
          return await _runClassic(encoded,
              tool == PsTool.denoise ? ClassicParams.denoiseTool : ClassicParams.lowLightTool,
              maxLongEdge: maxLongEdge);
        case PsTool.bgBlur:
          return await _runBlur(encoded, maxLongEdge: maxLongEdge);
      }
    } on PsCancelled {
      rethrow;
    } on PsIdentityRejected {
      rethrow;
    } on PsNoSubject {
      rethrow;
    } on PhotoStudioFailure {
      rethrow;
    } catch (e) {
      final f = PhotoStudioFailure('tool', '${tool.wire}:${psErrorCode(e)}', model: model.version);
      report(f);
      throw f;
    }
  }

  Future<Uint8List> _runUpscale(Uint8List encoded, int factor) async {
    if (_modelPath == null) throw const PhotoStudioFailure('tool', 'model_missing');
    final s = await codec.size(encoded);
    final plan = UpscalePlan.of(s.w, s.h, factor, tile: model.tile - 2 * model.pad);
    if (plan == null) throw const PhotoStudioFailure('tool', 'too_big');
    List<NativeFace>? found;
    try {
      found = await native.faces(encoded);
    } catch (_) {}
    final r = await _upscale(encoded, found,
        maxInputLong: plan.inputLong, targetLong: plan.targetLong, stage: 'upscale_tool');
    if (r == null) throw PhotoStudioFailure('upscale_tool', 'failed', model: model.version);
    final bytes = await File(r.path).readAsBytes();
    unawaited(File(r.path).delete().then((_) {}, onError: (_) {}));
    final v = await guard.check(encoded, bytes);
    if (!v.pass) throw PsIdentityRejected(v.outcome);
    return bytes;
  }

  /// [maxLongEdge]: free users' preview size (photoperf: tools honour it
  /// like enhance does; the export re-renders the recipe at full size).
  Future<Uint8List> _runClassic(Uint8List encoded, ClassicParams p, {int? maxLongEdge}) async {
    progress?.call(const PsProgress(PsStage.classic));
    final sw = Stopwatch()..start();
    List<NativeFace>? found;
    try {
      found = await native.faces(encoded);
    } catch (_) {}
    timings['faces_ms'] = sw.elapsedMilliseconds;
    final base = await codec.decode(encoded, maxLong: maxLongEdge);
    timings['decode_ms'] = sw.elapsedMilliseconds - timings['faces_ms']!;
    final t0 = sw.elapsedMilliseconds;
    final r = await _run(base.rgba, base.w, base.h,
        [ClassicStep(p, faces: _classicFaces(found))], PsStage.classic);
    timings['pixels_ms'] = sw.elapsedMilliseconds - t0;
    _checkCancel();
    final t1 = sw.elapsedMilliseconds;
    final out = await _encodeOut(RgbaImage(r.rgba, r.w, r.h));
    timings['encode_ms'] = sw.elapsedMilliseconds - t1;
    _lastStep = r.steps.single;
    return out;
  }

  /// Longest edge the blur composite works at (memory/time bound).
  static const blurMaxLong = 2048;

  Future<Uint8List> _runBlur(Uint8List encoded, {int? maxLongEdge}) async {
    if (_segPath == null) throw const PhotoStudioFailure('tool', 'mask_model_missing');
    progress?.call(const PsProgress(PsStage.mask));
    final m = await native.segment(encoded: encoded, modelPath: _segPath!, side: model.segSide);
    _checkCancel();
    if (!m.ok || m.mask == null) {
      final f = PhotoStudioFailure('segment', psErrorCode(m.error), model: '${model.version}/seg');
      report(f);
      throw f;
    }
    await perf.addMask(m.ms);
    final cov = maskCoverage(m.mask!);
    if (cov < 0.03 || cov > 0.97) throw const PsNoSubject();
    // identity guard for blur: every detected face must be INSIDE the kept
    // (sharp, original-pixel) area — otherwise the face would be blurred.
    List<NativeFace>? found;
    try {
      found = await native.faces(encoded);
    } catch (_) {}
    for (final f in found ?? const <NativeFace>[]) {
      final cx = ((f.box.x + f.box.w / 2) * m.side).floor().clamp(0, m.side - 1);
      final cy = ((f.box.y + f.box.h / 2) * m.side).floor().clamp(0, m.side - 1);
      if (m.mask![cy * m.side + cx] < 160) throw const PsNoSubject();
    }
    progress?.call(const PsProgress(PsStage.classic));
    final cap = maxLongEdge == null ? blurMaxLong : math.min(blurMaxLong, maxLongEdge);
    final base = await codec.decode(encoded, maxLong: cap);
    final r = await _run(base.rgba, base.w, base.h, [BlurStep(m.mask!, m.side)], PsStage.classic);
    _checkCancel();
    final out = await _encodeOut(RgbaImage(r.rgba, r.w, r.h));
    _lastStep = r.steps.single;
    return out;
  }
}

/// Background blur off the UI thread (tests pass a synchronous runner).
typedef BlurRunner = Future<Uint8List> Function(
    Uint8List rgba, int w, int h, Uint8List mask, int mw, int mh);

Future<Uint8List> isolateBlurRunner(
    Uint8List rgba, int w, int h, Uint8List mask, int mw, int mh) {
  final t = TransferableTypedData.fromList([rgba]);
  return Isolate.run(() => blurBackgroundRgba(t.materialize().asUint8List(), w, h, mask, mw, mh));
}

Future<Uint8List> syncBlurRunner(
        Uint8List rgba, int w, int h, Uint8List mask, int mw, int mh) async =>
    blurBackgroundRgba(rgba, w, h, mask, mw, mh);

const _u2netNotice = '''U-2-Net (u2netp weights), Copyright (c) 2020 Xuebin Qin.
Licensed under the Apache License, Version 2.0. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0 . Distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND. Used unmodified
(ONNX export) by Assisto Photo Studio for the background-blur mask.''';

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
