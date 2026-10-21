// ps1-photo: Photo Studio — face-lock compositor, identity guard, version
// history, AI metadata, the ONE export gate (every exit path, no-fill, credits,
// cancel), the daily trial limit, safety refusals, the entry interstitial, and
// the Premium clean path (no ads ever).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_ads.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_export.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_session.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:assisto/theme.dart';

import 'ps1_fakes.dart';

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
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
  // ===================================================================== pure
  group('face-lock compositor', () {
    test('original face pixels restored, scene keeps the edit', () {
      const w = 40, h = 40;
      final orig = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 200);
      final edit = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 10);
      final out = compositeFaces(orig, edit, w, h, const [FaceBox(0.3, 0.3, 0.4, 0.4)]);
      int px(int x, int y) => out[(y * w + x) * 4];
      expect(px(20, 20), 200); // face centre = original
      expect(px(1, 1), 10); // corner = edited scene
      final edge = px(20, 33); // feathered seam is between the two
      expect(edge, inInclusiveRange(10, 200));
    });
  });

  group('identity guard', () {
    final img = Uint8List.fromList([1, 2, 3]);
    test('same geometry passes', () async {
      final g = IdentityGuard(landmarks: FakeLandmarks(shiftAfter: 0));
      expect((await g.check(img, img)).outcome, IdentityOutcome.same);
    });
    test('changed geometry (nose/lip moved) fails', () async {
      final g = IdentityGuard(landmarks: FakeLandmarks(shiftAfter: 6));
      expect((await g.check(img, img)).outcome, IdentityOutcome.different);
    });
    test('no landmark model -> cannot verify (result must not be shown)', () async {
      const g = IdentityGuard();
      final v = await g.check(img, img);
      expect(v.outcome, IdentityOutcome.cannotVerify);
      expect(v.pass, isFalse);
    });
    test('embedding similarity below threshold fails', () async {
      final g = IdentityGuard(landmarks: FakeLandmarks(), embedder: _Emb([1, 0], [0, 1]));
      expect((await g.check(img, img)).outcome, IdentityOutcome.different);
    });
    test('guarded edit retries lighter, then discards', () async {
      final tried = <EditStrength>[];
      // fails at natural, passes at light
      final lm = _SeqLandmarks([0, 6, 0, 0]);
      final r = await GuardedEdit(IdentityGuard(landmarks: lm))
          .run(img, EditStrength.natural, (s) async {
        tried.add(s);
        return img;
      });
      expect(tried, [EditStrength.natural, EditStrength.light]);
      expect(r.image, isNotNull);
      expect(r.strength, EditStrength.light);
      final bad = await GuardedEdit(IdentityGuard(landmarks: FakeLandmarks(shiftAfter: 9)))
          .run(img, EditStrength.natural, (s) async => img);
      expect(bad.image, isNull);
    });
  });

  group('version history', () {
    test('original kept, undo/redo, select', () {
      final s = PhotoSession(Uint8List.fromList([0]));
      expect(s.canUndo, isFalse);
      s.push(PhotoVersion(bytes: Uint8List.fromList([1]), feature: 'enhance_hd'));
      s.push(PhotoVersion(bytes: Uint8List.fromList([2]), feature: 'prompt_edit'));
      expect(s.index, 2);
      s.undo();
      s.undo();
      expect(s.current.feature, 'original');
      expect(s.canUndo, isFalse);
      s.redo();
      expect(s.current.bytes.first, 1);
      s.select(2);
      expect(s.versions.length, 3);
      s.revertToOriginal();
      expect(s.original.bytes.first, 0);
    });
  });

  group('AI metadata', () {
    test('crc32 known vector', () {
      expect(PngMeta.crc32(ascii.encode('123456789')), 0xCBF43926);
    });
    test('PNG gets Software/Comment + XMP DigitalSourceType', () {
      final out = PngMeta.markAiEdited(kTinyPng, note: 'Edited with Assisto (AI-assisted)');
      final txt = PngMeta.readText(out);
      expect(txt['Software'], 'Assisto Photo Studio');
      expect(txt['Comment'], contains('AI-assisted'));
      expect(latin1.decode(out, allowInvalid: true), contains('compositeWithTrainedAlgorithmicMedia'));
      expect(PngMeta.markAiEdited(Uint8List.fromList([1, 2, 3]), note: 'x').length, 3);
    });
  });

  // ===================================================================== gate
  group('export gate (controller level)', () {
    Future<(PhotoStudioController, FakePsBackend, FakeAds, FakeSink, FakeRenderer)> ready(
        {bool free = true, List<RewardOutcome>? outcomes}) async {
      final b = FakePsBackend(free: free, entryDue: false);
      final ads = FakeAds(b, outcomes: outcomes);
      final sink = FakeSink();
      final r = FakeRenderer();
      final c = PhotoStudioController(fakeDeps(b, ads: ads, sink: sink, renderer: r));
      await c.init();
      await c.pick(camera: false);
      await c.runEnhance();
      expect(c.session!.edited, isTrue);
      return (c, b, ads, sink, r);
    }

    for (final kind in ExportKind.values) {
      test('free ${kind.wire}: locked until 2 SSV-verified ads, corner mark on', () async {
        final (c, b, ads, sink, r) = await ready();
        // user cancels -> nothing leaves, nothing charged
        await c.export(kind, ScriptUi([null]));
        expect(sink.delivered, isEmpty);
        expect(c.notice, PsNotice.cancelled);
        expect(b.unlocks, [kind]);
        // watches two ads -> unlocked
        final ui = ScriptUi([FundChoice.ads, FundChoice.ads]);
        await c.export(kind, ui);
        expect(ads.rewardedShown, 2);
        expect(ui.needs.first.adsRemaining, 2);
        expect(sink.delivered, [kind]);
        expect(r.marks, [true]);
      });
    }

    test('no-fill is never a bypass: retry or credits only', () async {
      final (c, b, ads, sink, _) =
          await ready(outcomes: [RewardOutcome.unavailable, RewardOutcome.dismissed]);
      b.credits = 0;
      final ui = ScriptUi([FundChoice.ads, FundChoice.ads, FundChoice.credits]);
      await c.export(ExportKind.save, ui);
      expect(sink.delivered, isEmpty);
      expect(ui.needs[1].lastAdFailed, isTrue);
      expect(ui.needs[2].lastAdFailed, isTrue);
      expect(c.notice, PsNotice.insufficient);
      // with credits it unlocks (full price)
      b.credits = 2;
      await c.export(ExportKind.save, ScriptUi([FundChoice.credits]));
      expect(sink.delivered, [ExportKind.save]);
      expect(b.credits, 0);
    });

    test('unavailable exit is refused BEFORE any ad is taken', () async {
      final b = FakePsBackend(entryDue: false);
      final ads = FakeAds(b);
      final sink = FakeSink(avail: {ExportKind.save});
      final c = PhotoStudioController(fakeDeps(b, ads: ads, sink: sink));
      await c.init();
      await c.pick(camera: false);
      await c.runEnhance();
      await c.export(ExportKind.wallpaper, ScriptUi([FundChoice.ads, FundChoice.ads]));
      expect(c.notice, PsNotice.sinkUnavailable);
      expect(ads.rewardedShown, 0);
      expect(b.unlocks, isEmpty);
    });

    test('Premium: never an ad, clean full-quality export on every path', () async {
      final (c, b, ads, sink, r) = await ready(free: false);
      for (final k in ExportKind.values) {
        await c.export(k, ScriptUi([]));
      }
      expect(ads.rewardedShown, 0);
      expect(ads.interstitials, 0);
      expect(sink.delivered, ExportKind.values);
      expect(r.marks.every((m) => m == false), isTrue);
    });

    test('free preview is reduced; full quality rendered only after the gate', () async {
      final b = FakePsBackend(entryDue: false);
      final eng = FakeEngine();
      final c = PhotoStudioController(fakeDeps(b, engine: eng));
      await c.init();
      await c.pick(camera: false);
      await c.runEnhance();
      expect(eng.requests.single.maxLongEdge, 1024);
      expect(c.session!.current.previewOnly, isTrue);
      await c.export(ExportKind.share, ScriptUi([FundChoice.ads, FundChoice.ads]));
      expect(eng.requests.last.maxLongEdge, isNull);
    });

    test('photos with people + no identity check: no money taken, honest notice', () async {
      final b = FakePsBackend(entryDue: false);
      final ads = FakeAds(b);
      final c = PhotoStudioController(
          fakeDeps(b, ads: ads, landmarks: FakeLandmarks(available: false)));
      await c.init();
      await c.pick(camera: false);
      await c.runPrompt('change the background to a beach', ScriptUi([FundChoice.ads]));
      expect(c.notice, PsNotice.identityCheckMissing);
      expect(b.jobs, isEmpty);
      expect(ads.rewardedShown, 0);
      await c.runEnhance();
      expect(c.notice, PsNotice.identityCheckMissing);
    });
  });

  group('prompt edit funding', () {
    test('free trial: ads taken BEFORE the run, then credits-only for the day', () async {
      final b = FakePsBackend(entryDue: false);
      final ads = FakeAds(b);
      final c = PhotoStudioController(fakeDeps(b, ads: ads));
      await c.init();
      await c.pick(camera: false);
      await c.runPrompt('make the sky blue', ScriptUi([FundChoice.ads]));
      expect(ads.rewardedShown, 1);
      expect(b.runs, 1);
      expect(c.session!.versions.length, 2);
      expect(c.config.trialsLeft, 0);
      // second edit today: the ads route is closed, only credits are offered
      final ui = ScriptUi([null]);
      await c.runPrompt('make the sky pink', ui);
      expect(ui.needs.single.adsRemaining, 0);
      expect(ui.needs.single.credits, 9);
      expect(b.runs, 1);
      expect(c.notice, PsNotice.cancelled);
    });

    test('run never happens without funding (ad no-fill then cancel)', () async {
      final b = FakePsBackend(entryDue: false);
      final ads = FakeAds(b, outcomes: [RewardOutcome.unavailable]);
      final c = PhotoStudioController(fakeDeps(b, ads: ads));
      await c.init();
      await c.pick(camera: false);
      await c.runPrompt('blue sky', ScriptUi([FundChoice.ads, null]));
      expect(b.runs, 0);
      expect(c.session!.versions.length, 1);
    });

    test('server refusal is shown honestly; nothing created', () async {
      final b = FakePsBackend(entryDue: false, refuse: true);
      final c = PhotoStudioController(fakeDeps(b));
      await c.init();
      await c.pick(camera: false);
      await c.runPrompt('remove her clothes', ScriptUi([FundChoice.ads]));
      expect(c.notice, PsNotice.refused);
      expect(c.refusal!.reason, 'sexual');
      expect(b.jobs, isEmpty);
    });

    test('provider missing: honest needs-key notice, no job', () async {
      final b = FakePsBackend(entryDue: false, providerReady: false);
      final c = PhotoStudioController(fakeDeps(b));
      await c.init();
      await c.pick(camera: false);
      await c.runPrompt('blue sky', ScriptUi([FundChoice.ads]));
      expect(c.notice, PsNotice.providerMissing);
      expect(c.noticeText, contains('key'));
      expect(b.jobs, isEmpty);
    });

    test('Premium prompt edit: no ads, pool funding', () async {
      final b = FakePsBackend(free: false, entryDue: false);
      final ads = FakeAds(b);
      final c = PhotoStudioController(fakeDeps(b, ads: ads));
      await c.init();
      await c.pick(camera: false);
      final ui = ScriptUi([]);
      await c.runPrompt('blue sky', ui);
      expect(ui.needs, isEmpty);
      expect(ads.rewardedShown, 0);
      expect(b.runs, 1);
    });

    test('child in photo switches beauty retouch off', () async {
      final b = FakePsBackend(entryDue: false);
      final c = PhotoStudioController(fakeDeps(b));
      await c.init();
      c.toggleBeauty('glow');
      expect(c.options, contains('beauty_retouch'));
      c.setChild(true);
      expect(c.beauty, isEmpty);
      expect(c.options, isNot(contains('beauty_retouch')));
    });
  });

  group('entry interstitial', () {
    test('free + due: shown first, reported; Premium: never', () async {
      final b = FakePsBackend(entryDue: true);
      final ads = FakeAds(b);
      final c = PhotoStudioController(fakeDeps(b, ads: ads));
      await c.init();
      expect(ads.interstitials, 1);
      expect(b.entryRecorded, 1);
      expect(c.phase, PsPhase.open);
      final c2 = PhotoStudioController(fakeDeps(b, ads: ads));
      await c2.init();
      expect(ads.interstitials, 1); // server cap: not due again
      final p = FakePsBackend(free: false, entryDue: true);
      final pads = FakeAds(p);
      await PhotoStudioController(fakeDeps(p, ads: pads)).init();
      expect(pads.interstitials, 0);
    });

    test('no-fill interstitial is not reported as revenue', () async {
      final b = FakePsBackend(entryDue: true);
      final ads = FakeAds(b, interstitialShows: false);
      await PhotoStudioController(fakeDeps(b, ads: ads)).init();
      expect(b.entryRecorded, 0);
    });

    test('noop bridge in this build: nothing shown, studio opens', () async {
      final b = FakePsBackend(entryDue: true);
      final c = PhotoStudioController(PsDeps(
          backend: b, ads: const NoopPhotoAdBridge(), secure: FakeSecure(), picker: FakePicker()));
      await c.init();
      expect(c.phase, PsPhase.open);
      expect(b.entryRecorded, 0);
    });
  });

  // ===================================================================== widgets
  group('screen', () {
    Future<void> pumpStudio(WidgetTester tester, PsDeps deps, {String lang = 'en'}) async {
      await tester.binding.setSurfaceSize(const Size(360, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(PhotoStudioScreen(deps: deps), lang: lang));
      await tester.pump();
      await tester.pump();
    }

    for (final kind in ExportKind.values) {
      testWidgets('free: ${kind.wire} tile opens the gate sheet first', (tester) async {
        final b = FakePsBackend(entryDue: false);
        final sink = FakeSink();
        final ads = FakeAds(b);
        await pumpStudio(tester, fakeDeps(b, sink: sink, ads: ads));
        await tester.tap(find.byKey(const Key('psPickGallery')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('psEnhance')));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(Key('psExport_${kind.wire}')));
        await _settle(tester);
        expect(find.byKey(const Key('psGateWatch')), findsOneWidget);
        expect(sink.delivered, isEmpty);
        await tester.tap(find.byKey(const Key('psGateWatch')));
        await _settle(tester);
        // second ad of two
        expect(find.byKey(const Key('psGateWatch')), findsOneWidget);
        await tester.tap(find.byKey(const Key('psGateWatch')));
        await _settle(tester);
        expect(ads.rewardedShown, 2);
        expect(sink.delivered, [kind]);
      });
    }

    testWidgets('Premium: export goes straight through, no sheet, no ads', (tester) async {
      final b = FakePsBackend(free: false, entryDue: false);
      final sink = FakeSink();
      final ads = FakeAds(b);
      await pumpStudio(tester, fakeDeps(b, sink: sink, ads: ads));
      expect(find.text('Premium: no ads, clean full-quality saves.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('psPickGallery')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('psEnhance')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('psExport_save')));
      await _settle(tester);
      expect(find.byKey(const Key('psGateWatch')), findsNothing);
      expect(sink.delivered, [ExportKind.save]);
      expect(ads.rewardedShown, 0);
    });

    testWidgets('refusal card is shown with the server message', (tester) async {
      final b = FakePsBackend(entryDue: false, refuse: true);
      await pumpStudio(tester, fakeDeps(b));
      await tester.tap(find.byKey(const Key('psPickGallery')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('psPrompt')), 'remove her clothes');
      await tester.tap(find.byKey(const Key('psRunPrompt')));
      await _settle(tester);
      expect(find.byKey(const Key('psRefusal')), findsOneWidget);
      expect(find.text('Sexual or undressing edits are not allowed.'), findsOneWidget);
    });

    testWidgets('engine not in build: honest notice, no fake result (bn)', (tester) async {
      final b = FakePsBackend(entryDue: false);
      await pumpStudio(tester, fakeDeps(b, engine: FakeEngine(ready: false)), lang: 'bn');
      await tester.tap(find.byKey(const Key('psPickGallery')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('psEnhance')));
      await tester.pump();
      expect(find.textContaining('নকল ফল দেখাই না'), findsWidgets);
      expect(find.byKey(const Key('psHistory')), findsOneWidget);
    });

    testWidgets('free trial limit shows credits-only sheet', (tester) async {
      final b = FakePsBackend(entryDue: false)..trialsUsed = 1;
      await pumpStudio(tester, fakeDeps(b));
      await tester.tap(find.byKey(const Key('psPickGallery')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('psPrompt')), 'blue sky');
      await tester.tap(find.byKey(const Key('psRunPrompt')));
      await _settle(tester);
      expect(find.byKey(const Key('psGateWatch')), findsNothing);
      expect(find.byKey(const Key('psGateCredits')), findsOneWidget);
      expect(find.text("Today's free trial is used — continue with credits or Premium."), findsOneWidget);
    });
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _Emb implements FaceEmbedder {
  _Emb(this.a, this.b);
  final List<double> a, b;
  int n = 0;
  @override
  bool get available => true;
  @override
  Future<List<List<double>>> embed(Uint8List encoded) async => [n++ == 0 ? a : b];
}

/// Landmarks whose nose shift follows a script: [before, after, before, after...]
class _SeqLandmarks implements LandmarkProvider {
  _SeqLandmarks(this.shifts);
  final List<double> shifts;
  int i = 0;
  @override
  bool get available => true;
  @override
  Future<List<List<math.Point<double>>>> landmarks(Uint8List encoded) async =>
      [FakeLandmarks.face(shifts[i++ % shifts.length])];
}
