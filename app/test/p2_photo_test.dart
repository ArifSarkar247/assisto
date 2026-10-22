// p2-photo: Photo Studio made real — classical enhance (level mapping, tone,
// geometry-preserving, strip-invariant, skin only on faces), SHA-256, model
// manifest + resumable/offline download manager, AI sizing, identity-check
// decisions on synthetic landmark sets, the StudioEnhanceEngine (AI used /
// rejected -> fallback / not offered), FLAG_SECURE over a fake channel, and the
// prompt section hidden without a cloud key (owner note only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_classic.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_enhance.dart';
import 'package:assisto/photo_studio/ps_identity.dart';
import 'package:assisto/photo_studio/ps_model.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ps1_fakes.dart';

// ------------------------------------------------------------------ helpers
Uint8List _img(int w, int h, List<int> Function(int x, int y) px) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = px(x, y);
      final i = (y * w + x) * 4;
      out[i] = c[0];
      out[i + 1] = c[1];
      out[i + 2] = c[2];
      out[i + 3] = 255;
    }
  }
  return out;
}

List<double> _means(Uint8List rgba) {
  final m = [0.0, 0.0, 0.0];
  final n = rgba.length ~/ 4;
  for (var i = 0; i < rgba.length; i += 4) {
    m[0] += rgba[i];
    m[1] += rgba[i + 1];
    m[2] += rgba[i + 2];
  }
  return [for (final v in m) v / n];
}

double _meanAbsDiff(Uint8List a, Uint8List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    if (i % 4 == 3) continue;
    s += (a[i] - b[i]).abs();
  }
  return s / (a.length * 3 / 4);
}

/// A dull, dark, blue-tinted, noisy scene with structure.
Uint8List _scene(int w, int h, {int seed = 1}) {
  final r = math.Random(seed);
  return _img(w, h, (x, y) {
    final base = 60 + 40 * math.sin(x / 9) * math.cos(y / 13);
    final n = r.nextInt(17) - 8;
    final edge = (x > w / 2) ? 25 : 0;
    return [
      (base * 0.85 + n + edge).clamp(0, 255).round(),
      (base + n + edge).clamp(0, 255).round(),
      (base * 1.25 + 18 + n + edge).clamp(0, 255).round(),
    ];
  });
}

// "encoded" image for fakes: 'RAW1' + w + h + rgba
Uint8List _enc(Uint8List rgba, int w, int h) {
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

class _RawCodec implements ImageCodecPort {
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
  Future<Uint8List> encodePng(RgbaImage img) async => _enc(img.rgba, img.w, img.h);
}

const _eyesTpl = <List<double>>[
  [40, 50], [80, 50], [60, 70], [46, 88], [74, 88], [60, 96], [36, 74], [84, 74]
];
List<math.Point<double>> _face({double scale = 1, double dx = 0, double dy = 0,
    double rot = 0, double noseShift = 0, double mouthWiden = 0, math.Random? jitter,
    double jitterIod = 0}) {
  final pts = <math.Point<double>>[];
  for (var i = 0; i < _eyesTpl.length; i++) {
    var x = _eyesTpl[i][0], y = _eyesTpl[i][1];
    if (i == 2) x += noseShift * 40;
    if (i == 3) x -= mouthWiden * 14;
    if (i == 4) x += mouthWiden * 14;
    if (jitter != null) {
      x += (jitter.nextDouble() * 2 - 1) * jitterIod * 40;
      y += (jitter.nextDouble() * 2 - 1) * jitterIod * 40;
    }
    final cx = x - 60, cy = y - 70;
    final rx = cx * math.cos(rot) - cy * math.sin(rot);
    final ry = cx * math.sin(rot) + cy * math.cos(rot);
    pts.add(math.Point(60 + rx * scale + dx, 70 + ry * scale + dy));
  }
  return pts;
}

/// Native fake: faces before = template; faces on the upscaled (bigger)
/// image = [after] (scaled x2 like a real 2x result).
class _FakeNative implements PhotoNative {
  _FakeNative({this.up = true, this.facesOn = true, this.after});
  final bool up, facesOn;
  List<math.Point<double>>? after;
  int upscales = 0;
  int? lastMaxInput, lastTarget;
  List<FaceBox> lastFaces = const [];
  @override
  Future<void> probe() async {}
  @override
  bool get upscaleAvailable => up;
  @override
  bool get facesAvailable => facesOn;
  @override
  Future<List<NativeFace>?> faces(Uint8List encoded) async {
    final s = await _RawCodec().size(encoded);
    final big = s.w > 64;
    if (!facesOn) return null;
    final pts = big ? (after ?? _face(scale: 2)) : _face();
    return [NativeFace(const FaceBox(0.3, 0.3, 0.4, 0.4), pts)];
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
    lastFaces = faces;
    lastMaxInput = maxInputLong;
    lastTarget = targetLong;
    final src = await _RawCodec().decode(encoded);
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
    final f = File('${Directory.systemTemp.createTempSync('p2up').path}/o.raw')
      ..writeAsBytesSync(_enc(out, w, h));
    return NativeUpscaleResult(ok: true, path: f.path, w: w, h: h, ep: 'cpu');
  }

  @override
  Future<void> cancel() async {}
}

class _MemHttp implements RangeHttp {
  _MemHttp(this.blob, {this.failAfter, this.ignoreRange = false, this.status416 = false});
  final Uint8List blob;
  int? failAfter; // drop the connection after this many bytes (once)
  bool ignoreRange;
  bool status416;
  final froms = <int>[];
  final ifRanges = <String?>[];
  @override
  Future<RangeResponse> get(String url, {int from = 0, String? ifRange}) async {
    froms.add(from);
    ifRanges.add(ifRange);
    if (status416 && from > 0) {
      return RangeResponse(416, const Stream.empty());
    }
    final start = ignoreRange ? 0 : from;
    final data = blob.sublist(start);
    final fa = failAfter;
    failAfter = null;
    Stream<List<int>> body() async* {
      const step = 1000;
      for (var i = 0; i < data.length; i += step) {
        if (fa != null && i >= fa) throw const SocketException('dropped');
        yield data.sublist(i, math.min(data.length, i + step));
      }
    }

    return RangeResponse(start > 0 ? 206 : 200, body(),
        contentRange: start > 0 ? 'bytes $start-${blob.length - 1}/${blob.length}' : '');
  }
}

class _NoNet implements RangeHttp {
  int calls = 0;
  @override
  Future<RangeResponse> get(String url, {int from = 0, String? ifRange}) async {
    calls++;
    throw const SocketException('offline');
  }
}

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ===================================================== classical pipeline
  group('classical enhance', () {
    test('Light < Natural < Strong for every knob; skin never plastic', () {
      const l = ClassicParams.light, n = ClassicParams.natural, s = ClassicParams.strong;
      for (final k in l.toMap().keys) {
        expect(l.toMap()[k]! < n.toMap()[k]!, isTrue, reason: k);
        expect(n.toMap()[k]! < s.toMap()[k]!, isTrue, reason: k);
      }
      expect(s.skin, lessThanOrEqualTo(0.45));
      expect(ClassicParams.of(EditStrength.light), same(ClassicParams.light));
      expect(ClassicParams.of(EditStrength.natural), same(ClassicParams.natural));
      expect(ClassicParams.of(EditStrength.strong), same(ClassicParams.strong));
    });

    test('fixes cast + darkness; change grows with strength; input untouched', () {
      const w = 120, h = 90;
      final src = _scene(w, h);
      final copy = Uint8List.fromList(src);
      final m0 = _means(src);
      final out = {
        for (final s in EditStrength.values)
          s: enhanceClassic(src, w, h, ClassicParams.of(s))
      };
      expect(src, copy);
      final mn = _means(out[EditStrength.natural]!);
      double spread(List<double> m) => (m[0] - m[2]).abs();
      expect(spread(mn), lessThan(spread(m0)));
      expect(mn.reduce((a, b) => a + b), greaterThan(m0.reduce((a, b) => a + b)));
      final dl = _meanAbsDiff(out[EditStrength.light]!, src);
      final dn = _meanAbsDiff(out[EditStrength.natural]!, src);
      final ds = _meanAbsDiff(out[EditStrength.strong]!, src);
      expect(dl, greaterThan(0));
      expect(dl, lessThan(dn));
      expect(dn, lessThan(ds));
    });

    test('geometry preserving: a dark dot stays exactly where it was', () {
      const w = 80, h = 80;
      final src = _img(w, h, (x, y) =>
          (x - 23).abs() <= 1 && (y - 57).abs() <= 1 ? [10, 10, 10] : [170, 160, 150]);
      final out = enhanceClassic(src, w, h, ClassicParams.strong);
      var best = 999, bx = 0, by = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = out[(y * w + x) * 4];
          if (v < best) {
            best = v;
            bx = x;
            by = y;
          }
        }
      }
      expect((bx - 23).abs() <= 1 && (by - 57).abs() <= 1, isTrue, reason: '($bx,$by)');
    });

    test('strip processing == one pass (memory-bounded, same pixels)', () {
      const w = 70, h = 150;
      final src = _scene(w, h, seed: 3);
      const faces = [ClassicFace(0.2, 0.2, 0.5, 0.4)];
      final a = enhanceClassic(src, w, h, ClassicParams.strong, faces: faces, stripRows: 1000);
      final b = enhanceClassic(src, w, h, ClassicParams.strong, faces: faces, stripRows: 23);
      var maxD = 0;
      for (var i = 0; i < a.length; i++) {
        maxD = math.max(maxD, (a[i] - b[i]).abs());
      }
      expect(maxD, lessThanOrEqualTo(1));
    });

    test('skin smoothing only inside detected faces', () {
      const w = 100, h = 100;
      final r = math.Random(5);
      // skin-coloured noisy field
      final src = _img(w, h, (x, y) {
        final n = r.nextInt(21) - 10;
        return [(200 + n).clamp(0, 255), (150 + n).clamp(0, 255), (120 + n).clamp(0, 255)];
      });
      const face = [ClassicFace(0.05, 0.05, 0.3, 0.3)];
      final withFace = enhanceClassic(src, w, h, ClassicParams.natural, faces: face);
      final noFace = enhanceClassic(src, w, h, ClassicParams.natural);
      // far corner (bottom-right): identical
      for (var y = 70; y < 100; y++) {
        for (var x = 70; x < 100; x++) {
          final i = (y * w + x) * 4;
          expect(withFace[i], noFace[i]);
        }
      }
      // face centre: smoother with the face box
      double variance(Uint8List im) {
        final v = <int>[];
        for (var y = 12; y < 28; y++) {
          for (var x = 12; x < 28; x++) {
            v.add(im[(y * w + x) * 4]);
          }
        }
        final m = v.reduce((a, b) => a + b) / v.length;
        return v.map((e) => (e - m) * (e - m)).reduce((a, b) => a + b) / v.length;
      }

      expect(variance(withFace), lessThan(variance(noFace)));
    });

    test('downscale keeps aspect', () {
      final d = downscaleRgba(Uint8List(400 * 200 * 4), 400, 200, 100);
      expect((d.w, d.h), (100, 50));
    });
  });

  // ============================================================== sha256
  group('sha256', () {
    test('FIPS vectors + chunking', () {
      expect(Sha256.ofBytes([]),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(Sha256.ofBytes(ascii.encode('abc')),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          Sha256.ofBytes(ascii.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      final big = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
      expect(Sha256.ofBytes(big),
          'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
      final h = Sha256();
      for (var i = 0; i < big.length; i += 777) {
        h.add(big.sublist(i, math.min(big.length, i + 777)));
      }
      expect(h.close(), 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    });
  });

  // ===================================================== manifest + download
  group('model manifest', () {
    final sha = 'a' * 64;
    Map<String, dynamic> m({bool ok = true, String s = '', String url = 'https://x/m/a.onnx'}) => {
          'available': ok,
          'reason': ok ? '' : 'licence_pending',
          'scale': 4,
          'tile': 144,
          'pad': 8,
          'files': [
            {'name': 'a.onnx', 'sha256': s.isEmpty ? sha : s, 'size': 10, 'url': url}
          ],
        };
    test('valid / not cleared / bad sha / bad url / garbage', () {
      expect(AiModelInfo.fromJson(m()).usable, isTrue);
      expect(AiModelInfo.fromJson(m(ok: false)).usable, isFalse);
      expect(AiModelInfo.fromJson(m(s: 'xyz')).usable, isFalse);
      expect(AiModelInfo.fromJson(m(url: 'ftp://x')).usable, isFalse);
      expect(AiModelInfo.fromJson('nope').usable, isFalse);
      expect(AiModelInfo.fromJson(null).reason, 'model_pending');
      final cfg = PsConfig.fromJson({'ai_model': m(), 'is_owner': true});
      expect(cfg.aiModel.file!.name, 'a.onnx');
      expect(cfg.isOwner, isTrue);
      expect(PsConfig.fromJson({}).isOwner, isFalse);
    });
  });

  group('model download (resumable, sha256, offline)', () {
    late Directory dir;
    final blob = Uint8List.fromList(List.generate(10500, (i) => (i * 31) & 0xff));
    final file = AiModelFile(
        name: 'm.onnx', sha256: Sha256.ofBytes(blob), size: blob.length, url: 'https://s/m.onnx');
    setUp(() => dir = Directory.systemTemp.createTempSync('p2dl'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('full download -> verified, marker written, progress reported', () async {
      final prog = <int>[];
      final p = await ModelDownloader(http: _MemHttp(blob), dir: dir)
          .ensure(file, onProgress: (g, t) => prog.add(g));
      expect(File(p).readAsBytesSync(), blob);
      expect(File('${dir.path}/m.onnx.ok').readAsStringSync(), file.sha256);
      expect(prog.last, blob.length);
      expect(File('${dir.path}/m.onnx.part').existsSync(), isFalse);
    });

    test('dropped connection RESUMES with Range from the bytes we have', () async {
      final http = _MemHttp(blob, failAfter: 4000);
      final p = await ModelDownloader(http: http, dir: dir).ensure(file);
      expect(File(p).readAsBytesSync(), blob);
      expect(http.froms, [0, 4000]);
      expect(http.ifRanges.last, '"${file.sha256}"');
    });

    test('a .part left from yesterday resumes (separate downloader)', () async {
      File('${dir.path}/m.onnx.part').writeAsBytesSync(blob.sublist(0, 7000));
      final http = _MemHttp(blob);
      await ModelDownloader(http: http, dir: dir).ensure(file);
      expect(http.froms, [7000]);
    });

    test('server ignores Range (200) -> starts over cleanly', () async {
      File('${dir.path}/m.onnx.part').writeAsBytesSync(blob.sublist(0, 3000));
      final http = _MemHttp(blob, ignoreRange: true);
      final p = await ModelDownloader(http: http, dir: dir).ensure(file);
      expect(File(p).readAsBytesSync(), blob);
    });

    test('wrong bytes -> deleted, refetched once, then fails (never used)', () async {
      final bad = Uint8List.fromList(blob)..[5] ^= 0xff;
      final http = _MemHttp(bad);
      await expectLater(ModelDownloader(http: http, dir: dir).ensure(file),
          throwsA(isA<ModelDownloadFailed>()));
      expect(File('${dir.path}/m.onnx').existsSync(), isFalse);
      expect(File('${dir.path}/m.onnx.part').existsSync(), isFalse);
      expect(http.froms, [0, 0]);
    });

    test('416 on a complete part -> verified without re-download', () async {
      File('${dir.path}/m.onnx.part').writeAsBytesSync(blob.sublist(0, blob.length - 1));
      // part one byte short; server answers normally
      final p = await ModelDownloader(http: _MemHttp(blob), dir: dir).ensure(file);
      expect(File(p).lengthSync(), blob.length);
      File('${dir.path}/m.onnx').deleteSync();
      File('${dir.path}/m.onnx.ok').deleteSync();
      File('${dir.path}/m.onnx.part').writeAsBytesSync(blob); // complete part
      final http = _MemHttp(blob, status416: true);
      final p2 = await ModelDownloader(http: http, dir: dir).ensure(file);
      expect(File(p2).readAsBytesSync(), blob);
      expect(http.froms, isEmpty); // complete part: no request at all
    });

    test('offline reuse: verified copy is used with NO network', () async {
      await ModelDownloader(http: _MemHttp(blob), dir: dir).ensure(file);
      final off = _NoNet();
      final d = ModelDownloader(http: off, dir: dir);
      expect(await d.cached(file), isNotNull);
      expect(await d.ensure(file), '${dir.path}/m.onnx');
      expect(off.calls, 0);
    });

    test('offline and nothing cached -> fails honestly after retries', () async {
      final off = _NoNet();
      await expectLater(ModelDownloader(http: off, dir: dir).ensure(file),
          throwsA(isA<ModelDownloadFailed>()));
      expect(off.calls, 3);
    });

    test('a new model version replaces the old file', () async {
      File('${dir.path}/old.onnx').writeAsBytesSync([1, 2]);
      File('${dir.path}/old.onnx.ok').writeAsStringSync('x');
      await ModelDownloader(http: _MemHttp(blob), dir: dir).ensure(file);
      expect(File('${dir.path}/old.onnx').existsSync(), isFalse);
      expect(File('${dir.path}/old.onnx.ok').existsSync(), isFalse);
    });
  });

  // ============================================================== AI sizing
  group('AI plan', () {
    test('2x target, ≤640 px model input, preview cap respected', () {
      var p = AiPlan.of(800);
      expect((p.maxInputLong, p.targetLong), (640, 1600));
      p = AiPlan.of(800, maxLongEdge: 1024);
      expect((p.maxInputLong, p.targetLong), (512, 1024));
      p = AiPlan.of(300);
      expect((p.maxInputLong, p.targetLong), (300, 600));
      p = AiPlan.of(1600);
      expect((p.maxInputLong, p.targetLong), (640, 2560));
      expect(AiPlan.tiles(640, 480, 128), 5 * 4);
    });
  });

  // ======================================================== identity check
  group('identity check (synthetic landmarks)', () {
    test('same face under jitter (≤0.015 IOD), zoom, rotation, shift -> same', () {
      final rnd = math.Random(7);
      for (var k = 0; k < 200; k++) {
        final after = _face(
            scale: 0.5 + rnd.nextDouble() * 3.5,
            dx: rnd.nextDouble() * 300,
            dy: rnd.nextDouble() * 300,
            rot: (rnd.nextDouble() - 0.5) * 0.6,
            jitter: rnd,
            jitterIod: 0.015);
        final r = decideIdentity([_face()], [after]);
        expect(r.decision, IdentityDecision.same, reason: 'k=$k rms=${r.worst?.rms}');
      }
    });
    test('moved nose / wider mouth / different face -> different', () {
      expect(decideIdentity([_face()], [_face(noseShift: 0.15)]).decision,
          IdentityDecision.different);
      expect(decideIdentity([_face()], [_face(scale: 2, noseShift: 0.12)]).decision,
          IdentityDecision.different);
      expect(decideIdentity([_face()], [_face(mouthWiden: 0.25)]).decision,
          IdentityDecision.different);
      final other = [
        for (final p in _face()) math.Point(p.x * (p.y > 70 ? 1.25 : 1.0), p.y * 1.1)
      ];
      expect(decideIdentity([_face()], [other]).decision, IdentityDecision.different);
    });
    test('face lost / new face / incomplete / none', () {
      expect(decideIdentity([_face()], []).decision, IdentityDecision.different);
      expect(decideIdentity([_face()], [_face(), _face(dx: 200)]).decision,
          IdentityDecision.different);
      expect(decideIdentity([_face()], [_face().sublist(0, 2)]).decision,
          IdentityDecision.cannotVerify);
      expect(decideIdentity([], [_face()]).decision, IdentityDecision.noFaces);
    });
    test('scores are in IOD units', () {
      final s = compareFaces(_face(), _face(noseShift: 0.2));
      expect(s.maxPoint, greaterThan(0.1));
      expect(compareFaces(_face(), _face(scale: 3, rot: 0.3)).rms, lessThan(1e-9));
    });
    test('guard: failed detection -> cannot verify (never "no faces")', () async {
      final g = IdentityGuard(landmarks: _ThrowingLandmarks());
      expect((await g.check(Uint8List(1), Uint8List(1))).outcome, IdentityOutcome.cannotVerify);
    });
  });

  // ============================================================ the engine
  group('StudioEnhanceEngine', () {
    late Directory dir;
    final blob = Uint8List.fromList(List.generate(2000, (i) => i & 0xff));
    AiModelInfo model() => AiModelInfo(
        available: true,
        file: AiModelFile(
            name: 'm.onnx', sha256: Sha256.ofBytes(blob), size: blob.length, url: 'https://s/m.onnx'));
    setUp(() => dir = Directory.systemTemp.createTempSync('p2eng'));
    tearDown(() => dir.deleteSync(recursive: true));

    StudioEnhanceEngine eng(_FakeNative n, {AiModelInfo? m, RangeHttp? http}) =>
        StudioEnhanceEngine(
          native: n,
          guard: IdentityGuard(landmarks: NativeLandmarks(n)),
          model: m ?? model(),
          downloader: ModelDownloader(http: http ?? _MemHttp(blob), dir: dir),
          codec: _RawCodec(),
          runner: syncClassicRunner,
        );
    final photo = _enc(_scene(48, 40), 48, 40);

    test('classical only: real pixels change, size kept, AI untouched', () async {
      final n = _FakeNative();
      final e = eng(n);
      expect((await e.availability()).state, EnhanceState.ready);
      final out = await e.enhance(photo, const EnhanceRequest());
      expect((await _RawCodec().size(out)), (w: 48, h: 40));
      expect(out, isNot(equals(photo)));
      expect(n.upscales, 0);
      expect(e.lastReport.aiUsed, isFalse);
    });

    test('AI: needs download -> prepare (progress) -> ready -> used when face passes', () async {
      final n = _FakeNative();
      final e = eng(n);
      expect((await e.availability()).ai, AiState.needsDownload);
      expect(await e.aiEligible(photo), isTrue);
      final seen = <AiState>[];
      final a = await e.prepare(onProgress: (x) => seen.add(x.ai));
      expect(a.ai, AiState.ready);
      expect(seen.first, AiState.downloading);
      final out = await e.enhance(photo, const EnhanceRequest(ai: true));
      expect(n.upscales, 1);
      expect(e.lastReport.aiUsed, isTrue);
      expect((await _RawCodec().size(out)), (w: 96, h: 80));
      expect((n.lastMaxInput, n.lastTarget), (48, 96));
      expect(n.lastFaces.single.toList(), [0.3, 0.3, 0.4, 0.4]); // face-lock boxes sent
    });

    test('AI result with a changed face -> thrown away, classical result used', () async {
      final n = _FakeNative(after: _face(scale: 2, noseShift: 0.2));
      final e = eng(n);
      await e.availability();
      await e.prepare();
      final out = await e.enhance(photo, const EnhanceRequest(ai: true));
      expect(n.upscales, 1);
      expect(e.lastReport.aiUsed, isFalse);
      expect(e.lastReport.aiRejected, isTrue);
      expect((await _RawCodec().size(out)), (w: 48, h: 40));
    });

    test('not offered: no model / no runtime / no face check', () async {
      expect((await eng(_FakeNative(), m: AiModelInfo.none).availability()).ai, AiState.notOffered);
      expect((await eng(_FakeNative(up: false)).availability()).ai, AiState.notOffered);
      expect((await eng(_FakeNative(facesOn: false)).availability()).ai, AiState.notOffered);
    });

    test('download failure -> failed state, classical still works', () async {
      final e = eng(_FakeNative(), http: _NoNet());
      await e.availability();
      expect((await e.prepare()).ai, AiState.failed);
      final out = await e.enhance(photo, const EnhanceRequest(ai: true));
      expect(e.lastReport.aiUsed, isFalse);
      expect(out, isNotEmpty);
    });

    test('big photos are not eligible for the AI step', () async {
      final e = StudioEnhanceEngine(
          native: _FakeNative(),
          guard: IdentityGuard(landmarks: NativeLandmarks(_FakeNative())),
          model: model(),
          downloader: ModelDownloader(http: _MemHttp(blob), dir: dir),
          codec: _RawCodec(),
          runner: syncClassicRunner,
          aiMaxSourceLong: 40);
      await e.availability();
      expect(await e.aiEligible(photo), isFalse);
    });
  });

  // ===================================================== FLAG_SECURE channel
  group('FLAG_SECURE (fake platform channel)', () {
    const ch = MethodChannel('com.assisto/photo_secure');
    final calls = <String>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (c) async {
        calls.add(c.method);
        return true;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null));

    PsDeps deps(FakePsBackend b) => PsDeps(
        backend: b,
        ads: FakeAds(b),
        native: const NoPhotoNative(),
        engine: FakeEngine(),
        guard: IdentityGuard(landmarks: FakeLandmarks()),
        sink: FakeSink(),
        renderer: FakeRenderer(),
        picker: FakePicker());

    test('free preview: enabled on open, restored when leaving', () async {
      final c = PhotoStudioController(deps(FakePsBackend(entryDue: false)));
      await c.init();
      expect(calls, ['enable']);
      expect(c.secureActive, isTrue);
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['enable', 'disable']);
    });

    test('Premium: never touched', () async {
      final c = PhotoStudioController(deps(FakePsBackend(free: false, entryDue: false)));
      await c.init();
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
    });

    test('missing channel -> honest false, no crash', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
      expect(await const ChannelSecureScreen().enable(), isFalse);
    });
  });

  // ============================================ prompt section / showpieces
  group('screen', () {
    Future<PhotoStudioController> pump(WidgetTester tester, FakePsBackend b,
        {bool secure = false}) async {
      await tester.binding.setSurfaceSize(const Size(360, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = PhotoStudioController(PsDeps(
          backend: b,
          ads: FakeAds(b),
          native: const NoPhotoNative(),
          engine: FakeEngine(),
          guard: IdentityGuard(landmarks: FakeLandmarks()),
          sink: FakeSink(),
          renderer: FakeRenderer(),
          secure: FakeSecure(works: secure),
          picker: FakePicker()));
      await tester.pumpWidget(_app(PhotoStudioScreen(controller: c)));
      await c.init();
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('no cloud key: prompt section hidden for users (no dead button)',
        (tester) async {
      await pump(tester, FakePsBackend(entryDue: false, providerReady: false));
      expect(find.byKey(const Key('psPrompt')), findsNothing);
      expect(find.byKey(const Key('psRunPrompt')), findsNothing);
      expect(find.byKey(const Key('psOwnerKeyNote')), findsNothing);
      expect(find.textContaining('next update'), findsNothing);
    });

    testWidgets('no cloud key: the owner sees the small Admin note', (tester) async {
      await pump(tester, FakePsBackend(entryDue: false, providerReady: false, isOwner: true));
      expect(find.byKey(const Key('psPrompt')), findsNothing);
      expect(find.byKey(const Key('psOwnerKeyNote')), findsOneWidget);
      expect(find.textContaining('Admin → Integrations'), findsOneWidget);
    });

    testWidgets('with a key: prompt section is there', (tester) async {
      await pump(tester, FakePsBackend(entryDue: false, providerReady: true));
      expect(find.byKey(const Key('psPrompt')), findsOneWidget);
      expect(find.byKey(const Key('psOwnerKeyNote')), findsNothing);
    });

    testWidgets('enhance works, secure note only when the flag is really on',
        (tester) async {
      final c = await pump(tester, FakePsBackend(entryDue: false, providerReady: false),
          secure: false);
      await c.pick(camera: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('psEnhance')), findsOneWidget);
      await tester.tap(find.byKey(const Key('psEnhance')));
      await tester.pumpAndSettle();
      expect(c.session!.edited, isTrue);
      expect(find.textContaining('Screenshot'), findsNothing);
      expect(find.byKey(const Key('psAiSwitch')), findsNothing); // not offered
    });

    testWidgets('secure on -> "Screenshots are blocked" note', (tester) async {
      final c = await pump(tester, FakePsBackend(entryDue: false), secure: true);
      await c.pick(camera: false);
      await tester.pumpAndSettle();
      expect(find.text('Screenshots are blocked on this preview.'), findsOneWidget);
    });

    test('no showpiece keys referenced by Photo Studio code', () {
      for (final f in Directory('lib/photo_studio').listSync().whereType<File>().toList()
        ..add(File('lib/screens/photo_studio_screen.dart'))) {
        final src = f.readAsStringSync();
        for (final k in ['psEnhanceNotInBuild', 'psIdentityMissing', 'psSecureOff']) {
          expect(src.contains(k), isFalse, reason: '${f.path} uses $k');
        }
      }
    });
  });
}

class _ThrowingLandmarks implements LandmarkProvider {
  @override
  bool get available => true;
  @override
  Future<List<List<math.Point<double>>>> landmarks(Uint8List encoded) async =>
      throw StateError('boom');
}
