// cctvx — CCTV extras on the app side:
//   * clip SHARE crypto: the owner's phone unwraps the edge-sealed key and
//     re-wraps it for ONE Circle member; the member opens the same clip, a
//     stranger cannot (no server involved);
//   * evidence pack: stored ZIP round-trip with CRC-32, manifest SHA-256 of
//     every file, SHA256SUMS.txt, the GD letter quoting the manifest hash;
//   * privacy-kit PDF: a valid one-page PDF (A4 / A5) around an RGB picture;
//   * screens: guard settings save + bounds + escalation chain, alert actions
//     (honest siren reason, call the shop, 999 asks first), placement tips,
//     privacy kit, alerts passed to me — bn/en, light/dark, 200 % text.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/cashguard/clip_crypto.dart';
import 'package:assisto/cashguard/guard_box_engine.dart';
import 'package:assisto/cctvx/evidence_pack.dart';
import 'package:assisto/cctvx/mini_pdf.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';
import 'package:assisto/screens/watchman/cctvx_guard_screen.dart';
import 'package:assisto/screens/watchman/cctvx_inbox.dart';
import 'package:assisto/screens/watchman/cctvx_placement.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cashguard_fakes.dart';
import 'cctvx_fakes.dart';
import 'cctvx_shots.dart';
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

Map<String, dynamic> _metaFor(Map<String, dynamic> meta, String uid) {
  final m = Map<String, dynamic>.from(meta);
  m['wrap'] = (meta['wraps'] as Map)[uid];
  m.remove('wraps');
  return m;
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('clip share crypto', () {
    test('owner re-wraps for one member; the member opens it, a stranger cannot', () {
      final rng = Random(11);
      final e2e = SoftwareE2E(rng);
      final owner = e2e.generateIdentity();
      final member = e2e.generateIdentity();
      final stranger = e2e.generateIdentity();
      final frames = [for (var i = 0; i < 6; i++) (i * 0.25, kTinyPng)];
      final sealed = sealClip(encodeContainer(frames, 4),
          [{'uid': 1, 'key_id': owner.keyId, 'pub': owner.publicKeyB64}], 4, 1.5, rng: rng);
      final ownerMeta = _metaFor(sealed.meta, '1');
      final k = unwrapClipKey(meta: ownerMeta, keys: [owner]);
      expect(k.length, 32);
      final wrap = wrapClipKeyFor(
          contentKey: k, me: owner, memberPublicKey: member.publicKey, memberKeyId: member.keyId);
      expect(wrap.keys.toSet(), {'key_id', 'nonce', 'ct', 'sender_pub', 'sender_key_id'});
      expect(wrap['sender_pub'], owner.publicKeyB64);
      final memberMeta = Map<String, dynamic>.from(ownerMeta)..['wrap'] = wrap;
      final clip = openClip(meta: memberMeta, ciphertext: sealed.ct, keys: [member]);
      expect(clip.frames.length, 6);
      expect(clip.frames.first, kTinyPng);
      expect(() => openClip(meta: memberMeta, ciphertext: sealed.ct, keys: [stranger]),
          throwsA(isA<ClipOpenError>()));
      // the owner's own wrap still opens for the owner (nothing changed)
      expect(openClip(meta: ownerMeta, ciphertext: sealed.ct, keys: [owner]).frames.length, 6);
    });
  });

  group('evidence pack', () {
    test('crc32 vector', () {
      expect(crc32(utf8.encode('123456789')), 0xCBF43926);
    });

    test('zip round-trip, manifest + SHA256SUMS + GD letter with the manifest hash', () {
      final at = DateTime.utc(2026, 10, 28, 4, 0, 0);
      final media = evidenceMedia(
          photo: Uint8List.fromList([0xFF, 0xD8, 1, 2, 3]),
          alertAt: at,
          frames: [Uint8List.fromList([0xFF, 0xD8, 9]), Uint8List.fromList([0xFF, 0xD8, 8])],
          frameTimes: [0.0, 0.2],
          clipStart: at);
      expect(media.map((f) => f.name), ['photo.jpg', 'clip/frame_001.jpg', 'clip/frame_002.jpg']);
      final manifest = evidenceManifest(media, {'event_id': 7}, exportedAt: at);
      final mh = sha256Hex(manifest);
      final zip = assembleEvidencePack(
          media: media, manifest: manifest, letter: 'GD — manifest $mh', now: at);
      final files = readStoredZip(zip);
      expect(files.keys, containsAll(['photo.jpg', 'clip/frame_002.jpg', 'manifest.json',
                                      'gd_letter.txt', 'SHA256SUMS.txt']));
      final m = jsonDecode(utf8.decode(files['manifest.json']!)) as Map<String, dynamic>;
      expect(m['hash'], 'sha256');
      final listed = {for (final f in m['files'] as List) f['name']: f['sha256']};
      expect(listed['photo.jpg'], sha256Hex(media.first.bytes));
      expect(listed['clip/frame_002.jpg'], sha256Hex(files['clip/frame_002.jpg']!));
      expect(((m['files'] as List)[2] as Map)['time'], '2026-10-28T04:00:00.200Z');
      expect(sha256Hex(files['manifest.json']!), mh);
      expect(utf8.decode(files['gd_letter.txt']!), contains(mh));
      final sums = utf8.decode(files['SHA256SUMS.txt']!);
      expect(sums, contains('$mh  manifest.json'));
      expect(sums, contains('${sha256Hex(files['gd_letter.txt']!)}  gd_letter.txt'));
    });

    test('a corrupted entry is caught', () {
      final zip = storedZip([EvidenceFile('a.txt', Uint8List.fromList(utf8.encode('hello')))],
          when: DateTime(2026, 10, 28));
      zip[30 + 5] ^= 0x01; // flip a byte of the data
      expect(() => readStoredZip(zip), throwsFormatException);
    });
  });

  group('privacy-kit pdf', () {
    test('one valid page, A4 and A5, image fitted', () {
      final rgba = Uint8List.fromList([for (var i = 0; i < 4 * 6; i++) i.isEven ? 255 : 0]);
      final rgb = rgbaToRgb(rgba);
      expect(rgb.length, 6 * 3);
      for (final p in PdfPaper.values) {
        final pdf = onePagePdf(rgb: rgb, width: 3, height: 2, paper: p);
        final head = latin1.decode(pdf.sublist(0, 8));
        expect(head, '%PDF-1.4');
        final text = latin1.decode(pdf, allowInvalid: true);
        expect(text, contains('/Subtype /Image /Width 3 /Height 2'));
        expect(text, contains(p == PdfPaper.a4 ? '595.28 841.89' : '419.53 595.28'));
        expect(text.trimRight().endsWith('%%EOF'), isTrue);
        final sx = text.lastIndexOf('startxref');
        final off = int.parse(text.substring(sx + 10).trim().split('\n').first);
        expect(text.substring(off, off + 4), 'xref');
      }
      expect(() => onePagePdf(rgb: rgb, width: 9, height: 9), throwsArgumentError);
    });
  });

  group('screens', () {
    testWidgets('guard settings: window saved, chain shown, phone saved', (tester) async {
      _phone(tester, height: 2600);
      final src = FakeCctvx();
      await tester.pumpWidget(_app(GuardSettingsScreen(source: src, siteId: 1,
          hours: const {'open': '09:00', 'close': '21:00'})));
      await _settle(tester);
      expect(find.text(en.cxNoSaleTitle), findsOneWidget);
      expect(find.text(en.cxNoSaleWindow('2')), findsOneWidget);
      expect(find.text('Karim (manager)'), findsOneWidget);
      expect(find.text(en.cxEscalationAfter('2')), findsOneWidget);
      await tester.tap(find.text(en.cxOfflineSwitch));
      await _settle(tester);
      expect(src.saved.last, {'offline_on': false});
      await tester.enterText(find.byType(TextField), '01811111111');
      await tester.tap(find.widgetWithText(FilledButton, en.cxSave));
      await _settle(tester);
      expect(src.saved.last, {'shop_phone': '01811111111'});
      expect(find.text(en.cxPhoneSaved), findsOneWidget);
      await tester.tap(find.byTooltip(en.cxRemove));
      await _settle(tester);
      expect(src.saved.last, {'escalation': <int>[]});
    });

    testWidgets('alert actions: honest siren reason, call the shop, 999 asks first', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(Scaffold(
          body: AlertActionsSheet(
              source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(), preview: kFakeEventActions))));
      await _settle(tester);
      expect(find.text(en.cxNoSaleTitle), findsOneWidget);
      expect(find.textContaining('no official way to sound the siren'), findsOneWidget);
      expect(find.text('01712345678'), findsOneWidget);
      await tester.tap(find.text(en.cx999));
      await _settle(tester);
      expect(find.text(en.cx999ConfirmTitle), findsOneWidget);
      await tester.tap(find.text(en.cxCancel));
      await _settle(tester);
      expect(find.text(en.cx999ConfirmTitle), findsNothing);
      expect(find.textContaining('theft'), findsNothing);
    });

    testWidgets('bangla digits in the actions sheet', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          Scaffold(
              body: AlertActionsSheet(
                  source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(), preview: kFakeEventActions)),
          lang: 'bn'));
      await _settle(tester);
      expect(find.text('০১৭১২৩৪৫৬৭৮'), findsOneWidget);
      expect(find.text(bn.cxCallShop), findsOneWidget);
    });

    testWidgets('placement: tips for the failed checks', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(Scaffold(
          body: PlacementSheet(source: FakeCctvx(), cameraId: 11, preview: kFakePlacementDark))));
      await _settle(tester);
      expect(find.text(en.cxPlacementScore('67')), findsOneWidget);
      expect(find.textContaining('dark'), findsOneWidget);
      expect(find.text(en.cxCheckGlare), findsOneWidget);
      await tester.tap(find.text(en.cxPlacementAgain));
      await _settle(tester);
      expect(find.text(en.cxPlacementChecked), findsOneWidget);
    });

    testWidgets('alerts passed to me: escalated one is marked seen', (tester) async {
      _phone(tester, height: 2000);
      final src = FakeCctvx();
      await tester.pumpWidget(_app(GuardInboxScreen(source: src, cash: FakeCashGuard())));
      await _settle(tester);
      expect(find.text(en.cxInboxPassed('Rahim')), findsOneWidget);
      expect(find.text(en.cxInboxShared('Rahim')), findsOneWidget);
      expect(src.calls, contains('opened:301'));
      expect(src.calls, isNot(contains('opened:302')));
    });

    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('cctvx screens at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
          _phone(tester, height: 800);
          for (final e in cctvxShots.entries) {
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
