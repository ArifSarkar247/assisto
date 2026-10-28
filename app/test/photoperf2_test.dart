// photoperf2 (owner: "Photo Studio edit and memory on a 2 GB phone"):
//  * 1280 px editing proxy on ≤ 2 GB phones — rules, and the look stays the
//    same (PSNR vs the 1600 px path > 30 dB) with the export unchanged;
//  * faster classic filters (one-sweep box filters, exact strip context) —
//    same results as the plain filters;
//  * the export decoded in BANDS natively (BitmapRegionDecoder seam): the
//    same pixels as the whole-image path, and every failure falls back to it
//    (format, older APK, size mismatch, a band error); cancel; corner mark;
//  * chained tool on an AI-enhanced version and Premium batch export through
//    the recipe path.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:assisto/photo_studio/ps_classic.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_enhance.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_model.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/photo_studio/ps_recipe.dart';
import 'package:assisto/photo_studio/ps_report.dart';
import 'package:assisto/photo_studio/ps_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'd1_photo_test.dart' as d1 show MemHttp;
import 'photoperf_test.dart' as pp;
import 'ps1_fakes.dart';

// ------------------------------------------------------------------ fakes
/// The native band decoder over a known photo: band() writes the requested
/// rows as raw RGBA to a temp file (what RegionBands.kt does).
class RegionNative extends pp.PerfNative implements PhotoNativeRegions {
  RegionNative(this.rgba, this.w, this.h,
      {this.openNull = false, this.failAt = -1, this.reportW, this.onBand});
  final Uint8List rgba;
  final int w, h;
  final bool openNull;
  final int failAt;
  final int? reportW;
  final void Function(int i)? onBand;
  int opens = 0, bands = 0, closes = 0;
  final files = <String>[];
  final ranges = <(int, int)>[];

  @override
  Future<PsRegionSource?> openRegions(Uint8List encoded) async {
    opens++;
    if (openNull) return null;
    return _Src(this);
  }
}

class _Src implements PsRegionSource {
  _Src(this.n);
  final RegionNative n;
  final dir = Directory.systemTemp.createTempSync('ppband');
  @override
  int get w => n.reportW ?? n.w;
  @override
  int get h => n.h;
  @override
  Future<String?> band(int top, int bottom) async {
    final i = n.bands++;
    n.ranges.add((top, bottom));
    n.onBand?.call(i);
    if (i == n.failAt) return null;
    final f = File('${dir.path}/b$i.raw')
      ..writeAsBytesSync(Uint8List.sublistView(n.rgba, top * n.w * 4, bottom * n.w * 4));
    n.files.add(f.path);
    return f.path;
  }

  @override
  Future<void> close() async => n.closes++;
}

class FailMark implements MarkPainter {
  @override
  Future<MarkPatch?> paint(int w, int h) async => throw StateError('mark');
}

/// "AI": shrink to the model input, nearest x2, fit to the target, a touch
/// greener (so a re-run classic pass is visible) — deterministic.
({Uint8List rgba, int w, int h}) fakeAi(Uint8List rgba, int w, int h, int maxIn, int target) {
  final a = downscaleRgba(rgba, w, h, maxIn);
  final uw = a.w * 2, uh = a.h * 2;
  final up = Uint8List(uw * uh * 4);
  for (var y = 0; y < uh; y++) {
    for (var x = 0; x < uw; x++) {
      final si = ((y ~/ 2) * a.w + x ~/ 2) * 4, di = (y * uw + x) * 4;
      up[di] = a.rgba[si];
      up[di + 1] = math.min(255, a.rgba[si + 1] + 5);
      up[di + 2] = a.rgba[si + 2];
      up[di + 3] = 255;
    }
  }
  final o = downscaleRgba(up, uw, uh, target);
  return (rgba: o.rgba, w: o.w, h: o.h);
}

class AiNative extends pp.PerfNative {
  int upscales = 0;
  final targets = <int>[], inputs = <int>[];
  @override
  bool get upscaleAvailable => true;
  @override
  Future<List<NativeFace>?> faces(Uint8List encoded) async => const []; // guard: noFaces = pass
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
    upscales++;
    targets.add(targetLong);
    inputs.add(maxInputLong);
    final s = await pp.RawCodec().decode(encoded);
    final r = fakeAi(s.rgba, s.w, s.h, maxInputLong, targetLong);
    final f = File('${Directory.systemTemp.createTempSync('ppai').path}/o.raw')
      ..writeAsBytesSync(pp.enc(r.rgba, r.w, r.h));
    return NativeUpscaleResult(ok: true, path: f.path, w: r.w, h: r.h, ep: 'cpu', ms: 900, tiles: 2);
  }
}

class _Picker implements PhotoPicker {
  _Picker(this.one);
  final Uint8List one;
  @override
  Future<Uint8List?> pick({required bool camera}) async => one;
  @override
  Future<List<Uint8List>> pickMany({int limit = 10}) async => [one];
}

Float32List naiveBox(Float32List src, int w, int h, int r) {
  final t = Float32List(w * h), o = Float32List(w * h);
  final win = 2 * r + 1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var k = -r; k <= r; k++) {
        s += src[y * w + (x + k).clamp(0, w - 1)];
      }
      t[y * w + x] = s / win;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var k = -r; k <= r; k++) {
        s += t[(y + k).clamp(0, h - 1) * w + x];
      }
      o[y * w + x] = s / win;
    }
  }
  return o;
}

double maxAbs(Float32List a, Float32List b) {
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    m = math.max(m, (a[i] - b[i]).abs());
  }
  return m;
}

void main() {
  final reports = <PhotoStudioFailure>[];
  final ram0 = PhotoStudioController.deviceRam;
  tearDown(() {
    PhotoStudioController.proxyLongOverride = null;
    PhotoStudioController.deviceRam = ram0;
  });

  StudioEnhanceEngine engOf(PhotoNative n, {PsWorker? worker}) {
    reports.clear();
    return StudioEnhanceEngine(
        native: n,
        guard: IdentityGuard(landmarks: NativeLandmarks(n)),
        codec: pp.RawCodec(),
        runner: syncClassicRunner,
        blurRunner: syncBlurRunner,
        worker: worker,
        modelDir: () async => throw StateError('no model dir in tests'),
        reporter: reports.add);
  }

  // ============================================================== proxy rules
  group('1280 px proxy on ≤ 2 GB phones', () {
    test('rules: ≤ 2 GB / low-RAM 1280, ≤ 3 GB 1600, bigger 2400; export strips', () {
      expect(psProxyLong(ramMb: 1967, lowRam: false), 1280); // the 2 GB emulator
      expect(psProxyLong(ramMb: 1800, lowRam: false), 1280);
      expect(psProxyLong(ramMb: psRam2GbMb, lowRam: false), 1280);
      expect(psProxyLong(ramMb: 2800, lowRam: false), 1600); // 3 GB
      expect(psProxyLong(ramMb: 7600, lowRam: true), 1280); // Android low-RAM flag
      expect(psProxyLong(ramMb: 3900, lowRam: false), 2400);
      expect(psProxyLong(ramMb: 0, lowRam: false), 2400); // unknown
      expect(psExportStripRows(ramMb: 1967, lowRam: false), 128);
      expect(psExportStripRows(ramMb: 2800, lowRam: false), 128);
      expect(psExportStripRows(ramMb: 7600, lowRam: false), 256);
      // free users stay at the server preview size
      expect(psInteractiveLong(proxyLong: 1280, free: true, previewMaxPx: 1024), 1024);
    });

    test('controller: a 2 GB phone edits at 1280 px', () async {
      PhotoStudioController.deviceRam = () => (ramMb: 1967, lowRam: false);
      final b = FakePsBackend(entryDue: false, free: false);
      final n = pp.PerfNative();
      final c = PhotoStudioController(PsDeps(
          backend: b, ads: FakeAds(b), native: n, engine: engOf(n), guard: const IdentityGuard(),
          sink: pp.BytesSink(), renderer: FakeRenderer(), secure: FakeSecure(),
          picker: _Picker(Uint8List(0)), reporter: (_) {}));
      await c.init();
      expect(c.free, isFalse);
      expect(c.interactiveLong, 1280);
      PhotoStudioController.deviceRam = () => (ramMb: 2800, lowRam: false);
      expect(c.interactiveLong, 1600);
    });

    test('same look: 1280 preview vs 1600 preview > 30 dB; export unchanged', () {
      const fw = 2000, fh = 1500;
      final full = pp.scene(fw, fh, seed: 11);
      const faces = [ClassicFace(0.35, 0.2, 0.25, 0.35)];
      for (final p in [ClassicParams.lowLightTool, ClassicParams.natural]) {
        final p16 = downscaleRgba(full, fw, fh, 1600), p12 = downscaleRgba(full, fw, fh, 1280);
        final r16 = applySteps(p16.rgba, p16.w, p16.h, [ClassicStep(p, faces: faces)]);
        final r12 = applySteps(p12.rgba, p12.w, p12.h, [ClassicStep(p, faces: faces)]);
        expect((r12.w, r12.h), (1280, 960));
        final shrunk = downscaleRgba(r16.rgba, r16.w, r16.h, 1280);
        final dbPrev = psnr(shrunk.rgba, r12.rgba);
        // the export: the recipe measured on each proxy, run on the original
        final e16 = applySteps(full, fw, fh, r16.steps).rgba;
        final e12 = applySteps(full, fw, fh, r12.steps).rgba;
        final dbExp = psnr(e16, e12);
        // ignore: avoid_print
        print('photoperf2 1280 vs 1600 (lift ${p.lift}): preview $dbPrev dB, export $dbExp dB');
        expect(dbPrev, greaterThan(30), reason: 'the 1280 preview looks like the 1600 one');
        expect(dbExp, greaterThan(40), reason: 'the export does not depend on the proxy size');
      }
    });
  });

  // ============================================================== filters
  group('faster classic filters', () {
    test('boxBlur (edge-split, one multiply) == the plain clamped box filter', () {
      final r = math.Random(3);
      for (final (w, h, rad) in [(97, 41, 3), (7, 5, 3), (40, 30, 1), (300, 9, 8), (5, 50, 0)]) {
        final src = Float32List.fromList(List.generate(w * h, (_) => r.nextDouble()));
        final out = Float32List(w * h), tmp = Float32List(w * h);
        boxBlur(src, out, tmp, w, h, rad);
        expect(maxAbs(out, rad == 0 ? src : naiveBox(src, w, h, rad)), lessThan(1e-5),
            reason: '$w x $h r$rad');
      }
    });

    test('boxBlur2 (two planes / mean of squares in one sweep) == two boxBlurs', () {
      final r = math.Random(4);
      for (final (w, h, rad) in [(120, 33, 4), (6, 6, 3)]) {
        final a = Float32List.fromList(List.generate(w * h, (_) => r.nextDouble()));
        final b = Float32List.fromList(List.generate(w * h, (_) => r.nextDouble()));
        final sq = Float32List.fromList([for (final v in a) v * v]);
        final oa = Float32List(w * h), ob = Float32List(w * h);
        final t1 = Float32List(w * h), t2 = Float32List(w * h);
        boxBlur2(a, b, oa, ob, t1, t2, w, h, rad);
        expect(maxAbs(oa, naiveBox(a, w, h, rad)), lessThan(1e-5));
        expect(maxAbs(ob, naiveBox(b, w, h, rad)), lessThan(1e-5));
        boxBlur2(a, null, oa, ob, t1, t2, w, h, rad, sq: true);
        expect(maxAbs(oa, naiveBox(a, w, h, rad)), lessThan(1e-5));
        expect(maxAbs(ob, naiveBox(sq, w, h, rad)), lessThan(1e-5));
      }
    });

    test('exact strip context: any strip height gives the one-strip result (±1)', () {
      const w = 240, h = 610;
      final img = pp.scene(w, h, seed: 8);
      const faces = [ClassicFace(0.25, 0.3, 0.5, 0.4)];
      final one = enhanceClassic(img, w, h, ClassicParams.strong, faces: faces, stripRows: 10000);
      for (final sr in [16, 64, 128, 256]) {
        final k = enhanceClassic(img, w, h, ClassicParams.strong, faces: faces, stripRows: sr);
        var md = 0;
        for (var i = 0; i < one.length; i++) {
          md = math.max(md, (one[i] - k[i]).abs());
        }
        expect(md, lessThanOrEqualTo(1), reason: 'strip $sr');
      }
      // and it is smaller than the old generous sum (+8): fewer rows per strip
      final sc = 4000 / 1000.0;
      final old = 2 * ((2 * sc).round() * 2 + (1.2 * sc).round() + 2) + 8;
      expect(classicPad(4000, 3000, const []), lessThan(old));
      expect(classicPad(4000, 3000, const []), 32);
    });
  });

  // ============================================================== band export
  group('export decoded in bands (native BitmapRegionDecoder seam)', () {
    const w = 300, h = 700;
    final img = pp.scene(w, h, seed: 5);
    final px = downscaleRgba(img, w, h, 150);
    final step = applySteps(px.rgba, px.w, px.h, const [
      ClassicStep(ClassicParams.lowLightTool, faces: [ClassicFace(0.3, 0.2, 0.3, 0.2)])
    ]).steps.single as ClassicStep;
    final mark = pp.FakeMark();
    // the whole-image export (the old path) with the same strips
    Uint8List want() => renderRecipePng(img, w, h, [step],
        mark: MarkPatch(Uint8List.fromList(List.filled(10 * 6 * 4, 255)), w - 12, h - 8, 10, 6),
        stripRows: 64);

    StudioEnhanceEngine bandEng(PhotoNative n, {PsWorker? worker}) => engOf(n, worker: worker)
      ..exportStripRows = 64
      ..regionBandRows = 128;

    test('bands == the whole-image export, pixel for pixel; files cleaned; decoder closed',
        () async {
      final n = RegionNative(img, w, h);
      final e = bandEng(n);
      final png = await e.renderExport(pp.enc(img, w, h), [step], mark: mark, note: 'n');
      expect(e.lastExportPath, 'bands');
      expect(n.bands, 6); // 700 rows / 128 per band (multiples of the 64-row strips)
      final pad = classicPad(w, h, step.faces);
      expect(n.ranges.first, (0, 128 + pad), reason: 'each band brings its context rows');
      expect(n.closes, 1);
      final r = pp.readPng(png);
      expect((r.w, r.h), (w, h));
      expect(r.rgba, pp.readPng(want()).rgba);
      expect(mark.sizes.last, (w, h));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(n.files.where((f) => File(f).existsSync()), isEmpty);
      expect(reports, isEmpty);
    });

    test('real isolates: bands read from files in the workers, same pixels', () async {
      final n = RegionNative(img, w, h);
      final e = bandEng(n, worker: PsWorker());
      final png = await e.renderExport(pp.enc(img, w, h), [step], mark: mark);
      expect(e.lastExportPath, 'bands');
      expect(pp.readPng(png).rgba, pp.readPng(want()).rgba);
    });

    test('fallbacks: not offered / a band fails / size mismatch -> whole-image path, same file',
        () async {
      for (final n in [
        RegionNative(img, w, h, openNull: true),
        RegionNative(img, w, h, failAt: 2),
        RegionNative(img, w, h, reportW: w + 1),
      ]) {
        final e = bandEng(n);
        final png = await e.renderExport(pp.enc(img, w, h), [step], mark: mark);
        expect(e.lastExportPath, 'full');
        expect(pp.readPng(png).rgba, pp.readPng(want()).rgba);
        if (n.failAt >= 0) {
          expect(reports.single.code, startsWith('region:'));
          expect(n.closes, 1);
        }
        if (n.reportW != null) expect(reports.single.code, 'region_size');
      }
      // an engine on a native part without band decoding (older APK / fakes)
      final e = bandEng(pp.PerfNative());
      await e.renderExport(pp.enc(img, w, h), [step]);
      expect(e.lastExportPath, 'full');
      // chained steps keep the whole-image path
      final e2 = bandEng(RegionNative(img, w, h));
      await e2.renderExport(pp.enc(img, w, h), [step, step]);
      expect(e2.lastExportPath, 'full');
    });

    test('cancel during the band export: cancelled, no file left, decoder closed', () async {
      late StudioEnhanceEngine e;
      final n = RegionNative(img, w, h, onBand: (i) {
        if (i == 1) unawaited(e.cancel());
      });
      e = bandEng(n);
      await expectLater(e.renderExport(pp.enc(img, w, h), [step]), throwsA(isA<PsCancelled>()));
      expect(n.closes, 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(n.files.where((f) => File(f).existsSync()), isEmpty);
    });

    test('a failing corner mark is never skipped (no fallback to an unmarked file)', () async {
      final e = bandEng(RegionNative(img, w, h));
      await expectLater(e.renderExport(pp.enc(img, w, h), [step], mark: FailMark()),
          throwsA(isA<StateError>()));
      expect(reports.single.code, startsWith('mark:'));
    });

    test('formats: JPEG and opaque 8-bit PNG only', () {
      final rgb = (PngStreamEncoder(4, 2)..addRows(Uint8List(4 * 2 * 4)..fillRange(0, 32, 255), 2))
          .close();
      expect(psRegionFormatOk(rgb), isTrue);
      final rgba = (PngStreamEncoder(4, 2)..addRows(Uint8List(4 * 2 * 4), 2)).close(); // alpha 0
      expect(psRegionFormatOk(rgba), isFalse);
      // tRNS (palette / colour-key transparency) before the image data
      final trns = BytesBuilder()
        ..add(rgb.sublist(0, 33))
        ..add(pngChunk('tRNS', const [0, 0, 0, 0, 0, 0]))
        ..add(rgb.sublist(33));
      expect(psRegionFormatOk(trns.toBytes()), isFalse);
      final interlaced = Uint8List.fromList(rgb)..[28] = 1;
      expect(psRegionFormatOk(interlaced), isFalse);
      expect(psRegionFormatOk(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16])), isTrue);
      expect(psRegionFormatOk(encodeBmp(Uint8List(4), 1, 1)), isFalse);
      expect(psRegionFormatOk(Uint8List(3)), isFalse);
    });

    test('band plan: whole strips, covers every row, at most 8 bands', () {
      for (final (hh, sr) in [(3000, 128), (3000, 256), (700, 64), (100, 128), (9000, 128)]) {
        final b = psRegionBands(hh, sr);
        expect(b.first.$1, 0);
        expect(b.last.$2, hh);
        for (var i = 0; i < b.length; i++) {
          expect(b[i].$1 % sr, 0);
          if (i > 0) expect(b[i].$1, b[i - 1].$2);
        }
        expect(b.length, lessThanOrEqualTo(8));
      }
      expect(psRegionBands(3000, 128).length, 6); // 512-row bands
    });

    test('runPool: ordered results, progress to 1000, failures stop it', () async {
      final wk = PsWorker();
      final seen = <int>[];
      final r = await wk.runPool<int>(5, (i) async => (p) {
            p(1, 1);
            return i * i;
          }, parallel: 2, onProgress: (d, t) => seen.add(d));
      expect(r, [0, 1, 4, 9, 16]);
      expect(seen.last, 1000);
      await expectLater(
          wk.runPool<int>(4, (i) async {
            if (i == 2) throw StateError('decode');
            return (p) => i;
          }),
          throwsA(isA<StateError>()));
      await expectLater(
          wk.runPool<int>(3, (i) async => (p) => i == 1 ? throw StateError('x') : i),
          throwsA(isA<StateError>()));
      expect(wk.running, isFalse);
    });
  });

  // ============================================================== recipe paths
  group('recipe paths: chained tool on AI enhance, Premium batch', () {
    late Directory dir;
    final blob = Uint8List.fromList(List.generate(3000, (i) => (i * 7) & 0xff));
    setUp(() => dir = Directory.systemTemp.createTempSync('pp2ai'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    AiModelInfo aiModel() => AiModelInfo(
        available: true,
        version: '2026.10.1',
        file: AiModelFile(
            name: 'm.onnx', sha256: Sha256.ofBytes(blob), size: blob.length, url: 'https://s/m.onnx'));

    /// init (the fake server lists no model) -> our test model -> download.
    Future<void> aiReady(PhotoStudioController c) async {
      await c.init();
      (c.deps.engine as StudioEnhanceEngine).model = aiModel();
      await c.prepareEnhance();
      expect(c.enhance.ai, AiState.ready);
    }

    ({PhotoStudioController c, AiNative n, pp.BytesSink sink}) make(Uint8List photo) {
      final n = AiNative();
      final b = FakePsBackend(entryDue: false, free: false);
      final eng = StudioEnhanceEngine(
          native: n,
          guard: IdentityGuard(landmarks: NativeLandmarks(n)),
          model: aiModel(),
          downloader: ModelDownloader(http: d1.MemHttp(blob), dir: dir),
          modelDir: () async => dir,
          codec: pp.RawCodec(),
          runner: syncClassicRunner,
          blurRunner: syncBlurRunner,
          reporter: (_) {});
      final sink = pp.BytesSink();
      final c = PhotoStudioController(PsDeps(
          backend: b, ads: FakeAds(b), native: n, engine: eng, guard: eng.guard, sink: sink,
          renderer: FakeRenderer(), secure: FakeSecure(), picker: _Picker(photo),
          mark: pp.FakeMark(), reporter: (_) {}));
      return (c: c, n: n, sink: sink);
    }

    test('tool on an AI-enhanced version: export = AI on the original + both recorded passes',
        () async {
      PhotoStudioController.proxyLongOverride = 200;
      const w = 400, h = 300;
      final full = pp.scene(w, h, seed: 12);
      final t = make(pp.enc(full, w, h));
      final c = t.c;
      await aiReady(c);
      await c.pick(camera: false);
      await c.setAi(true);
      await c.runEnhance();
      expect(c.lastReport.aiUsed, isTrue);
      final eng = c.deps.engine as StudioEnhanceEngine;
      final aiStep = eng.lastAiStep as ClassicStep;
      expect(eng.lastStep, isNull);
      await c.runTool(PsTool.lowLight);
      expect(c.notice, PsNotice.none);
      final toolStep = eng.lastStep!;
      expect(t.n.upscales, 1);
      await c.export(ExportKind.save, ScriptUi([]));
      expect(c.notice, PsNotice.saved);
      expect(t.n.upscales, 2, reason: 'the AI part runs once more, on the original');
      // the preview was capped at the proxy size, the export is not
      expect(t.n.targets.first, lessThanOrEqualTo(200));
      expect(t.n.targets.last, greaterThan(200));
      final anchor = fakeAi(full, w, h, t.n.inputs.last, t.n.targets.last);
      final want = applySteps(anchor.rgba, anchor.w, anchor.h, [aiStep, toolStep]).rgba;
      final r = pp.readPng(t.sink.files.single);
      expect((r.w, r.h), (anchor.w, anchor.h));
      expect(psnr(r.rgba, want), greaterThan(60),
          reason: 'the recorded classical pass, not a re-measured one');

      // the plain AI-enhanced version exports through the recipe too
      c.undo();
      await c.export(ExportKind.save, ScriptUi([]));
      expect(t.n.upscales, 3);
      final anchor1 = fakeAi(full, w, h, t.n.inputs.last, t.n.targets.last);
      final r1 = pp.readPng(t.sink.files.last);
      expect(psnr(r1.rgba, applySteps(anchor1.rgba, anchor1.w, anchor1.h, [aiStep]).rgba),
          greaterThan(60));
    });

    test('Premium batch: edited at the proxy size, exported at full size from the recipe',
        () async {
      PhotoStudioController.proxyLongOverride = 200;
      const w = 400, h = 300;
      final full = pp.scene(w, h, seed: 13);
      final t = make(pp.enc(full, w, h));
      final c = t.c;
      await c.init();
      expect(c.free, isFalse);
      await c.pickBatch();
      await c.runBatch(tool: PsTool.lowLight);
      final it = c.batch.single;
      expect(it.status, BatchStatus.done);
      expect(await pp.RawCodec().size(it.output!), (w: 200, h: 150),
          reason: 'not the 12 MP original any more');
      expect(it.step, isNotNull);
      c.openBatchItem(0);
      expect(c.session!.current.fullQuality, isFalse);
      await c.export(ExportKind.save, ScriptUi([]));
      expect(c.notice, PsNotice.saved);
      final r = pp.readPng(t.sink.files.single);
      expect((r.w, r.h), (w, h));
      expect(psnr(r.rgba, applySteps(full, w, h, [it.step!]).rgba), greaterThan(60));
    });

    test('Premium batch AI enhance: the export re-runs only the AI part + the recorded pass',
        () async {
      PhotoStudioController.proxyLongOverride = 200;
      const w = 400, h = 300;
      final full = pp.scene(w, h, seed: 14);
      final t = make(pp.enc(full, w, h));
      final c = t.c;
      await aiReady(c);
      await c.setAi(true);
      await c.pickBatch();
      await c.runBatch();
      final it = c.batch.single;
      expect(it.status, BatchStatus.done);
      expect(it.aiAnchored, isTrue);
      c.openBatchItem(0);
      await c.export(ExportKind.save, ScriptUi([]));
      expect(c.notice, PsNotice.saved);
      expect(t.n.upscales, 2);
      final anchor = fakeAi(full, w, h, t.n.inputs.last, t.n.targets.last);
      final r = pp.readPng(t.sink.files.single);
      expect(psnr(r.rgba, applySteps(anchor.rgba, anchor.w, anchor.h, [it.step!]).rgba),
          greaterThan(60));
    });
  });
}
