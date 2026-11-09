// cctvact (CCTV GUARD V3 D/E/F/G): alert actions (Live, box siren + own
// warning with confirm-first, thana call with confirm, Wrong alert with a
// reason, lock ONLY after Yes), the timestamp watermark (originals kept),
// closing report, Ask (examples -> answer + clips), sales match (review-only
// + POS key shown once + CSV), automations (empty -> link; rules), bn / en,
// 200 % text, light + dark.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'package:assisto/cctvx/evidence_pack.dart';
import 'package:assisto/cctvx/evidence_watermark.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/cctv_act_screens.dart';
import 'package:assisto/screens/watchman/cctv_act_tiles.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cashguard_fakes.dart';
import 'cctvact_fakes.dart';
import 'cctvact_shots.dart';
import 'cctvx_fakes.dart';
import 'fake_api.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  group('alert actions (D)', () {
    Future<FakeCctvAct> pumpSheet(WidgetTester tester, {String lang = 'en'}) async {
      final act = FakeCctvAct(lang: lang);
      await tester.pumpWidget(_app(
          Scaffold(
              body: AlertActionsSheet(
                  source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(), act: act,
                  preview: actEventActions())),
          lang: lang));
      await tester.pumpAndSettle();
      return act;
    }

    testWidgets('live, box siren asks first, warning, thana, wrong, lock only on Yes',
        (tester) async {
      final act = await pumpSheet(tester);
      expect(find.byKey(const ValueKey('cv3-live')), findsOneWidget);
      expect(find.text('Sample Model Thana'), findsOneWidget);
      expect(find.textContaining('01711000000'), findsOneWidget);
      expect(find.textContaining('number not on the public map'), findsOneWidget);
      // siren: confirm first; Cancel does nothing
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-box-siren')));
      await tester.tap(find.byKey(const ValueKey('cv3-box-siren')));
      await tester.pumpAndSettle();
      expect(find.text('Sound the siren now?'), findsOneWidget);
      await _tapText(tester, 'Cancel');
      expect(act.calls.where((c) => c.startsWith('play')), isEmpty);
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-box-warn')));
      await tester.tap(find.byKey(const ValueKey('cv3-box-warn')));
      await tester.pumpAndSettle();
      await _tapText(tester, 'Play');
      expect(act.calls, contains('play:201:warn'));
      // wrong alert with a reason
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-wrong')));
      await tester.tap(find.byKey(const ValueKey('cv3-wrong')));
      await tester.pumpAndSettle();
      expect(find.text('What was it really?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cv3-wrong-staff')));
      await tester.pumpAndSettle();
      expect(act.calls, contains('wrong:201:staff'));
      // the lock never acts without the owner's Yes
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-lock-p1')));
      await tester.tap(find.byKey(const ValueKey('cv3-lock-p1')));
      await tester.pumpAndSettle();
      expect(act.calls.where((c) => c.startsWith('lock')), isEmpty);
      await _tapText(tester, 'Yes, lock');
      expect(act.calls, contains('lock:p1'));
      expect(find.byKey(const ValueKey('cv3-lock-p1')), findsNothing);
      expect(find.textContaining('waiting for your Yes'), findsOneWidget);
    });

    testWidgets('no location yet: find the thana from the phone, 999 still there',
        (tester) async {
      final act = FakeCctvAct();
      final ev = actEventActions(locks: false);
      (ev['actions'] as Map)['act'] = fakeAct(locks: false, stations: false);
      await tester.pumpWidget(_app(Scaffold(
          body: AlertActionsSheet(
              source: FakeCctvx(), eventId: 201, act: act, preview: ev))));
      await tester.pumpAndSettle();
      final tiles = find.byType(ActTiles);
      expect(tiles, findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-thana-set')));
      await tester.tap(find.byKey(const ValueKey('cv3-thana-set')));
      await tester.pumpAndSettle();
      expect(find.text('Save the shop\'s location?'), findsOneWidget);
    });

    testWidgets('bn 200 % dark: no overflow, Bangla digits', (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          Scaffold(
              body: AlertActionsSheet(
                  source: FakeCctvx(), eventId: 201, act: FakeCctvAct(lang: 'bn'),
                  preview: actEventActions())),
          lang: 'bn', scale: 2.0, dark: true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('০১৭১১০০০০০০'), findsOneWidget);
    });
  });

  group('watermark (D evidence)', () {
    test('a stamped copy, the original untouched, Dhaka time', () {
      final src = img.Image(width: 640, height: 360);
      img.fill(src, color: img.ColorRgb8(30, 120, 200));
      final jpg = Uint8List.fromList(img.encodeJpg(src));
      final before = sha256Hex(jpg);
      final at = DateTime.utc(2026, 11, 9, 8, 20, 5);
      expect(dhakaStamp(at), '2026-11-09 14:20:05 +06:00');
      expect(watermarkLabel(201, at, camera: 'Till'),
          'ASSISTO CCTV | alert #201 | 2026-11-09 14:20:05 +06:00 | Till');
      final copies = watermarkedCopies(
          [EvidenceFile('photo.jpg', jpg, at: at), EvidenceFile('clip/sd_clip_10s.ts', Uint8List(10))],
          201);
      expect(copies.map((c) => c.name), ['watermarked/photo.jpg']);
      expect(sha256Hex(jpg), before); // original bytes unchanged
      final w = img.decodeJpg(copies.first.bytes)!;
      expect((w.width, w.height), (640, 360));
      final p = w.getPixel(5, 355); // inside the dark band
      expect(p.r < 90 && p.g < 90 && p.b < 90, isTrue);
      expect(watermarkJpeg(Uint8List.fromList([1, 2, 3]), 'x'), isNull);
    });
  });

  group('manager screens (E, F, G, D automations)', () {
    testWidgets('closing report shows the lines, hourly bars and settings', (tester) async {
      final act = FakeCctvAct();
      await tester.pumpWidget(_app(CctvClosingReportScreen(source: act, siteId: 1, owner: true)));
      await tester.pumpAndSettle();
      expect(find.text('Counter left empty for 1 h 35 min while open'), findsOneWidget);
      expect(find.text('People by hour'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-use-parking')));
      await tester.tap(find.byKey(const ValueKey('cv3-use-parking')));
      await tester.pumpAndSettle();
      expect(act.calls, contains('cfg:use'));
    });

    testWidgets('ask: an example runs and the results open as rows', (tester) async {
      final act = FakeCctvAct();
      await tester.pumpWidget(_app(CctvAskScreen(source: act, siteId: 1)));
      await tester.pumpAndSettle();
      await _tapText(tester, 'Show the red car at the gate');
      expect(act.calls, contains('ask:Show the red car at the gate'));
      expect(find.text('Found 2 events — first 14:05, last 14:41.'), findsOneWidget);
      expect(find.textContaining('no face recognition'), findsWidgets);
      expect(find.text('Searched 14:00 – 15:00'), findsOneWidget);
    });

    testWidgets('sales match: review-only, POS secret shown once, CSV import', (tester) async {
      final act = FakeCctvAct();
      await tester.pumpWidget(_app(CctvSalesMatchScreen(source: act, siteId: 1)));
      await tester.pumpAndSettle();
      expect(find.textContaining('not an accusation'), findsOneWidget);
      expect(find.textContaining('Cash drawer opened at 15:12'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-pos-link')));
      await tester.tap(find.byKey(const ValueKey('cv3-pos-link')));
      await tester.pumpAndSettle();
      await _tapText(tester, 'Asalify POS');
      expect(act.calls, contains('key:asalify'));
      expect(find.textContaining('ask_sample_secret_only_for_tests'), findsOneWidget);
      await _tapText(tester, 'Copy');
      await tester.ensureVisible(find.byKey(const ValueKey('cv3-csv')));
      await tester.tap(find.byKey(const ValueKey('cv3-csv')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('cv3-csv-field')),
          'time,type,amount,id\n2026-11-09 14:05,sale,350,S1');
      await _tapText(tester, 'Import');
      expect(act.calls.any((c) => c.startsWith('csv:')), isTrue);
    });

    testWidgets('automations: empty -> link; rule toggles save; test a plug', (tester) async {
      final act = FakeCctvAct();
      await tester.pumpWidget(_app(CctvAutomationsScreen(
          source: act, siteId: 1, preview: fakeAuto(linked: false))));
      await tester.pumpAndSettle();
      expect(find.text('Scare them away before they come in'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cv3-auto-link')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('cv3-link-uid')), 'ay1234567890');
      await _tapText(tester, 'Link');
      expect(act.calls.any((c) => c.startsWith('link:own:ay1234567890')), isTrue);
      expect(find.byKey(const ValueKey('cv3-rule-night_intrusion')), findsOneWidget);
      expect(find.text('Door lock — asks you first, every time'), findsWidgets);
      await tester.ensureVisible(find.text('Shop siren').first);
      await tester.tap(find.text('Shop siren').first);
      await tester.pumpAndSettle();
      expect(act.calls.any((c) => c.startsWith('rules:')), isTrue);
      await tester.ensureVisible(find.text('Test').first);
      await tester.tap(find.text('Test').first);
      await tester.pumpAndSettle();
      expect(act.calls, contains('test:plug1'));
    });
  });

  group('gallery states render in bn + en at 200 %', () {
    for (final e in cctvactShots.entries) {
      for (final lang in ['bn', 'en']) {
        testWidgets('${e.key} $lang', (tester) async {
          tester.view.physicalSize = const Size(720, 1600);
          tester.view.devicePixelRatio = 2.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
