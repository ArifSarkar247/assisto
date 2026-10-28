// photoperf: Photo Studio edits on a PROXY, the recipe is re-rendered at
// full size on export.
//  * pure rules: proxy size per RAM, free preview cap, coordinate scaling,
//    header sizes, BMP/PNG encoders;
//  * recipe determinism (same steps -> same bytes) and proxy-vs-full
//    equivalence on a fixture (the export looks like the preview);
//  * controller: big photo -> proxy previews, export renders the recipe at
//    full size (free users: tools honour the preview size), cancel, errors,
//    dispose / memory pressure release the native parts;
//  * screen: export progress + Cancel (bn/en, 48 dp, dark).
import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_classic.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_enhance.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/photo_studio/ps_recipe.dart';
import 'package:assisto/photo_studio/ps_report.dart';
import 'package:assisto/photo_studio/ps_session.dart';
import 'package:assisto/photo_studio/ps_tools.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ps1_fakes.dart';

// ------------------------------------------------------------------ fixtures
Uint8List enc(Uint8List rgba, int w, int h) {
  final b = BytesBuilder()
    ..add(ascii.encode('RAW1'))
    ..add((ByteData(8)
          ..setUint32(0, w)
          ..setUint32(4, h))
        .buffer
        .asUint8List())
    ..add(rgba);
  return b.toBytes();
}

class RawCodec implements ImageCodecPort {
  int fullDecodes = 0;
  bool failFull = false;
  @override
  Future<({int w, int h})> size(Uint8List e) async {
    final d = ByteData.sublistView(e, 4, 12);
    return (w: d.getUint32(0), h: d.getUint32(4));
  }

  @override
  Future<RgbaImage> decode(Uint8List e, {int? maxLong}) async {
    final s = await size(e);
    final rgba = Uint8List.sublistView(e, 12);
    if (maxLong != null && math.max(s.w, s.h) > maxLong) {
      final d = downscaleRgba(Uint8List.fromList(rgba), s.w, s.h, maxLong);
      return RgbaImage(d.rgba, d.w, d.h);
    }
    if (maxLong == null && math.max(s.w, s.h) > 300) {
      fullDecodes++;
      if (failFull) throw StateError('decode');
    }
    return RgbaImage(Uint8List.fromList(rgba), s.w, s.h);
  }

  @override
  Future<Uint8List> encodePng(RgbaImage img) async => enc(img.rgba, img.w, img.h);
}

/// Smooth "photo" (gradients + soft texture + mild grain).
Uint8List scene(int w, int h, {int seed = 1}) {
  final r = math.Random(seed);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final fx = x / w, fy = y / h;
      final base = 70 + 50 * math.sin(fx * 6.3) * math.cos(fy * 4.1) + 40 * fy;
      final n = r.nextInt(7) - 3;
      final i = (y * w + x) * 4;
      out[i] = (base * 0.95 + n).clamp(0, 255).round();
      out[i + 1] = (base * 0.8 + 20 * fx + n).clamp(0, 255).round();
      out[i + 2] = (base * 0.7 + n).clamp(0, 255).round();
      out[i + 3] = 255;
    }
  }
  return out;
}

/// Minimal PNG reader for what PngStreamEncoder writes (8-bit RGB/RGBA,
/// filter "Up" on every row).
({int w, int h, Uint8List rgba, List<String> chunks}) readPng(Uint8List b) {
  final d = ByteData.sublistView(b);
  var p = 8, w = 0, h = 0, ct = 2;
  final idat = BytesBuilder();
  final chunks = <String>[];
  while (p < b.length) {
    final len = d.getUint32(p);
    final type = ascii.decode(b.sublist(p + 4, p + 8));
    chunks.add(type);
    if (type == 'IHDR') {
      w = d.getUint32(p + 8);
      h = d.getUint32(p + 12);
      ct = b[p + 17];
    }
    if (type == 'IDAT') idat.add(b.sublist(p + 8, p + 8 + len));
    p += 12 + len;
  }
  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.toBytes()));
  final bpp = ct == 6 ? 4 : 3;
  final stride = w * bpp;
  final out = Uint8List(w * h * 4);
  final prev = Uint8List(stride);
  for (var y = 0; y < h; y++) {
    final o = y * (stride + 1);
    final ft = raw[o];
    expect(ft == 2 || ft == 0, isTrue, reason: 'filter Up (or None on a band start)');
    for (var j = 0; j < stride; j++) {
      prev[j] = ft == 2 ? (raw[o + 1 + j] + prev[j]) & 0xFF : raw[o + 1 + j];
    }
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      out[i] = prev[x * bpp];
      out[i + 1] = prev[x * bpp + 1];
      out[i + 2] = prev[x * bpp + 2];
      out[i + 3] = bpp == 4 ? prev[x * bpp + 3] : 255;
    }
  }
  return (w: w, h: h, rgba: out, chunks: chunks);
}

class PerfNative implements PhotoNative, PhotoNativeRelease {
  int releases = 0, faceCalls = 0;
  final sizes = <int>[];
  @override
  Future<void> probe() async {}
  @override
  bool get upscaleAvailable => false;
  @override
  bool get facesAvailable => true;
  @override
  Future<List<NativeFace>?> faces(Uint8List encoded) async {
    faceCalls++;
    sizes.add((await RawCodec().size(encoded)).w);
    return [const NativeFace(FaceBox(0.3, 0.25, 0.3, 0.4), [])];
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
  }) async =>
      const NativeUpscaleResult(ok: false, error: 'unavailable');
  @override
  Future<NativeMaskResult> segment(
          {required Uint8List encoded, required String modelPath, required int side}) async =>
      const NativeMaskResult(ok: false, error: 'unavailable');
  @override
  Future<void> cancel() async {}
  @override
  Future<void> release() async => releases++;
}

class BytesSink implements ExportSink {
  final files = <Uint8List>[];
  @override
  bool available(ExportKind kind) => true;
  @override
  Future<DeliverResult> deliver(ExportKind kind, Uint8List png, String fileName) async {
    files.add(png);
    return DeliverResult.done;
  }
}

class FakeMark implements MarkPainter {
  final sizes = <(int, int)>[];
  @override
  Future<MarkPatch?> paint(int w, int h) async {
    sizes.add((w, h));
    // a 10x6 solid white box in the bottom-right corner
    return MarkPatch(Uint8List.fromList(List.filled(10 * 6 * 4, 255)), w - 12, h - 8, 10, 6);
  }
}

void main() {
  tearDown(() => PhotoStudioController.proxyLongOverride = null);

  // ============================================================== pure rules
  group('proxy rules', () {
    test('proxy long edge: 1600 px on ≤ 3 GB / low-RAM phones, 2400 otherwise', () {
      expect(psProxyLong(ramMb: 1967, lowRam: false), 1600);
      expect(psProxyLong(ramMb: 2800, lowRam: false), 1600);
      expect(psProxyLong(ramMb: 7600, lowRam: true), 1600);
      expect(psProxyLong(ramMb: 3900, lowRam: false), 2400);
      expect(psProxyLong(ramMb: 0, lowRam: false), 2400); // unknown
    });

    test('free users: every interactive step at most the server preview size', () {
      expect(psInteractiveLong(proxyLong: 1600, free: true, previewMaxPx: 1024), 1024);
      expect(psInteractiveLong(proxyLong: 1600, free: false, previewMaxPx: 1024), 1600);
      expect(psInteractiveLong(proxyLong: 1600, free: true, previewMaxPx: 2048), 1600);
    });

    test('fit size never enlarges; matches the decoder rounding', () {
      expect(psFitSize(4000, 3000, 1600), (w: 1600, h: 1200));
      expect(psFitSize(3000, 4000, 1600), (w: 1200, h: 1600));
      expect(psFitSize(800, 600, 1600), (w: 800, h: 600));
      final d = downscaleRgba(Uint8List(41 * 31 * 4), 41, 31, 16);
      expect((w: d.w, h: d.h), psFitSize(41, 31, 16));
    });

    test('landmarks found on the proxy scale back to original pixels', () {
      final p = psPointsToSource(const [math.Point(100.0, 50.0), math.Point(1600.0, 1200.0)],
          proxyW: 1600, proxyH: 1200, srcW: 4000, srcH: 3000);
      expect(p[0], const math.Point(250.0, 125.0));
      expect(p[1], const math.Point(4000.0, 3000.0));
      // boxes are 0..1: the classic skin ellipse lands on the same face at
      // any size
      const f = ClassicFace(0.3, 0.25, 0.3, 0.4);
      expect((f.x + f.w / 2) * 4000, closeTo((f.x + f.w / 2) * 1600 * 2.5, 1e-9));
    });

    test('header sizes: PNG / BMP / JPEG without decoding', () {
      final png = PngStreamEncoder(7, 5)..addRows(Uint8List(7 * 5 * 4)..fillRange(0, 140, 255), 5);
      expect(psHeaderSize(png.close()), (w: 7, h: 5));
      expect(psHeaderSize(encodeBmp(Uint8List(3 * 2 * 4), 3, 2)), (w: 3, h: 2));
      // SOI, APP0 (len 16), SOF0 (h=480, w=640)
      final jpg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0, 0, 16, ...List.filled(14, 0),
        0xFF, 0xC0, 0, 17, 8, 0x01, 0xE0, 0x02, 0x80, 3, ...List.filled(9, 0),
      ]);
      expect(psHeaderSize(jpg), (w: 640, h: 480));
      expect(psHeaderSize(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('BMP: top-down BGRA, every pixel kept', () {
      final rgba = Uint8List.fromList([1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255]);
      final b = encodeBmp(rgba, 2, 2);
      expect(b.length, 54 + 16);
      expect(ByteData.sublistView(b).getInt32(22, Endian.little), -2);
      expect(b.sublist(54, 58), [3, 2, 1, 255]);
      expect(b.sublist(66, 70), [12, 11, 10, 255]);
    });
  });

  // ============================================================== recipe
  group('recipe', () {
    test('determinism: the same steps give the same bytes; the plan is measured once', () {
      const w = 160, h = 120;
      final img = scene(w, h);
      final a = applySteps(img, w, h, const [ClassicStep(ClassicParams.lowLightTool)]);
      final step = a.steps.single as ClassicStep;
      expect(step.plan, isNotNull);
      final b = applySteps(img, w, h, a.steps);
      final c = applySteps(img, w, h, a.steps);
      expect(b.rgba, a.rgba);
      expect(c.rgba, a.rgba);
      // and identical to the classic pipeline the app always ran
      expect(a.rgba, enhanceClassic(img, w, h, ClassicParams.lowLightTool));
    });

    test('proxy vs full export: the full render, shrunk, matches the proxy preview', () {
      const fw = 800, fh = 600;
      final full = scene(fw, fh, seed: 4);
      final px = downscaleRgba(full, fw, fh, 400);
      const faces = [ClassicFace(0.3, 0.25, 0.3, 0.4)];
      for (final p in [ClassicParams.lowLightTool, ClassicParams.natural, ClassicParams.denoiseTool]) {
        final prev = applySteps(px.rgba, px.w, px.h, [ClassicStep(p, faces: faces)]);
        final exp = applySteps(full, fw, fh, prev.steps);
        expect((exp.w, exp.h), (fw, fh));
        final back = downscaleRgba(exp.rgba, fw, fh, 400);
        final db = psnr(back.rgba, prev.rgba);
        // printed for the record (.phaseB evidence comes from CI logs)
        // ignore: avoid_print
        print('photoperf equivalence ${p.toMap()['lift']}: $db dB');
        expect(db, greaterThan(30), reason: 'export must look like the preview');
      }
    });

    test('streamed PNG export == recipe pixels, corner mark composited, AI note kept', () {
      const w = 300, h = 200;
      final img = scene(w, h, seed: 2);
      final steps = applySteps(img, w, h, const [ClassicStep(ClassicParams.natural)]).steps;
      final want = applySteps(img, w, h, steps).rgba;
      final mark = MarkPatch(Uint8List.fromList(List.filled(10 * 6 * 4, 255)), w - 12, h - 8, 10, 6);
      final png = renderRecipePng(img, w, h, steps,
          mark: mark, extraChunks: PngMeta.aiChunks(note: 'Edited with Assisto'), stripRows: 64);
      final r = readPng(png);
      expect((r.w, r.h), (w, h));
      expect(PngMeta.readText(png)['Comment'], 'Edited with Assisto');
      expect(r.chunks.take(2).toList(), ['IHDR', 'tEXt']);
      var diffs = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final inMark = x >= w - 12 && x < w - 2 && y >= h - 8 && y < h - 2;
          if (inMark) {
            expect(r.rgba.sublist(i, i + 3), [255, 255, 255]);
          } else if (r.rgba[i] != want[i] || r.rgba[i + 1] != want[i + 1] || r.rgba[i + 2] != want[i + 2]) {
            diffs++;
          }
        }
      }
      // stripRows only moves where running sums restart: ±1 on a few pixels
      expect(diffs, lessThan(w * h ~/ 200));
    });

    test('bands over several cores: bit-identical pixels, one valid PNG', () {
      const w = 300, h = 700; // 3 strips of 256 rows
      final img = scene(w, h, seed: 6);
      const st0 = ClassicStep(ClassicParams.lowLightTool, faces: [ClassicFace(0.3, 0.2, 0.3, 0.2)]);
      final one = applySteps(img, w, h, const [st0]);
      final bands = psBands(h, 256, 2);
      expect(bands, [(0, 256), (256, 700)]);
      final parts = [for (final (a, b) in bands) classicBand(img, w, h, st0, a, b)];
      final joined = joinBands(parts, w, h, st0);
      expect(joined.rgba, one.rgba);
      final st = one.steps.single as ClassicStep;
      // export bands get only their rows + context
      final pad = classicPad(w, h, st.faces);
      final eb = psBands(h, 256, 3);
      final pngParts = <PngBand>[];
      for (var i = 0; i < eb.length; i++) {
        final (a, b) = eb[i];
        final r0 = math.max(0, a - pad), r1 = math.min(h, b + pad);
        pngParts.add(exportBand(Uint8List.sublistView(img, r0 * w * 4, r1 * w * 4), r0, w, h, st, a, b,
            first: i == 0, last: i == eb.length - 1));
      }
      final png = joinPngBands(pngParts, w, h, extraChunks: PngMeta.aiChunks(note: 'n'));
      final r = readPng(png); // zlib checks the combined Adler-32
      expect((r.w, r.h), (w, h));
      expect(r.rgba, applySteps(img, w, h, one.steps).rgba);
      expect(r.chunks.where((c) => c == 'IDAT').length, 4);
    });

    test('adler32 combine matches one pass', () {
      int ad(List<int> d) {
        var a = 1, b = 0;
        for (final x in d) {
          a = (a + x) % 65521;
          b = (b + a) % 65521;
        }
        return (b << 16) | a;
      }

      final x = List.generate(70000, (i) => (i * 31) & 0xFF), y = List.generate(1234, (i) => i & 0xFF);
      expect(adler32Combine(ad(x), ad(y), y.length), ad([...x, ...y]));
    });

    test('blur step: the mask is resolution-free, output capped like before', () {
      final m = Uint8List(16 * 16);
      for (var i = 0; i < m.length; i++) {
        final x = i % 16, y = i ~/ 16;
        m[i] = (x > 4 && x < 11 && y > 3 && y < 13) ? 255 : 0;
      }
      final st = BlurStep(m, 16, maxLong: 100);
      final r = applySteps(scene(200, 150), 200, 150, [st]);
      expect((r.w, r.h), (100, 75));
      expect(psStepsSize(200, 150, [st]), (w: 100, h: 75));
    });

    test('worker: progress + cancel inline (tests) and in a real isolate', () async {
      final inl = PsWorker(inline: true);
      final seen = <int>[];
      final r = await inl.run((p) {
        for (var i = 1; i <= 4; i++) {
          p(i, 4);
        }
        return 7;
      }, onProgress: (d, t) => seen.add(d));
      expect(r, 7);
      expect(seen, [1, 2, 3, 4]);

      final iso = PsWorker();
      final img = scene(400, 300);
      final steps = const [ClassicStep(ClassicParams.natural)];
      final got = <int>[];
      final out = await iso.run((p) => applySteps(img, 400, 300, steps, progress: p),
          onProgress: (d, t) => got.add(d));
      expect(out.rgba, applySteps(img, 400, 300, steps).rgba);
      expect(got.last, 1000);
      // cancel: the isolate is killed, nothing returned
      final slow = iso.run((p) {
        var x = 0;
        for (var i = 0; i < 1 << 40; i++) {
          x ^= i;
          if (i % (1 << 22) == 0) p(i, 1 << 40);
        }
        return x;
      });
      await Future<void>.delayed(const Duration(milliseconds: 150));
      iso.cancel();
      await expectLater(slow, throwsA(isA<PsWorkCancelled>()));
      expect(iso.running, isFalse);
    });
  });

  // ============================================================== controller
  group('controller', () {
    ({PhotoStudioController c, PerfNative n, RawCodec codec, BytesSink sink, FakeMark mark,
        FakePsBackend b}) make({bool free = false, required Uint8List photo, PsWorker? worker}) {
      final n = PerfNative();
      final codec = RawCodec();
      final sink = BytesSink();
      final mark = FakeMark();
      final b = FakePsBackend(entryDue: false, free: free);
      final eng = StudioEnhanceEngine(
          native: n,
          guard: IdentityGuard(landmarks: NativeLandmarks(n)),
          codec: codec,
          runner: syncClassicRunner,
          blurRunner: syncBlurRunner,
          worker: worker,
          modelDir: () async => throw StateError('no model dir in tests'),
          reporter: (_) {});
      final c = PhotoStudioController(PsDeps(
          backend: b,
          ads: FakeAds(b),
          native: n,
          engine: eng,
          guard: eng.guard,
          sink: sink,
          renderer: FakeRenderer(),
          secure: FakeSecure(),
          picker: _OnePicker(photo),
          mark: mark,
          reporter: (_) {}));
      return (c: c, n: n, codec: codec, sink: sink, mark: mark, b: b);
    }

    test('big photo: pick + tool on the proxy, export = the recipe at FULL size', () async {
      PhotoStudioController.proxyLongOverride = 200;
      const w = 400, h = 300;
      final full = scene(w, h, seed: 9);
      final t = make(photo: enc(full, w, h));
      final c = t.c;
      await c.init();
      await c.pick(camera: false);
      expect((c.proxy!.w, c.proxy!.h, c.proxy!.srcW), (200, 150, 400));
      expect(c.proxy!.identity, isFalse);
      await c.facesReady;
      expect(c.facesFound, 1);
      expect(t.n.sizes.first, 200, reason: 'faces are found on the proxy');
      expect(c.tools.classic, isTrue);
      expect(t.codec.fullDecodes, 0, reason: 'nothing decoded the 12 MP original');
      await c.runTool(PsTool.lowLight);
      expect(c.notice, PsNotice.none);
      final v = c.session!.current;
      expect(await RawCodec().size(v.bytes), (w: 200, h: 150));
      expect(v.fullQuality, isFalse);
      expect(t.codec.fullDecodes, 0, reason: 'the edit ran on the proxy');
      await c.export(ExportKind.save, ScriptUi([]));
      expect(c.notice, PsNotice.saved);
      final r = readPng(t.sink.files.single);
      expect((r.w, r.h), (w, h));
      expect(t.codec.fullDecodes, 1);
      // the export is the proxy's recipe on the original
      final px = downscaleRgba(full, w, h, 200);
      final prev = applySteps(px.rgba, px.w, px.h, [
        const ClassicStep(ClassicParams.lowLightTool, faces: [ClassicFace(0.3, 0.25, 0.3, 0.4)])
      ]);
      final want = applySteps(full, w, h, prev.steps).rgba;
      expect(psnr(r.rgba, want), greaterThan(60));
      expect(t.mark.sizes, isEmpty, reason: 'Premium: no corner mark');
      expect(PngMeta.readText(t.sink.files.single)['Software'], 'Assisto Photo Studio');
    });

    test('free users: tools honour the preview size like enhance; export full + corner mark',
        () async {
      PhotoStudioController.proxyLongOverride = 1600;
      const w = 1200, h = 900;
      final t = make(free: true, photo: enc(scene(w, h, seed: 3), w, h));
      final c = t.c;
      await c.init();
      expect(c.interactiveLong, 1024); // server preview_max_px
      await c.pick(camera: false);
      await c.runTool(PsTool.denoise);
      final v = c.session!.current;
      expect(math.max((await RawCodec().size(v.bytes)).w, (await RawCodec().size(v.bytes)).h),
          lessThanOrEqualTo(1024));
      expect(v.previewOnly, isTrue);
      expect(v.fullQuality, isFalse);
      await c.export(ExportKind.save, ScriptUi([FundChoice.ads, FundChoice.ads]));
      expect(c.notice, PsNotice.saved);
      final r = readPng(t.sink.files.single);
      expect((r.w, r.h), (w, h));
      expect(t.mark.sizes.single, (w, h));
    });

    test('small photo: the proxy IS the original -> results are full quality (no re-render)',
        () async {
      PhotoStudioController.proxyLongOverride = 200;
      final t = make(photo: enc(scene(120, 90), 120, 90));
      await t.c.init();
      await t.c.pick(camera: false);
      expect(t.c.proxy!.identity, isTrue);
      await t.c.runTool(PsTool.lowLight);
      expect(t.c.session!.current.fullQuality, isTrue);
    });

    test('export error: honest notice, nothing delivered', () async {
      PhotoStudioController.proxyLongOverride = 200;
      final t = make(photo: enc(scene(400, 300), 400, 300));
      await t.c.init();
      await t.c.pick(camera: false);
      await t.c.runTool(PsTool.lowLight);
      t.codec.failFull = true;
      await t.c.export(ExportKind.save, ScriptUi([]));
      expect(t.c.notice, PsNotice.failed);
      expect(t.sink.files, isEmpty);
      expect(t.c.busy, isFalse);
      expect(t.c.progress, isNull);
    });

    test('Cancel during the export (real isolate): stops, nothing saved', () async {
      PhotoStudioController.proxyLongOverride = 400;
      const w = 1600, h = 1200;
      final t = make(photo: enc(scene(w, h), w, h), worker: PsWorker());
      final c = t.c;
      await c.init();
      await c.pick(camera: false);
      await c.runTool(PsTool.lowLight);
      expect(c.notice, PsNotice.none);
      final seen = <PsProgress>[];
      c.addListener(() {
        if (c.progress != null) seen.add(c.progress!);
      });
      final f = c.export(ExportKind.save, ScriptUi([]));
      while (!seen.any((p) => p.stage == PsStage.export)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await c.cancelRun();
      await f;
      expect(c.notice, PsNotice.cancelled);
      expect(t.sink.files, isEmpty);
      expect(c.busy, isFalse);
    });

    test('dispose frees the native parts and every photo buffer; memory pressure too', () async {
      PhotoStudioController.proxyLongOverride = 200;
      final t = make(photo: enc(scene(400, 300), 400, 300));
      await t.c.init();
      await t.c.pick(camera: false);
      t.c.onMemoryPressure();
      expect(t.n.releases, 1);
      t.c.busy = true;
      t.c.onMemoryPressure(); // never while a job runs
      expect(t.n.releases, 1);
      t.c.busy = false;
      t.c.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(t.n.releases, 2);
      expect(t.c.session, isNull);
      expect(t.c.proxy, isNull);
    });
  });

  // ============================================================== screen
  group('screen', () {
    Future<PhotoStudioController> pumpProgress(WidgetTester tester, Locale locale,
        {ThemeData? theme}) async {
      await tester.binding.setSurfaceSize(const Size(360, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = PhotoStudioController(fakeDeps(FakePsBackend(entryDue: false, providerReady: false)));
      await tester.runAsync(() async {
        await c.init();
        await c.pick(camera: false);
      });
      c.busy = true;
      c.progress = const PsProgress(PsStage.export, done: 420, total: 1000);
      await tester.pumpWidget(MaterialApp(
          locale: locale,
          theme: theme,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: PhotoStudioScreen(controller: c)));
      await tester.pump();
      return c;
    }

    for (final lang in ['en', 'bn']) {
      testWidgets('export progress: bar + %, Cancel ≥ 48 dp ($lang)', (tester) async {
        final c = await pumpProgress(tester, Locale(lang));
        final t = lookupAppLocalizations(Locale(lang));
        expect(find.textContaining(t.d1psStageClassic), findsOneWidget);
        expect(find.byKey(const Key('psProgressBar')), findsOneWidget);
        final cancel = find.byKey(const Key('psCancelRun'));
        expect(cancel, findsOneWidget);
        expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        c.cancelling = true;
        c.setStrength(c.strength);
        await tester.pump();
        expect(find.text(t.d1psStopping), findsOneWidget);
      });
    }

    testWidgets('export progress in dark theme: readable, no overflow', (tester) async {
      await pumpProgress(tester, const Locale('bn'), theme: ThemeData.dark(useMaterial3: true));
      expect(find.byKey(const Key('psProgress')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class _OnePicker implements PhotoPicker {
  _OnePicker(this.one);
  final Uint8List one;
  @override
  Future<Uint8List?> pick({required bool camera}) async => one;
  @override
  Future<List<Uint8List>> pickMany({int limit = 10}) async => [one];
}
