// ps1-photo: Photo Studio gallery states for test/screenshots_test.dart.
//
// The before/after pair is a SYNTHETIC test pattern drawn here (soft + dim vs
// crisp + bright) and fed through a FAKE engine — it exists only so the
// reviewer can see the compare slider, watermark and layout. The real app has
// no engine in this build and says so (see the *_unavailable shot).
import 'dart:io' show ZLibEncoder;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_gate_sheet.dart';
import 'package:assisto/photo_studio/ps_session.dart';
import 'package:assisto/screens/photo_studio_screen.dart';

import 'ps1_fakes.dart';

Uint8List _png(int w, int h, List<int> Function(int x, int y) px) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      raw.add(px(x, y));
    }
  }
  final idat = ZLibEncoder().convert(raw.toBytes());
  List<int> chunk(String t, List<int> d) {
    final type = t.codeUnits;
    final crc = PngMeta.crc32([...type, ...d]);
    int b(int v, int s) => (v >> s) & 0xFF;
    return [b(d.length, 24), b(d.length, 16), b(d.length, 8), b(d.length, 0), ...type, ...d,
      b(crc, 24), b(crc, 16), b(crc, 8), b(crc, 0)];
  }
  int be(int v, int s) => (v >> s) & 0xFF;
  final ihdr = [be(w, 24), be(w, 16), be(w, 8), be(w, 0), be(h, 24), be(h, 16), be(h, 8), be(h, 0), 8, 2, 0, 0, 0];
  return Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, ...chunk('IHDR', ihdr), ...chunk('IDAT', idat), ...chunk('IEND', [])]);
}

/// A simple "portrait-like" scene: sky gradient, sun, hills, a figure.
List<int> _scene(int x, int y, int w, int h, {required bool after}) {
  final fx = x / w, fy = y / h;
  double r, g, b;
  if (fy < 0.62) {
    r = 90 + 120 * fy;
    g = 150 + 60 * fy;
    b = 235 - 40 * fy;
  } else {
    final hill = 0.62 + 0.05 * math.sin(fx * 9);
    final grass = fy > hill;
    r = grass ? 60 : 120;
    g = grass ? 150 : 170;
    b = grass ? 70 : 200;
  }
  final sun = math.sqrt(math.pow(fx - 0.78, 2) + math.pow(fy - 0.2, 2));
  if (sun < 0.08) {
    r = 255;
    g = 214;
    b = 90;
  }
  final head = math.sqrt(math.pow((fx - 0.42) / 0.09, 2) + math.pow((fy - 0.42) / 0.12, 2));
  final body = (fx - 0.42).abs() < 0.13 && fy > 0.54 && fy < 0.95;
  if (head < 1) {
    r = 205;
    g = 150;
    b = 120;
  } else if (body) {
    r = 40;
    g = 70;
    b = 160;
  }
  if (!after) {
    // dim, flat, noisy, slightly blurred look
    final n = ((x * 7 + y * 13) % 11) - 5;
    r = r * 0.62 + 30 + n * 3;
    g = g * 0.62 + 30 + n * 3;
    b = b * 0.62 + 30 + n * 3;
  } else {
    r = math.min(255, r * 1.06 + 4);
    g = math.min(255, g * 1.06 + 4);
    b = math.min(255, b * 1.06);
  }
  return [r.clamp(0, 255).round(), g.clamp(0, 255).round(), b.clamp(0, 255).round()];
}

final Uint8List _before = _png(180, 240, (x, y) => _scene(x, y, 180, 240, after: false));
final Uint8List _after = _png(180, 240, (x, y) => _scene(x, y, 180, 240, after: true));

class _PicturePicker implements PhotoPicker {
  @override
  Future<Uint8List?> pick({required bool camera}) async => _before;
  @override
  Future<List<Uint8List>> pickMany({int limit = 10}) async => [_before];
}

class _SampleEngine extends FakeEngine {
  _SampleEngine({this.ai = AiState.notOffered, this.progress = 0, this.report = EnhanceReport.none});
  final AiState ai;
  final double progress;
  final EnhanceReport report;
  @override
  Future<EnhanceAvailability> availability() async => EnhanceAvailability(EnhanceState.ready,
      ai: ai, progress: progress, aiBytes: 4858595);
  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) async {
    lastReport = report;
    return _after;
  }
}

// p2-photo: AI restore states (the switch only shows for small/old photos)
Widget _aiStudio(AiState ai, {double progress = 0, bool run = false,
        EnhanceReport report = EnhanceReport.none}) =>
    _studio(
        _deps(FakePsBackend(entryDue: false, providerReady: false),
            eng: _SampleEngine(ai: ai, progress: progress, report: report)), (c) async {
      await c.pick(camera: false);
      c.aiEligible = true;
      c.aiOn = ai == AiState.ready || ai == AiState.downloading;
      if (run) await c.runEnhance();
      c.setStrength(c.strength);
    });

PsDeps _deps(FakePsBackend b, {bool engine = true, bool secureWorks = true, FakeEngine? eng}) =>
    PsDeps(
      backend: b,
      ads: FakeAds(b),
      native: const NoPhotoNative(),
      engine: eng ?? (engine ? _SampleEngine() : FakeEngine(ready: false)),
      guard: IdentityGuard(landmarks: FakeLandmarks()),
      sink: FakeSink(),
      renderer: FakeRenderer(),
      secure: FakeSecure(works: secureWorks),
      picker: _PicturePicker(),
    );

Widget _studio(PsDeps d, Future<void> Function(PhotoStudioController c) script) {
  final c = PhotoStudioController(d);
  c.init().then((_) => script(c));
  return PhotoStudioScreen(controller: c);
}

Widget _sheet(GateNeed need, {bool forRun = false}) => Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          elevation: 3,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: PsGateSheet(need: need, forRun: forRun, onPremium: () {}),
        ),
      ),
    );

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> ps1Shots = {
  'photo_studio_free_empty': (_) =>
      _studio(_deps(FakePsBackend(entryDue: false)), (c) async {}),
  'photo_studio_free_enhanced': (_) =>
      _studio(_deps(FakePsBackend(entryDue: false)), (c) async {
        await c.pick(camera: false);
        await c.runEnhance();
      }),
  'photo_studio_free_enhanced_bottom': (_) =>
      _studio(_deps(FakePsBackend(entryDue: false)), (c) async {
        await c.pick(camera: false);
        await c.runEnhance();
        c.toggleOption('bg_change');
        c.toggleBeauty('glow');
        c.toggleBeauty('skin_smooth');
        c.setOthers(true);
      }),
  'photo_studio_premium': (_) =>
      _studio(_deps(FakePsBackend(free: false, entryDue: false)), (c) async {
        await c.pick(camera: false);
        await c.runEnhance();
      }),
  // p2-photo: no cloud key -> no prompt section for users (no dead button)
  'photo_studio_nokey_user': (_) => _studio(
          _deps(FakePsBackend(entryDue: false, providerReady: false)), (c) async {
        await c.pick(camera: false);
        await c.runEnhance();
      }),
  // ... the owner sees one small "Admin -> Integrations" note instead
  'photo_studio_nokey_owner': (_) => _studio(
          _deps(FakePsBackend(entryDue: false, providerReady: false, isOwner: true)),
          (c) async {}),
  'photo_studio_ai_download': (_) => _aiStudio(AiState.needsDownload),
  'photo_studio_ai_downloading': (_) => _aiStudio(AiState.downloading, progress: 0.42),
  'photo_studio_ai_used': (_) => _aiStudio(AiState.ready,
      run: true, report: const EnhanceReport(aiUsed: true)),
  'photo_studio_ai_fellback': (_) => _aiStudio(AiState.ready,
      run: true, report: const EnhanceReport(aiRejected: true)),
  'photo_studio_refusal': (l) => _studio(
          _deps(FakePsBackend(
              entryDue: false,
              refuse: true,
              // the server's own bn/en refusal copy (core/photo_studio_service.py)
              refuseMessage: l == 'bn'
                  ? String.fromCharCodes([0x9AF, 0x9CC, 0x9A8, 0x20, 0x9AC, 0x9BE, 0x20, 0x995, 0x9BE, 0x9AA, 0x9DC, 0x20, 0x996, 0x9CB, 0x9B2, 0x9BE, 0x9B0, 0x20, 0x9AE, 0x9A4, 0x9CB, 0x20, 0x98F, 0x9A1, 0x9BF, 0x99F, 0x20, 0x995, 0x9B0, 0x9BE, 0x20, 0x9B9, 0x9AF, 0x9BC, 0x20, 0x9A8, 0x9BE, 0x964])
                  : 'Sexual or undressing edits are not allowed.')), (c) async {
        await c.pick(camera: false);
        await c.runPrompt('x', ScriptUi([]));
        c.clearNotice();
      }),
  'photo_studio_gate': (_) => _sheet(const GateNeed(adsRemaining: 2, adsTotal: 2, credits: 2)),
  'photo_studio_gate_nofill': (_) => _sheet(
      const GateNeed(adsRemaining: 1, adsTotal: 2, credits: 9, lastAdFailed: true),
      forRun: true),
  'photo_studio_gate_credits_only': (_) =>
      _sheet(const GateNeed(adsRemaining: 0, adsTotal: 0, credits: 9, reason: 'trial_used')),
};

// d1-photo: the synthetic sample pair, shared with d1_photo_shots.dart.
Uint8List get ps1SampleBefore => _before;
Uint8List get ps1SampleAfter => _after;
