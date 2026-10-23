// d1-photo: Photo Studio gallery states (tools, honest progress + cancel,
// server restore for users / the owner, batch). Synthetic sample pictures and
// FAKE engines — they exist only so the layout can be reviewed; the real
// engine and its numbers are covered by d1_photo_test.dart.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_enhance.dart' show AiPlan;
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/photo_studio/ps_report.dart';
import 'package:assisto/photo_studio/ps_tools.dart';
import 'package:assisto/screens/photo_studio_screen.dart';

import 'ps1_fakes.dart';
import 'ps1_shots.dart';

class _ToolEngine extends FakeEngine implements PhotoToolEngine {
  _ToolEngine({this.ai = AiState.needsDownload});
  final AiState ai;
  @override
  PsProgressFn? progress;
  @override
  Future<EnhanceAvailability> availability() async =>
      EnhanceAvailability(EnhanceState.ready, ai: ai, aiBytes: 4858595, maxScale: 4);
  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) async => ps1SampleAfter;
  @override
  Future<ToolsAvailability> tools(Uint8List encoded) async => const ToolsAvailability(
      upscale2x: true,
      upscale4x: true,
      classic: true,
      bgBlur: true,
      needsMaskModel: true,
      etaMs: {PsTool.upscale2x: 6600, PsTool.upscale4x: 6600, PsTool.bgBlur: 2700});
  @override
  Future<bool> prepareTool(PsTool tool) async => true;
  @override
  Future<Uint8List> runTool(PsTool tool, Uint8List encoded, {int? maxLongEdge}) async =>
      ps1SampleAfter;
  @override
  Future<void> cancel() async {}
}

class _Picker implements PhotoPicker {
  @override
  Future<Uint8List?> pick({required bool camera}) async => ps1SampleBefore;
  @override
  Future<List<Uint8List>> pickMany({int limit = 10}) async =>
      [ps1SampleBefore, ps1SampleAfter, ps1SampleBefore, ps1SampleAfter];
}

PsDeps _deps(FakePsBackend b, {AiState ai = AiState.needsDownload}) => PsDeps(
      backend: b,
      ads: FakeAds(b),
      native: const NoPhotoNative(),
      engine: _ToolEngine(ai: ai),
      guard: IdentityGuard(landmarks: FakeLandmarks()),
      sink: FakeSink(),
      renderer: FakeRenderer(),
      secure: FakeSecure(works: true),
      picker: _Picker(),
      reporter: (_) {},
    );

Widget _studio(PsDeps d, Future<void> Function(PhotoStudioController c) script) {
  final c = PhotoStudioController(d);
  c.init().then((_) => script(c));
  return PhotoStudioScreen(controller: c);
}

Future<void> _withPhoto(PhotoStudioController c) async {
  await c.pick(camera: false);
  c.aiEligible = true;
  c.aiPlan = const AiPlan(320, 1280, tileCount: 6);
  c.setStrength(c.strength);
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> d1PhotoShots = {
  // tools card + the honest "works on a 1,280 px copy · about 7 s" AI line
  'photo_studio_d1_tools': (_) =>
      _studio(_deps(FakePsBackend(entryDue: false, providerReady: false)), _withPhoto),
  // a running AI step: real stage, tile counts, time left, Cancel
  'photo_studio_d1_progress': (_) =>
      _studio(_deps(FakePsBackend(entryDue: false, providerReady: false)), (c) async {
        await _withPhoto(c);
        c.busy = true;
        c.progress = const PsProgress(PsStage.ai, done: 2, total: 6, etaMs: 4400);
        c.setStrength(c.strength);
      }),
  // server restore ready for a free user (costs shown), after a blur
  'photo_studio_d1_restore': (_) => _studio(
          _deps(FakePsBackend(entryDue: false, providerReady: false, restoreReady: true)),
          (c) async {
        await _withPhoto(c);
        await c.runTool(PsTool.bgBlur);
      }),
  // the owner sees what is missing (model / GPU key) + why no face restore
  'photo_studio_d1_restore_owner': (_) => _studio(
      _deps(FakePsBackend(entryDue: false, providerReady: false, free: false, isOwner: true)),
      _withPhoto),
  // batch: several photos, one action, statuses
  'photo_studio_d1_batch': (_) =>
      _studio(_deps(FakePsBackend(entryDue: false, providerReady: false)), (c) async {
        await c.pickBatch();
        await c.runBatch(tool: PsTool.lowLight);
        c.batch[2].status = BatchStatus.skipped;
        c.batch[2].reason = PsNotice.noSubject;
        c.batch[3].status = BatchStatus.waiting;
        c.clearNotice();
      }),
};
