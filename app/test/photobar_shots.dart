// photobar: Photo Studio launch-bar gallery states — the editor card, the
// Bangladesh ID / passport card, an ID photo made + its print sheet, and the
// crop / ID framer / filter / text / sticker editors. Synthetic sample
// picture + FAKE engines (layout review only; the real pixels are covered by
// photobar_test.dart).
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_edit.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/photo_studio/ps_report.dart';
import 'package:assisto/photo_studio/ps_tools.dart';
import 'package:assisto/screens/photo_edit_screens.dart';
import 'package:assisto/screens/photo_studio_screen.dart';

import 'photobar_fakes.dart';
import 'ps1_fakes.dart';
import 'ps1_shots.dart' show ps1SampleBefore, ps1SampleAfter;

/// Tools on (the background mask is offered) — results are the sample.
class _BgToolEngine extends FakeEngine implements PhotoToolEngine {
  @override
  PsProgressFn? progress;
  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) async => ps1SampleAfter;
  @override
  Future<ToolsAvailability> tools(Uint8List encoded) async => const ToolsAvailability(
      classic: true, bgBlur: true, etaMs: {PsTool.bgWhite: 2100, PsTool.bgBlur: 2700});
  @override
  Future<bool> prepareTool(PsTool tool) async => true;
  @override
  Future<Uint8List> runTool(PsTool tool, Uint8List encoded, {int? maxLongEdge}) async => encoded;
  @override
  Future<void> cancel() async {}
}

PsDeps _deps(FakePsBackend b, {bool tools = false}) => PsDeps(
      backend: b,
      ads: FakeAds(b),
      native: const NoPhotoNative(),
      engine: tools ? _BgToolEngine() : FakeEngine(),
      guard: IdentityGuard(landmarks: FakeLandmarks()),
      sink: FakeSink(),
      renderer: FakeRenderer(),
      secure: FakeSecure(works: true),
      picker: PbPicker(ps1SampleBefore),
      reporter: (_) {},
      edit: PureEditCodec(),
    );

Widget _studio(PsDeps d, Future<void> Function(PhotoStudioController c) script) {
  final c = PhotoStudioController(d);
  c.init().then((_) => script(c));
  return PhotoStudioScreen(controller: c);
}

Future<void> _idPhoto(PhotoStudioController c, {bool sheet = false}) async {
  await c.pick(camera: false);
  final p = c.idPresets.first; // passport 45x55
  await c.makeIdPhoto(p, GeoStep(crop: PsCrop.centred(180, 240, p.aspect)));
  if (sheet) await c.applyEdit([const SheetStep()], id: c.currentId, feature: 'id_sheet');
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> photobarShots = {
  // a photo picked: "Edit" card + "Passport & ID photo" card (bg choice)
  'photo_studio_pb_cards': (_) => _studio(
      _deps(FakePsBackend(entryDue: false, providerReady: false), tools: true),
      (c) async => c.pick(camera: false)),
  // free user, phone without the mask model: honest "use a white wall" line
  'photo_studio_pb_cards_nomask': (_) => _studio(
      _deps(FakePsBackend(entryDue: false, providerReady: false)), (c) async => c.pick(camera: false)),
  // a passport photo made: 531x650 px, 300 DPI file line, print-sheet button
  'photo_studio_pb_id_made': (_) =>
      _studio(_deps(FakePsBackend(free: false, entryDue: false, providerReady: false)), _idPhoto),
  // ... and its 4x6 inch print sheet (4 copies)
  'photo_studio_pb_id_sheet': (_) => _studio(
      _deps(FakePsBackend(free: false, entryDue: false, providerReady: false)),
      (c) => _idPhoto(c, sheet: true)),
  'photo_pb_crop': (_) => PsCropScreen(bytes: ps1SampleBefore),
  'photo_pb_crop_id': (_) => Builder(builder: (ctx) {
        final t = AppLocalizations.of(ctx);
        return PsCropScreen(
            bytes: ps1SampleBefore,
            fixedAspect: 45 / 55,
            title: t.psbIdPassport,
            face: const FaceBox(0.33, 0.30, 0.18, 0.24),
            idHint: t.psbIdHint);
      }),
  'photo_pb_filters': (_) => PsFilterScreen(bytes: ps1SampleBefore),
  'photo_pb_text': (_) => PsTextScreen(bytes: ps1SampleBefore, initial: const [
        PsOverlay(text: 'Assisto', cx: 0.5, cy: 0.82, bg: 0x99000000),
      ]),
  'photo_pb_stickers': (_) => PsTextScreen(bytes: ps1SampleBefore, stickers: true),
};
