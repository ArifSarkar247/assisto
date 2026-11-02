// photobar (2 Nov): Photo Studio launch bar — crop/rotate/flip, filters,
// background fill, text/sticker patches, Bangladesh ID presets (exact px,
// 300 DPI tag, portal JPEG under its KB limit, print sheet), the editor
// screens, the export (gallery notice, no corner mark on ID photos, dead
// Wallpaper/Copy tiles gone), history selection, 200% text + dark.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_edit.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_recipe.dart';
import 'package:assisto/screens/photo_edit_screens.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:assisto/theme.dart';

import 'photobar_fakes.dart';
import 'ps1_fakes.dart';

/// w×h RGBA where pixel (x, y) = [x, y, 0, 255].
Uint8List _grid(int w, int h) {
  final o = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      o[i] = x;
      o[i + 1] = y;
      o[i + 3] = 255;
    }
  }
  return o;
}

List<int> _px(RgbaOut r, int x, int y) {
  final i = (y * r.w + x) * 4;
  return [r.rgba[i], r.rgba[i + 1], r.rgba[i + 2], r.rgba[i + 3]];
}

class _GallerySink extends FakeSink {
  _GallerySink() : super(avail: {ExportKind.save, ExportKind.share, ExportKind.openIn});
  final files = <String, Uint8List>{};
  @override
  Future<DeliverResult> deliver(ExportKind kind, Uint8List png, String fileName) async {
    delivered.add(kind);
    files[fileName] = png;
    return kind == ExportKind.save ? DeliverResult.gallery : DeliverResult.done;
  }
}

Future<(PhotoStudioController, PureEditCodec, _GallerySink, FakeRenderer)> _ready(
    {bool free = false, int w = 120, int h = 160}) async {
  final b = FakePsBackend(free: free, entryDue: false);
  final codec = PureEditCodec();
  final sink = _GallerySink();
  final r = FakeRenderer();
  final c = PhotoStudioController(PsDeps(
    backend: b,
    ads: FakeAds(b),
    native: const NoPhotoNative(),
    engine: FakeEngine(),
    guard: IdentityGuard(landmarks: FakeLandmarks()),
    sink: sink,
    renderer: r,
    secure: FakeSecure(),
    picker: PbPicker(pbPhoto(w, h)),
    reporter: (_) {},
    edit: codec,
  ));
  await c.init();
  await c.pick(camera: false);
  return (c, codec, sink, r);
}

Widget _app(Widget child, {String lang = 'bn', double scale = 1, bool dark = false}) => MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, ch) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: ch!),
      home: child,
    );

void main() {
  // ------------------------------------------------------------------ pure
  group('GeoStep', () {
    test('rotate right: the top-left pixel goes to the top-right', () {
      final r = const GeoStep(turns: 1).apply(_grid(3, 2), 3, 2);
      expect((r.w, r.h), (2, 3));
      // rotated (x', y') <- source (y', h-1-x')
      expect(_px(r, 1, 0), [0, 0, 0, 255]); // source (0,0)
      expect(_px(r, 0, 0), [0, 1, 0, 255]); // source (0,1)
      expect(_px(r, 1, 2), [2, 0, 0, 255]); // source (2,0)
    });

    test('every quarter turn + mirror round-trips', () {
      final src = _grid(5, 3);
      for (final t in [0, 1, 2, 3]) {
        var r = GeoStep(turns: t).apply(src, 5, 3);
        r = GeoStep(turns: 4 - t).apply(r.rgba, r.w, r.h);
        expect(r.rgba, src, reason: 'turns $t');
      }
      final m = const GeoStep(flipH: true).apply(src, 5, 3);
      expect(_px(m, 0, 0), [4, 0, 0, 255]);
      final back = const GeoStep(flipH: true).apply(m.rgba, 5, 3);
      expect(back.rgba, src);
    });

    test('crop in 0..1 and the exact ID output size', () {
      final st = const GeoStep(crop: PsCrop(0.5, 0, 1, 0.5));
      final r = st.apply(_grid(10, 8), 10, 8);
      expect((r.w, r.h), (5, 4));
      expect(_px(r, 0, 0), [5, 0, 0, 255]);
      expect(st.outSize(10, 8), (w: 5, h: 4));
      const id = GeoStep(outW: 531, outH: 650);
      expect(id.outSize(1000, 1200), (w: 531, h: 650));
      final big = id.apply(_grid(200, 240), 200, 240);
      expect((big.w, big.h), (531, 650));
    });

    test('centred crop keeps the aspect', () {
      final c = PsCrop.centred(1200, 1600, 45 / 55);
      final w = (c.r - c.l) * 1200, h = (c.b - c.t) * 1600;
      expect(w / h, closeTo(45 / 55, 0.002));
      expect(c.isFull, isFalse);
    });
  });

  test('resize: area average when shrinking', () {
    final src = Uint8List.fromList([
      0, 0, 0, 255, 100, 100, 100, 255, //
      100, 100, 100, 255, 200, 200, 200, 255,
    ]);
    final r = resizeRgba(src, 2, 2, 1, 1);
    expect(r, [100, 100, 100, 255]);
  });

  group('filters', () {
    test('identity changes nothing; strength 0 = identity', () {
      final src = _grid(4, 4);
      expect(applyColorMatrix(src, PsMatrix.identity), src);
      expect(PsMatrix.mix(PsFilter.byId('drama')!.matrix, 0), PsMatrix.identity);
    });
    test('black & white makes the channels equal', () {
      final o = applyColorMatrix(Uint8List.fromList([200, 40, 10, 255]), PsMatrix.saturation(0));
      expect(o[0], o[1]);
      expect(o[1], o[2]);
      expect(o[3], 255);
    });
    test('every preset has a stable id and a 4x5 matrix', () {
      expect(PsFilter.all.map((f) => f.id).toSet().length, PsFilter.all.length);
      for (final f in PsFilter.all) {
        expect(f.matrix.length, 20, reason: f.id);
      }
    });
  });

  group('background fill', () {
    final rgba = _grid(8, 8);
    test('white where the mask says background, original where it says person', () {
      final bg = fillBackgroundRgba(rgba, 8, 8, Uint8List(4), 2, 2, PsBg.white);
      expect(bg.every((v) => v == 255), isTrue);
      final fg = fillBackgroundRgba(rgba, 8, 8, Uint8List(4)..fillRange(0, 4, 255), 2, 2, PsBg.white);
      expect(fg, rgba);
    });
    test('transparent: alpha 0 in the background, checkerboard RGB for previews', () {
      final o = fillBackgroundRgba(rgba, 8, 8, Uint8List(4), 2, 2, PsBg.transparent);
      for (var i = 3; i < o.length; i += 4) {
        expect(o[i], 0);
      }
      expect([0xF2, 0xCC], contains(o[0]));
    });
    test('the step obeys its size cap', () {
      final st = BgFillStep(Uint8List(4), 2, PsBg.white, maxLong: 4);
      expect(st.outSize(8, 6), (w: 4, h: 3));
      final r = st.apply(_grid(8, 6), 8, 6);
      expect((r.w, r.h), (4, 3));
    });
  });

  group('Bangladesh ID presets', () {
    test('print presets: pixels = mm at 300 DPI', () {
      for (final p in PsIdPreset.builtIn.where((p) => p.printable)) {
        expect(p.pxW, (p.wMm! / 25.4 * 300).round(), reason: p.id);
        expect(p.pxH, (p.hMm! / 25.4 * 300).round(), reason: p.id);
      }
      final pass = PsIdPreset.builtIn.first;
      expect((pass.id, pass.wMm, pass.hMm), ('passport_bd', 45, 55));
    });
    test('server values win; unknown ids keep the built-in copy', () {
      final r = PsIdPreset.resolve({
        'job_bd': {'px_w': 300, 'px_h': 300, 'fmt': 'jpg', 'max_kb': 80, 'verified': 'common_practice'},
      });
      expect(r.firstWhere((p) => p.id == 'job_bd').maxKb, 80);
      expect(r.firstWhere((p) => p.id == 'passport_bd').pxW, 531);
      expect(r.length, PsIdPreset.builtIn.length);
    });
    test('print sheet: 4 passport / 8 visa copies on 4x6 inch at 300 DPI', () {
      const s = SheetStep();
      expect(s.copies(531, 650), 4);
      expect(s.copies(413, 531), 8);
      final out = s.apply(Uint8List(531 * 650 * 4)..fillRange(0, 531 * 650 * 4, 0), 531, 650);
      expect({out.w, out.h}, {1200, 1800});
    });
    test('300 DPI tag in the PNG (replaces an old one)', () {
      final png = pbPhoto(20, 20);
      final tagged = psPngWithDpi(png, 300);
      expect(psPngDpi(tagged), 300);
      expect(psPngDpi(psPngWithDpi(tagged, 600)), 600);
      expect(img.decodePng(tagged)!.width, 20); // still a valid PNG
    });
    test('portal JPEG under its KB limit, or an honest null', () {
      final d = psDecodePng(pbPhoto(300, 300))!;
      final j = psJpegUnder(d.rgba, d.w, d.h, 100)!;
      expect(j.bytes.length, lessThanOrEqualTo(100 * 1000));
      expect(img.decodeJpg(j.bytes)!.width, 300);
      final noisy = psDecodePng(pbPhoto(300, 300, noise: true))!;
      expect(psJpegUnder(noisy.rgba, noisy.w, noisy.h, 1), isNull);
    });
  });

  test('an un-drawn overlay never silently disappears', () {
    expect(() => const OverlayStep([PsOverlay(text: 'x')]).apply(Uint8List(4), 1, 1),
        throwsStateError);
  });

  // ------------------------------------------------------------------ controller
  group('controller', () {
    test('crop + filter + text: new versions, overlays drawn at the photo size', () async {
      final (c, codec, _, _) = await _ready();
      await c.applyEdit([const GeoStep(turns: 1)]);
      expect(c.session!.versions.length, 2);
      expect(img.decodePng(c.session!.current.bytes)!.width, 160);
      await c.applyEdit([FilterStep('bw', PsFilter.byId('bw')!.matrix)]);
      await c.applyEdit([const OverlayStep([PsOverlay(text: 'Eid', cx: 0.5, cy: 0.5)])]);
      expect(c.session!.versions.length, 4);
      expect(codec.drawn.single, (1, 160, 120));
      expect(c.notice, PsNotice.none);
      // undo walks back; history select tells the screen
      var told = 0;
      c.addListener(() => told++);
      c.selectVersion(1);
      expect(c.session!.index, 1);
      expect(told, greaterThan(0));
    });

    test('ID photo: exact pixels, 300 DPI PNG, no corner mark, saved to the gallery', () async {
      final (c, _, sink, r) = await _ready(free: true);
      final pass = c.idPresets.firstWhere((p) => p.id == 'passport_bd');
      await c.makeIdPhoto(pass, GeoStep(crop: PsCrop.centred(120, 160, pass.aspect)));
      expect(c.currentId?.id, 'passport_bd');
      final shown = img.decodePng(c.session!.current.bytes)!;
      expect((shown.width, shown.height), (531, 650));
      // free user: the gate (2 SSV ads) still applies in full
      await c.export(ExportKind.save, ScriptUi([FundChoice.ads, FundChoice.ads]));
      expect(c.notice, PsNotice.savedGallery);
      expect(r.marks, [false]);
      final file = sink.files.values.single;
      expect(sink.files.keys.single, endsWith('.png'));
      expect(psPngDpi(file), 300);
      // print sheet keeps the ID and still prints at 300 DPI
      await c.applyEdit([const SheetStep()], id: c.currentId, feature: 'id_sheet');
      final sheet = img.decodePng(c.session!.current.bytes)!;
      expect({sheet.width, sheet.height}, {1200, 1800});
    });

    test('job-portal photo: JPEG at most 100 KB', () async {
      final (c, _, sink, _) = await _ready();
      final job = c.idPresets.firstWhere((p) => p.id == 'job_bd');
      await c.makeIdPhoto(job, const GeoStep());
      await c.export(ExportKind.share, ScriptUi([]));
      final name = sink.files.keys.single;
      expect(name, endsWith('.jpg'));
      expect(sink.files[name]!.length, lessThanOrEqualTo(100 * 1000));
      expect(img.decodeJpg(sink.files[name]!)!.width, 300);
    });

    test('free user: an ordinary edit still carries the corner mark', () async {
      final (c, _, sink, r) = await _ready(free: true);
      await c.applyEdit([const GeoStep(turns: 2)]);
      await c.export(ExportKind.save, ScriptUi([FundChoice.ads, FundChoice.ads]));
      expect(sink.delivered, [ExportKind.save]);
      expect(r.marks, [true]);
    });

    test('a failing edit changes nothing and says so', () async {
      final (c, codec, _, _) = await _ready();
      codec.decodes = 0;
      await c.applyEdit([const OverlayStep([PsOverlay(text: 'x')]), _Boom()]);
      expect(c.session!.versions.length, 1);
      expect(c.notice, PsNotice.editFailed);
      expect(c.busy, isFalse);
    });
  });

  test('export file type follows the name', () {
    expect(PlatformExportSink.mimeOf('a.jpg'), 'image/jpeg');
    expect(PlatformExportSink.mimeOf('a.png'), 'image/png');
    const s = PlatformExportSink();
    expect(s.available(ExportKind.wallpaper), isFalse);
    expect(s.available(ExportKind.save), isTrue);
  });

  // ------------------------------------------------------------------ screens
  group('screens', () {
    testWidgets('studio: edit + ID cards, no dead Wallpaper/Copy tiles (bn)', (tester) async {
      final (c, _, _, _) = await _ready();
      await c.applyEdit([const GeoStep(turns: 1)]);
      await tester.pumpWidget(_app(PhotoStudioScreen(controller: c)));
      await tester.pump();
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const Key('psbOpenCrop')), 200, scrollable: list);
      await tester.scrollUntilVisible(find.byKey(const Key('psbId_passport_bd')), 200, scrollable: list);
      expect(find.text('পাসপোর্ট ও আইডি ছবি'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('psExport_save')), 200, scrollable: list);
      expect(find.byKey(const Key('psExport_wallpaper')), findsNothing);
      expect(find.byKey(const Key('psExport_copy')), findsNothing);
    });

    testWidgets('crop screen: rotate + apply returns the step', (tester) async {
      Object? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async => got = await Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => PsCropScreen(bytes: pbPhoto(120, 160)))),
                    child: const Text('go')),
              ))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      // nothing changed yet: Reset is off (never a tap that does nothing)
      expect(tester.widget<TextButton>(find.byKey(const Key('psbReset'))).onPressed, isNull);
      await tester.tap(find.byKey(const Key('psbRotateRight')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('psbCropDone')));
      await tester.pumpAndSettle();
      expect(got, isA<GeoStep>());
      expect((got as GeoStep).turns, 1);
    });

    testWidgets('ID framer locks the aspect and shows the rule', (tester) async {
      await tester.pumpWidget(_app(PsCropScreen(
          bytes: pbPhoto(120, 160),
          fixedAspect: 45 / 55,
          idHint: 'hint',
          face: const FaceBox(0.4, 0.3, 0.2, 0.2))));
      await tester.pump();
      expect(find.byKey(const Key('psbIdHint')), findsOneWidget);
      expect(find.byKey(const Key('psbAspect_1.0')), findsNothing);
    });

    testWidgets('filters: pick black & white, apply', (tester) async {
      Object? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async => got = await Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => PsFilterScreen(bytes: pbPhoto(60, 80)))),
                    child: const Text('go')),
              ))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('psbFilter_bw')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('psbFilterApply')));
      await tester.pumpAndSettle();
      expect((got as FilterStep).id, 'bw');
    });

    testWidgets('text + Bangla sticker -> one overlay step', (tester) async {
      Object? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async => got = await Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => PsTextScreen(bytes: pbPhoto(60, 80)))),
                    child: const Text('go')),
              ))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('psbAddText')));
      await tester.pump();
      await tester.tap(find.text('স্টিকার').last);
      await tester.pump();
      await tester.tap(find.byKey(const Key('psbSticker_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('psbTextDone')));
      await tester.pumpAndSettle();
      final items = (got as OverlayStep).items;
      expect(items.map((o) => o.text), ['আপনার লেখা', 'ঈদ মোবারক']);
      expect(items.last.sticker, isTrue);
    });

    testWidgets('200% text + dark: studio and editors lay out without overflow', (tester) async {
      final (c, _, _, _) = await _ready();
      await tester.pumpWidget(_app(PhotoStudioScreen(controller: c), scale: 2, dark: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_app(PsTextScreen(bytes: pbPhoto(60, 80), stickers: true), scale: 2, dark: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_app(PsCropScreen(bytes: pbPhoto(60, 80)), scale: 2, dark: true, lang: 'en'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

class _Boom extends PsPixelStep {
  @override
  RgbaOut apply(Uint8List rgba, int w, int h) => throw StateError('boom');
}
