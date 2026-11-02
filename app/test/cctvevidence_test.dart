// cctvevidence (W7) — evidence pack with the SD clip + the Bangla PDF
// (every file's SHA-256, address, GD draft), the camera's Recording &
// evidence screen (SD health, video add-on purchase, address, honest vendor
// limits), the alert sheet's SD-clip row; 200 % text, dark, Bangla digits,
// 48 dp targets.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/cctvx/evidence_pack.dart';
import 'package:assisto/cctvx/evidence_pdf.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/shop_box_screen.dart' show ShopSiteForm;
import 'package:assisto/screens/watchman/cctv_recording_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctvevidence_fakes.dart';
import 'cctvevidence_shots.dart';
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

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 1600}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

const _words = EvPdfWords(
  title: 'Evidence pack — alert no. 7',
  shop: 'Shop',
  address: 'Address',
  camera: 'Camera',
  when: 'Time',
  what: 'What happened',
  photo: 'Alert photo',
  files: 'Files and their SHA-256 fingerprints',
  howCheck: 'sha256sum -c SHA256SUMS.txt',
  letter: 'Draft GD',
  footer: 'Made on this phone',
);

void main() {
  group('evidence pack + PDF', () {
    test('the SD clip is a file of its own with its time and hash', () {
      final clip = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
      final at = DateTime.utc(2026, 11, 3, 3, 59, 56);
      final media = evidenceMedia(
          photo: Uint8List.fromList([1, 2, 3]), alertAt: at, sdClip: clip, sdClipStart: at);
      expect(media.map((f) => f.name), ['photo.jpg', 'clip/sd_clip_10s.ts']);
      final manifest = evidenceManifest(media, {'event_id': 7}, exportedAt: at);
      final m = jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>;
      final files = (m['files'] as List).cast<Map<String, dynamic>>();
      expect(files[1]['sha256'], sha256Hex(clip));
      expect(files[1]['time'], at.toIso8601String());
    });

    test('the PDF goes into the ZIP and into SHA256SUMS', () {
      final media = evidenceMedia(photo: Uint8List.fromList([9, 9, 9]));
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.4 fake'));
      final zip = assembleEvidencePack(
          media: media,
          manifest: evidenceManifest(media, const {}, exportedAt: DateTime.utc(2026)),
          letter: 'GD',
          now: DateTime(2026, 11, 3),
          extra: [EvidenceFile('evidence_bn.pdf', pdf)]);
      final entries = readStoredZip(zip);
      expect(entries.keys, containsAll(['evidence_bn.pdf', 'SHA256SUMS.txt', 'gd_letter.txt']));
      expect(utf8.decode(entries['SHA256SUMS.txt']!), contains('${sha256Hex(pdf)}  evidence_bn.pdf'));
    });

    test('PDF blocks: facts with address, every file hash, the letter, photo only if any', () {
      final files = [
        EvidenceFile('photo.jpg', Uint8List.fromList([1, 2])),
        EvidenceFile('clip/sd_clip_10s.ts', Uint8List.fromList([3, 4, 5])),
      ];
      final b = evidencePdfBlocks(
          w: _words,
          facts: {'shop': 'Mirpur shop, 12 Mirpur Road', 'address': '12 Mirpur Road',
                  'camera': 'Gate', 'when': '2026-11-03 10:00:00', 'what': 'Person seen'},
          files: files,
          letter: 'To\nThe OC\n\nPlease record this GD.',
          photo: null);
      final text = b.map((x) => x.text).join('\n');
      expect(b.first.kind, 'title');
      expect(text, contains('Address: 12 Mirpur Road'));
      expect(text, contains(sha256Hex(files[1].bytes)));
      expect(text, contains('Please record this GD.'));
      expect(b.where((x) => x.kind == 'img'), isEmpty);
      final withPhoto = evidencePdfBlocks(
          w: _words, facts: const {}, files: files, letter: '', photo: Uint8List.fromList([1]));
      expect(withPhoto.where((x) => x.kind == 'img').length, 1);
    });

    testWidgets('the PDF renders to real PDF bytes', (tester) async {
      Uint8List? pdf;
      await tester.runAsync(() async {
        pdf = await buildEvidencePdf(evidencePdfBlocks(
            w: _words,
            facts: const {'shop': 'Shop', 'when': '2026-11-03'},
            files: [EvidenceFile('photo.jpg', Uint8List.fromList([1, 2, 3]))],
            letter: List.filled(40, 'A long paragraph of the GD draft.').join('\n\n')));
      });
      expect(pdf, isNotNull);
      expect(ascii.decode(pdf!.sublist(0, 5)), '%PDF-');
      expect(pdf!.length, greaterThan(1000));
    });
  });

  group('shop box retention slider (never more than the server keeps)', () {
    Future<Object?> openForm(WidgetTester tester, ShopSiteForm form, {String lang = 'en'}) async {
      Object? result;
      await tester.pumpWidget(_app(
          Builder(
              builder: (ctx) => Scaffold(
                  body: Center(
                      child: TextButton(
                          onPressed: () async {
                            result = await Navigator.of(ctx)
                                .push(MaterialPageRoute(builder: (_) => Scaffold(body: form)));
                          },
                          child: const Text('open'))))),
          lang: lang));
      await tester.tap(find.text('open'));
      await _settle(tester);
      return result;
    }

    testWidgets('base plan: max 7, reason line + add-on link', (tester) async {
      _phone(tester);
      await openForm(tester,
          const ShopSiteForm(initialName: 'Shop', initialRetention: 30, maxDays: 7, addonCameraId: 11));
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, 7);
      expect(slider.value, 7);                      // an older 30 is shown capped
      expect(find.textContaining('Up to 7 days'), findsOneWidget);
      expect(find.text('See the video add-on'), findsOneWidget);
    });

    testWidgets('the add-on link returns the camera to open', (tester) async {
      _phone(tester);
      Object? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Scaffold(
              body: Center(
                  child: TextButton(
                      onPressed: () async {
                        got = await Navigator.of(ctx).push(MaterialPageRoute(
                            builder: (_) => const Scaffold(
                                body: ShopSiteForm(maxDays: 7, addonCameraId: 11))));
                      },
                      child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.ensureVisible(find.text('See the video add-on'));
      await tester.tap(find.text('See the video add-on'));
      await _settle(tester);
      expect(got, {'addon': 11});
    });

    testWidgets('30-day add-on: max 30, no reason line', (tester) async {
      _phone(tester);
      await openForm(tester, const ShopSiteForm(initialRetention: 20, maxDays: 30, addonCameraId: 11));
      expect(tester.widget<Slider>(find.byType(Slider)).max, 30);
      expect(find.textContaining('Up to'), findsNothing);
      expect(find.text('See the video add-on'), findsNothing);
    });

    testWidgets('Bangla digits in the reason line', (tester) async {
      _phone(tester);
      await openForm(tester, const ShopSiteForm(maxDays: 7), lang: 'bn');
      expect(find.textContaining('সর্বোচ্চ ৭ দিন'), findsOneWidget);
      expect(find.text('See the video add-on'), findsNothing);   // no camera yet
    });
  });

  group('recording & evidence screen', () {
    testWidgets('SD health, days, prices and buying the add-on', (tester) async {
      _phone(tester);
      final src = FakeCctvEvidence();
      await tester.pumpWidget(_app(CctvRecordingScreen(source: src, cameraId: 11, cameraName: 'Gate')));
      await _settle(tester);
      expect(src.calls, ['recording:11:false']);
      expect(find.text('SD card OK'), findsOneWidget);
      expect(find.textContaining('5.8 days'), findsOneWidget);
      expect(find.text('Keep 7 days — 100 tk a month'), findsOneWidget);
      expect(find.text('Keep 30 days — 150 tk a month'), findsOneWidget);
      expect(find.text('Clips today: 3 of 30'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Get').last);
      await _settle(tester);
      expect(find.text('Get the video add-on?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Get').last);
      await _settle(tester);
      expect(src.calls, contains('buy:11:30d'));
      expect(find.text('The video add-on is on.'), findsOneWidget);
      expect(find.textContaining('On — clips kept 30 days'), findsOneWidget);
      expect(find.text('Add a month'), findsOneWidget);
    });

    testWidgets('no credits: the server reason, nothing turned on', (tester) async {
      _phone(tester);
      final src = FakeCctvEvidence('nocredit');
      await tester.pumpWidget(_app(CctvRecordingScreen(source: src, cameraId: 11)));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Get').first);
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Get').last);
      await _settle(tester);
      expect(find.text('Not enough credits.'), findsOneWidget);
      expect(find.textContaining('Off — only alert photos'), findsOneWidget);
    });

    testWidgets('Imou: honest "cannot download" line; address saved', (tester) async {
      _phone(tester);
      final src = FakeCctvEvidence('imou');
      await tester.pumpWidget(_app(CctvRecordingScreen(source: src, cameraId: 12)));
      await _settle(tester);
      expect(find.textContaining('cannot download SD-card video'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '5 Gulshan Ave, Dhaka');
      await tester.ensureVisible(find.text('Save address'));
      await _settle(tester, 4);
      await tester.tap(find.text('Save address'));
      await _settle(tester);
      expect(src.calls, contains('address:1:5 Gulshan Ave, Dhaka'));
      expect(find.text('Address saved.'), findsOneWidget);
    });

    testWidgets('error state has a retry', (tester) async {
      _phone(tester);
      final src = FakeCctvEvidence('fail');
      await tester.pumpWidget(_app(CctvRecordingScreen(source: src, cameraId: 11)));
      await _settle(tester);
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(src.calls.length, 2);
    });

    testWidgets('Bangla digits in bn', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          CctvRecordingScreen(source: FakeCctvEvidence(), cameraId: 11, preview: fakeRecording()),
          lang: 'bn'));
      await _settle(tester);
      expect(find.textContaining('৫.৮'), findsOneWidget);
      expect(find.textContaining('১০০'), findsWidgets);
      expect(find.textContaining('5.8'), findsNothing);
    });

    testWidgets('48 dp targets', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          CctvRecordingScreen(source: FakeCctvEvidence(), cameraId: 11, preview: fakeRecording())));
      await _settle(tester);
      for (final f in [find.byType(FilledButton), find.byType(OutlinedButton)]) {
        expect(f, findsWidgets);
        for (final e in f.evaluate()) {
          expect((e.renderObject! as RenderBox).size.height, greaterThanOrEqualTo(48));
        }
      }
    });

    testWidgets('alert sheet: SD clip row ready / pending', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(cctvevidenceShots['cev_alert_sd_ready']!('en')));
      await _settle(tester);
      expect(find.text('Watch the 10-second SD clip'), findsOneWidget);
      expect(find.textContaining('Kept encrypted until'), findsOneWidget);
      expect(find.text('Photo, clip, times, address, SHA-256 and a Bangla PDF — in one tap'),
          findsOneWidget);
      await tester.pumpWidget(_app(cctvevidenceShots['cev_alert_sd_pending']!('en')));
      await _settle(tester);
      expect(find.textContaining('Fetching the clip'), findsOneWidget);
    });

    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('cctvevidence screens at 200% text — $lang ${dark ? 'dark' : 'light'}',
            (tester) async {
          _phone(tester, height: 800);
          for (final e in cctvevidenceShots.entries) {
            await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
            await _settle(tester, 8);
            final err = tester.takeException();
            expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
          }
        });
      }
    }
  });
}
