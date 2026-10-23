// d1-photo: Photo Studio root-cause fix + tools.
//  * the owner's failure path simulated: a camera-size photo used to skip the
//    AI step silently (and never download the model); native AI failures and
//    enhance errors were swallowed — now each one is REPORTED (non-PII) and
//    the user gets an honest message;
//  * per-tile progress, measured speed, cancel;
//  * manifest roles (upscale + segment) and the downloader keeping both;
//  * tools: upscale 2x/4x (identity-checked), denoise, low-light, background
//    blur (face must stay in the sharp area), batch, server restore flow.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_classic.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_gate_sheet.dart';
import 'package:assisto/photo_studio/ps_enhance.dart';
import 'package:assisto/photo_studio/ps_model.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/photo_studio/ps_report.dart';
import 'package:assisto/photo_studio/ps_tools.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ps1_fakes.dart';

// ------------------------------------------------------------------ raw codec
Uint8List enc(Uint8List rgba, int w, int h) {
  final b = BytesBuilder();
  b.add(ascii.encode('RAW1'));
  b.add((ByteData(8)
        ..setUint32(0, w)
        ..setUint32(4, h))
      .buffer
      .asUint8List());
  b.add(rgba);
  return b.toBytes();
}

class RawCodec implements ImageCodecPort {
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
    return RgbaImage(Uint8List.fromList(rgba), s.w, s.h);
  }

  @override
  Future<Uint8List> encodePng(RgbaImage img) async => enc(img.rgba, img.w, img.h);
}

Uint8List scene(int w, int h, {int seed = 1, double gain = 1}) {
  final r = math.Random(seed);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final base = (60 + 40 * math.sin(x / 9) * math.cos(y / 13)) * gain;
      final n = r.nextInt(31) - 15;
      final i = (y * w + x) * 4;
      out[i] = (base * 0.9 + n).clamp(0, 255).round();
      out[i + 1] = (base + n).clamp(0, 255).round();
      out[i + 2] = (base * 1.1 + n).clamp(0, 255).round();
      out[i + 3] = 255;
    }
  }
  return out;
}

const _tpl = <List<double>>[
  [40, 50], [80, 50], [60, 70], [46, 88], [74, 88], [60, 96], [36, 74], [84, 74]
];
List<math.Point<double>> face({double scale = 1, double noseShift = 0}) => [
      for (var i = 0; i < _tpl.length; i++)
        math.Point((_tpl[i][0] + (i == 2 ? noseShift * 40 : 0)) * scale, _tpl[i][1] * scale)
    ];

// ------------------------------------------------------------------ fake native
class D1Native implements PhotoNative {
  D1Native({this.upError = '', this.drift = false, this.mask, this.faceBox = const FaceBox(0.3, 0.3, 0.4, 0.4)});
  String upError;
  bool drift;
  Uint8List? mask; // side*side; null -> segment fails
  FaceBox faceBox;
  int upscales = 0, cancels = 0;
  int? lastMaxInput, lastTarget;
  bool hang = false;

  @override
  Future<void> probe() async {}
  @override
  bool get upscaleAvailable => true;
  @override
  bool get facesAvailable => true;
  @override
  Future<List<NativeFace>?> faces(Uint8List encoded) async {
    final s = await RawCodec().size(encoded);
    final out = s.w > 48;
    return [NativeFace(faceBox, out && drift ? face(scale: 2, noseShift: 0.25) : face(scale: out ? 2 : 1))];
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
    upscales++;
    lastMaxInput = maxInputLong;
    lastTarget = targetLong;
    for (var i = 1; i <= 3; i++) {
      onProgress?.call(i, 3);
      if (cancels > 0) return const NativeUpscaleResult(ok: false, error: 'cancelled');
    }
    if (upError.isNotEmpty) return NativeUpscaleResult(ok: false, error: upError, ep: 'cpu');
    final src = await RawCodec().decode(encoded);
    final w = src.w * 2, h = src.h * 2;
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final si = ((y ~/ 2) * src.w + x ~/ 2) * 4, di = (y * w + x) * 4;
        for (var c = 0; c < 4; c++) {
          out[di + c] = src.rgba[si + c];
        }
      }
    }
    final f = File('${Directory.systemTemp.createTempSync('d1up').path}/o.raw')
      ..writeAsBytesSync(enc(out, w, h));
    return NativeUpscaleResult(ok: true, path: f.path, w: w, h: h, ep: 'cpu', ms: 1800, tiles: 3);
  }

  @override
  Future<NativeMaskResult> segment(
      {required Uint8List encoded, required String modelPath, required int side}) async {
    final m = mask;
    if (m == null) return const NativeMaskResult(ok: false, error: 'ort_session: OrtException');
    return NativeMaskResult(ok: true, mask: m, side: 32, ms: 700);
  }

  @override
  Future<void> cancel() async => cancels++;
}

/// 32x32 mask: a centred ellipse (the "person") = 255, background 0.
Uint8List ellipseMask({double cx = 0.5, double cy = 0.5}) {
  final m = Uint8List(32 * 32);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 32; x++) {
      final dx = (x + 0.5) / 32 - cx, dy = (y + 0.5) / 32 - cy;
      m[y * 32 + x] = (dx * dx / 0.06 + dy * dy / 0.1) <= 1 ? 255 : 0;
    }
  }
  return m;
}

class MemHttp implements RangeHttp {
  MemHttp(this.blob, {this.status = 200});
  final Uint8List blob;
  final int status;
  @override
  Future<RangeResponse> get(String url, {int from = 0, String? ifRange}) async =>
      RangeResponse(status, Stream.value(blob.sublist(from)), length: blob.length - from);
}

void main() {
  late Directory dir;
  final blob = Uint8List.fromList(List.generate(3000, (i) => (i * 7) & 0xff));
  final segBlob = Uint8List.fromList(List.generate(1500, (i) => (i * 3) & 0xff));
  AiModelInfo model({bool seg = true}) => AiModelInfo(
      available: true,
      version: '2026.10.1',
      file: AiModelFile(name: 'm.onnx', sha256: Sha256.ofBytes(blob), size: blob.length, url: 'https://s/m.onnx'),
      segment: seg
          ? AiModelFile(
              name: 'seg.onnx', sha256: Sha256.ofBytes(segBlob), size: segBlob.length,
              url: 'https://s/seg.onnx', role: 'segment')
          : null);
  setUp(() => dir = Directory.systemTemp.createTempSync('d1eng'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final reports = <PhotoStudioFailure>[];
  StudioEnhanceEngine eng(D1Native n, {RangeHttp? http, AiModelInfo? m}) {
    reports.clear();
    final mm = m ?? model();
    return StudioEnhanceEngine(
      native: n,
      guard: IdentityGuard(landmarks: NativeLandmarks(n)),
      model: mm,
      downloader: _Router(http ?? MemHttp(blob), MemHttp(segBlob), dir),
      modelDir: () async => dir,
      codec: RawCodec(),
      runner: syncClassicRunner,
      blurRunner: syncBlurRunner,
      reporter: reports.add,
    );
  }

  final photo = enc(scene(48, 40), 48, 40);

  // ============================================================== reports
  group('failure reports are PII-free codes', () {
    test('psErrorCode keeps only short codes / types', () {
      expect(psErrorCode('ort_session: OrtException'), 'ort_session: OrtException');
      expect(psErrorCode('model_shape'), 'model_shape');
      expect(psErrorCode('/data/user/0/com.assisto/files/x.onnx failed'), 'native');
      expect(psErrorCode(const FormatException('bad /sdcard/a.jpg')), 'FormatException');
      expect(psErrorCode(null), 'unknown');
      final f = const PhotoStudioFailure('upscale', 'oom', model: '2026.10.1', ep: 'nnapi');
      expect('$f', contains('stage=upscale'));
      expect('$f', isNot(contains('/')));
    });
  });

  // ============================================================== manifest
  group('manifest roles', () {
    test('upscale + segment files; old manifests (no role) = upscale', () {
      final m = AiModelInfo.fromJson({
        'available': true,
        'version': 'v',
        'seg_side': 320,
        'files': [
          {'role': 'segment', 'name': 'u2netp.onnx', 'sha256': 'a' * 64, 'size': 10, 'url': 'https://x/u2netp.onnx'},
          {'role': 'upscale', 'name': 'r.onnx', 'sha256': 'b' * 64, 'size': 20, 'url': 'https://x/r.onnx'},
        ]
      });
      expect(m.file!.name, 'r.onnx');
      expect(m.segment!.name, 'u2netp.onnx');
      expect(m.segSide, 320);
      expect(m.names, {'r.onnx', 'u2netp.onnx'});
      final old = AiModelInfo.fromJson({
        'available': true,
        'files': [
          {'name': 'r.onnx', 'sha256': 'b' * 64, 'size': 20, 'url': 'https://x/r.onnx'}
        ]
      });
      expect(old.file!.role, 'upscale');
      expect(old.segment, isNull);
      expect(old.segmentUsable, isFalse);
    });

    test('downloading the mask model never deletes the upscaler', () async {
      final m = model();
      final up = ModelDownloader(http: MemHttp(blob), dir: dir)..keep = m.names;
      await up.ensure(m.file!);
      final seg = ModelDownloader(http: MemHttp(segBlob), dir: dir)..keep = m.names;
      await seg.ensure(m.segment!);
      expect(File('${dir.path}/m.onnx').existsSync(), isTrue);
      expect(File('${dir.path}/seg.onnx').existsSync(), isTrue);
      expect(await up.cached(m.file!), isNotNull);
    });
  });

  // ============================================================== pure tools
  group('pure tools', () {
    test('upscale limits keep the native buffers small', () {
      expect(UpscalePlan.of(1280, 960, 2)!.targetLong, 2560);
      expect(UpscalePlan.of(1281, 960, 2), isNull);
      expect(UpscalePlan.of(640, 480, 4)!.tiles, 5 * 4);
      expect(UpscalePlan.of(641, 480, 4), isNull);
    });

    test('background blur: the person keeps its ORIGINAL pixels, background blurs', () {
      const w = 64, h = 64;
      final img = scene(w, h, seed: 3);
      final out = blurBackgroundRgba(img, w, h, ellipseMask(), 32, 32, strength: 1);
      // centre (person) identical
      for (var y = 28; y < 36; y++) {
        for (var x = 28; x < 36; x++) {
          final i = (y * w + x) * 4;
          expect(out.sublist(i, i + 4), img.sublist(i, i + 4));
        }
      }
      // corner (background) smoothed: lower local variance
      double variance(Uint8List b) {
        var s = 0.0, s2 = 0.0, n = 0;
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            final v = b[(y * w + x) * 4 + 1].toDouble();
            s += v;
            s2 += v * v;
            n++;
          }
        }
        return s2 / n - (s / n) * (s / n);
      }

      expect(variance(out), lessThan(variance(img) * 0.5));
      expect(maskCoverage(ellipseMask()), inInclusiveRange(0.15, 0.4));
      expect(maskCoverage(Uint8List(16)), 0);
    });

    test('denoise tool keeps tone, removes noise; low-light brightens more than enhance', () {
      const w = 80, h = 60;
      final dark = scene(w, h, seed: 5, gain: 0.45);
      double mean(Uint8List b) {
        var s = 0.0;
        for (var i = 0; i < b.length; i += 4) {
          s += b[i + 1];
        }
        return s / (b.length / 4);
      }

      double noise(Uint8List b) {
        var s = 0.0;
        for (var y = 1; y < h - 1; y++) {
          for (var x = 1; x < w - 1; x++) {
            final i = (y * w + x) * 4 + 1;
            s += (b[i] - (b[i - 4] + b[i + 4]) / 2).abs();
          }
        }
        return s;
      }

      final dn = enhanceClassic(dark, w, h, ClassicParams.denoiseTool);
      expect((mean(dn) - mean(dark)).abs(), lessThan(3));
      expect(noise(dn), lessThan(noise(dark) * 0.8));
      final ll = enhanceClassic(dark, w, h, ClassicParams.lowLightTool);
      final nat = enhanceClassic(dark, w, h, ClassicParams.natural);
      expect(mean(ll), greaterThan(mean(nat)));
      expect(mean(ll), greaterThan(mean(dark) + 15));
    });
  });

  // ============================================================== engine
  group('engine: the owner failure path', () {
    test('native AI failure -> classical result + REPORT (was swallowed)', () async {
      final n = D1Native(upError: 'ort_session: OrtException');
      final e = eng(n);
      await e.availability();
      await e.prepare();
      final out = await e.enhance(photo, const EnhanceRequest(ai: true));
      expect(out, isNotEmpty);
      expect(e.lastReport.aiFailed, isTrue);
      expect(e.lastReport.aiUsed, isFalse);
      expect(reports.single.stage, 'upscale');
      expect(reports.single.code, 'ort_session: OrtException');
      expect(reports.single.model, '2026.10.1');
    });

    test('model shape mismatch is reported as model_shape', () async {
      final e = eng(D1Native(upError: 'model_shape'));
      await e.availability();
      await e.prepare();
      await e.enhance(photo, const EnhanceRequest(ai: true));
      expect(reports.single.code, 'model_shape');
    });

    test('download failure is reported (stage download)', () async {
      final e = eng(D1Native(), http: MemHttp(blob, status: 503));
      await e.availability();
      expect((await e.prepare()).ai, AiState.failed);
      expect(reports.single.stage, 'download');
      expect(reports.single.code, contains('http'));
    });

    test('per-tile progress with an ETA from the measured speed; speed is stored', () async {
      final n = D1Native();
      final e = eng(n);
      final seen = <PsProgress>[];
      e.progress = seen.add;
      await e.availability();
      await e.prepare();
      expect(seen.any((p) => p.stage == PsStage.download), isTrue);
      await e.enhance(photo, const EnhanceRequest(ai: true));
      final ai = seen.where((p) => p.stage == PsStage.ai).toList();
      expect(ai.map((p) => p.done), [1, 2, 3]);
      expect(ai.first.total, 3);
      expect(ai.first.etaMs, 2 * AiPlan.defaultMsPerTile);
      expect(e.perf.msPerTile, 600); // 1800 ms / 3 tiles, measured
      expect(File('${dir.path}/perf.json').existsSync(), isTrue);
      expect(e.lastReport.aiUsed, isTrue);
    });

    test('cancel -> PsCancelled, no result, nothing reported', () async {
      final n = D1Native()..cancels = 1;
      final e = eng(n);
      await e.availability();
      await e.prepare();
      await expectLater(e.enhance(photo, const EnhanceRequest(ai: true)), throwsA(isA<PsCancelled>()));
      expect(reports, isEmpty);
    });
  });

  group('engine: tools', () {
    test('tools(): availability + honest ETA + model download needed', () async {
      final e = eng(D1Native());
      await e.availability();
      final t = await e.tools(photo);
      expect(t.upscale2x && t.upscale4x && t.classic && t.bgBlur, isTrue);
      expect(t.needsUpscaleModel, isTrue);
      expect(t.needsMaskModel, isTrue);
      expect(t.etaMs[PsTool.upscale4x], 1 * AiPlan.defaultMsPerTile);
      final big = enc(scene(700, 20), 700, 20);
      final tb = await e.tools(big);
      expect(tb.upscale4x, isFalse); // 700 > 640
      expect(tb.upscale2x, isTrue);
    });

    test('upscale tool: identity pass -> 2x bytes; identity drift -> refused', () async {
      final n = D1Native();
      final e = eng(n);
      await e.availability();
      expect(await e.prepareTool(PsTool.upscale2x), isTrue);
      final out = await e.runTool(PsTool.upscale2x, photo);
      expect(await RawCodec().size(out), (w: 96, h: 80));
      expect((n.lastMaxInput, n.lastTarget), (48, 96));
      n.drift = true;
      await expectLater(e.runTool(PsTool.upscale2x, photo), throwsA(isA<PsIdentityRejected>()));
    });

    test('blur tool: face inside the mask -> blurred background; face outside -> refused', () async {
      final n = D1Native(mask: ellipseMask());
      final e = eng(n);
      await e.availability();
      expect(await e.prepareTool(PsTool.bgBlur), isTrue);
      final out = await e.runTool(PsTool.bgBlur, photo);
      expect(await RawCodec().size(out), (w: 48, h: 40));
      expect(out, isNot(equals(photo)));
      n.faceBox = const FaceBox(0.0, 0.0, 0.1, 0.1); // face in the corner = background
      await expectLater(e.runTool(PsTool.bgBlur, photo), throwsA(isA<PsNoSubject>()));
      n.mask = Uint8List(32 * 32); // nothing found
      await expectLater(e.runTool(PsTool.bgBlur, photo), throwsA(isA<PsNoSubject>()));
    });

    test('blur tool: native mask failure is reported, nothing changed', () async {
      final n = D1Native();
      final e = eng(n);
      await e.availability();
      await e.prepareTool(PsTool.bgBlur);
      await expectLater(e.runTool(PsTool.bgBlur, photo), throwsA(isA<PhotoStudioFailure>()));
      expect(reports.single.stage, 'segment');
    });

    test('denoise / low-light tools run on any phone (no model)', () async {
      final e = eng(D1Native(), m: AiModelInfo.none);
      await e.availability();
      final t = await e.tools(photo);
      expect(t.classic, isTrue);
      expect(t.upscale2x || t.bgBlur, isFalse);
      final out = await e.runTool(PsTool.lowLight, photo);
      expect(await RawCodec().size(out), (w: 48, h: 40));
    });
  });

  // ============================================================== controller
  group('controller', () {
    test('an enhance error is REPORTED and the user told (not swallowed)', () async {
      final got = <PhotoStudioFailure>[];
      final c = PhotoStudioController(PsDeps(
          backend: FakePsBackend(entryDue: false),
          ads: FakeAds(FakePsBackend()),
          native: const NoPhotoNative(),
          engine: _ThrowingEngine(),
          guard: IdentityGuard(landmarks: FakeLandmarks()),
          sink: FakeSink(),
          renderer: FakeRenderer(),
          secure: FakeSecure(),
          picker: FakePicker(),
          reporter: got.add));
      await c.init();
      await c.pick(camera: false);
      await c.runEnhance();
      expect(c.notice, PsNotice.failed);
      expect(got.single.stage, 'enhance');
      expect(got.single.code, 'StateError');
      expect(c.busy, isFalse);
      expect(c.progress, isNull);
    });

    PhotoStudioController ctl(D1Native n, {FakePsBackend? b, FakeRenderer? r, List<Uint8List>? many}) {
      final e = eng(n);
      return PhotoStudioController(PsDeps(
          backend: b ?? FakePsBackend(entryDue: false),
          ads: FakeAds(b ?? FakePsBackend()),
          native: n,
          engine: e,
          guard: e.guard,
          sink: FakeSink(),
          renderer: r ?? FakeRenderer(),
          secure: FakeSecure(),
          picker: _RawPicker(photo, many ?? const []),
          reporter: reports.add));
    }

    test('tool result is a full-quality version and is what the export delivers', () async {
      final b = FakePsBackend(entryDue: false, free: false);
      final r = FakeRenderer();
      final n = D1Native(mask: ellipseMask());
      final c = ctl(n, b: b, r: r);
      // the controller keeps the engine's model from config; give it ours
      await c.init();
      (c.deps.engine as StudioEnhanceEngine).model = model();
      await c.deps.engine.availability();
      await c.pick(camera: false);
      expect(c.tools.bgBlur, isTrue);
      await c.runTool(PsTool.bgBlur);
      expect(c.notice, PsNotice.none);
      final v = c.session!.current;
      expect(v.fullQuality, isTrue);
      await c.export(ExportKind.save, ScriptUi([]));
      expect(r.inputs.single, v.bytes);
    });

    test('identity drift on a tool -> honest notice, no new version', () async {
      final n = D1Native(drift: true);
      final c = ctl(n);
      await c.init();
      (c.deps.engine as StudioEnhanceEngine).model = model();
      await c.deps.engine.availability();
      await c.pick(camera: false);
      await c.runTool(PsTool.upscale2x);
      expect(c.notice, PsNotice.identityFailed);
      expect(c.session!.edited, isFalse);
    });

    test('batch: sequential, statuses, results open in the studio; cancel stops', () async {
      final n = D1Native();
      final many = [photo, enc(scene(48, 40, seed: 2), 48, 40), enc(scene(48, 40, seed: 3), 48, 40)];
      final c = ctl(n, many: many);
      await c.init();
      await c.pickBatch();
      expect(c.batch.length, 3);
      await c.runBatch(tool: PsTool.denoise);
      expect(c.batch.every((i) => i.status == BatchStatus.done), isTrue);
      expect(c.notice, PsNotice.batchDone);
      c.openBatchItem(1);
      expect(c.session!.current.fullQuality, isTrue);
      expect(c.session!.original.bytes, many[1]);
      // cancel before the run: everything stops, nothing marked done
      c.clearBatch();
      await c.pickBatch();
      await c.cancelRun();
      // a cancel request before start is reset by runBatch, so cancel mid-run:
      final f = c.runBatch(tool: PsTool.lowLight);
      await c.cancelRun();
      await f;
      expect(c.batch.where((i) => i.status == BatchStatus.cancelled), isNotEmpty);
    });

    test('server restore: hidden until ready; old-photo restore asks colour option, no generative options',
        () async {
      final b = FakePsBackend(entryDue: false, free: false, restoreReady: true);
      final c = PhotoStudioController(fakeDeps(b));
      await c.init();
      await c.pick(camera: false);
      expect(c.config.restoreReady(PsFeature.oldRestore), isTrue);
      c.toggleOption('bg_change'); // must NOT leak into a restore job
      await c.runRestore(PsFeature.oldRestore, ScriptUi([]));
      expect(b.runs, 1);
      expect(b.lastBody['feature'], 'old_restore');
      expect(b.lastBody['restore_colorize'], isTrue);
      expect(b.lastBody['options'], isEmpty);
      final b2 = FakePsBackend(entryDue: false);
      final c2 = PhotoStudioController(fakeDeps(b2));
      await c2.init();
      expect(c2.config.restoreReady(PsFeature.colorize), isFalse);
      expect(c2.config.restoreNeeds['deblur'], contains('GPU'));
    });
  });

  // ============================================================== screen
  group('screen', () {
    testWidgets('gate: no ad network linked -> no dead "Watch ads" button (owner build-202 dead end)',
        (tester) async {
      Widget sheet(bool linked) => MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              body: PsGateSheet(
                  need: GateNeed(adsRemaining: 2, adsTotal: 2, credits: 2, adsLinked: linked))));
      await tester.pumpWidget(sheet(false));
      expect(find.byKey(const Key('psGateWatch')), findsNothing);
      expect(find.byKey(const Key('psGateCredits')), findsOneWidget);
      await tester.pumpWidget(sheet(true));
      expect(find.byKey(const Key('psGateWatch')), findsOneWidget);
    });

    testWidgets('progress overlay: real stage, tile counts, time left, Cancel', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = PhotoStudioController(fakeDeps(FakePsBackend(entryDue: false, providerReady: false)));
      await tester.runAsync(() async {
        await c.init();
        await c.pick(camera: false);
      });
      c.busy = true;
      c.progress = const PsProgress(PsStage.ai, done: 2, total: 6, etaMs: 4400);
      await tester.pumpWidget(MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: PhotoStudioScreen(controller: c)));
      await tester.pump();
      expect(find.text('AI: part 2 of 6'), findsOneWidget);
      expect(find.text('5 s left'), findsOneWidget);
      expect(find.byKey(const Key('psProgressBar')), findsOneWidget);
      expect(find.byKey(const Key('psCancelRun')), findsOneWidget);
      c.progress = const PsProgress(PsStage.server);
      c.setStrength(c.strength);
      await tester.pump();
      expect(find.byKey(const Key('psCancelRun')), findsNothing); // server jobs can't be stopped
    });
  });
}

class _ThrowingEngine extends FakeEngine {
  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) async =>
      throw StateError('boom');
}

class _RawPicker implements PhotoPicker {
  _RawPicker(this.one, this.many);
  final Uint8List one;
  final List<Uint8List> many;
  @override
  Future<Uint8List?> pick({required bool camera}) async => one;
  @override
  Future<List<Uint8List>> pickMany({int limit = 10}) async => many.take(limit).toList();
}

/// One downloader that serves the upscaler and the mask model by name.
class _Router extends ModelDownloader {
  _Router(RangeHttp up, this.seg, Directory dir) : super(http: up, dir: dir);
  final RangeHttp seg;
  @override
  Future<String> ensure(AiModelFile f, {void Function(int, int)? onProgress}) {
    if (f.role == 'segment') {
      return (ModelDownloader(http: seg, dir: dir)..keep = keep).ensure(f, onProgress: onProgress);
    }
    return super.ensure(f, onProgress: onProgress);
  }
}
