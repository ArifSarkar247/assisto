// cashguard — Smart Cash Guard on the app side:
//   * the clip crypto opens the SAME fixed vector the Shop Box edge seals
//     (tools/cashguard/clip_vector.json) — cross-language proof, no server;
//   * a Guard Box clip sealed in Dart opens with the owner's key, never with
//     another key, and tampering is caught;
//   * Guard Box engine: motion inside the cash polygon -> ONE alert with a
//     snapshot + clip_ref -> after the post-roll ONE sealed clip upload;
//     cooldown; a person OUTSIDE the zone is not a cash alert; timing;
//   * LAN helpers: RFC 2617 digest vector, WS-Discovery / ONVIF parsing;
//   * screens: cash alert wording + clip button, clip player plays and tells
//     the server the owner watched it, away mode, 200% text bn/en dark/light.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/cashguard/clip_crypto.dart';
import 'package:assisto/cashguard/guard_box_engine.dart';
import 'package:assisto/cashguard/guard_box_net.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/cash_guard_clip.dart';
import 'package:assisto/screens/watchman/cash_guard_screen.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cashguard_fakes.dart';
import 'cashguard_shots.dart';
import 'fake_api.dart';

Map<String, dynamic> _vector() =>
    jsonDecode(File('../tools/cashguard/clip_vector.json').readAsStringSync()) as Map<String, dynamic>;

IdentityKeyPair _vectorKey(Map<String, dynamic> v) {
  final priv = base64Decode(v['recipient_private'] as String);
  final pub = X25519.scalarMultBase(priv);
  final kid = (v['meta']['wraps']['7']['key_id'] as String);
  return IdentityKeyPair(priv, pub, kid);
}

Map<String, dynamic> _metaFor(Map<String, dynamic> meta, String uid) {
  final m = Map<String, dynamic>.from(meta);
  m['wrap'] = (meta['wraps'] as Map)[uid];
  m.remove('wraps');
  return m;
}

class _FakeDevice implements GuardDevice {
  final List<Map<String, dynamic>> ingests = [];
  final List<(String, Map<String, dynamic>, Uint8List)> clips = [];
  @override
  Future<(int, Map<String, dynamic>)> ingest(String type, Map<String, dynamic> signals,
      {Uint8List? snapshot, String? clipRef}) async {
    ingests.add({'type': type, 'signals': signals, 'snap': snapshot?.length ?? 0, 'ref': clipRef});
    return (201, {'raised': true, 'clip_wanted': true});
  }

  @override
  Future<(int, Map<String, dynamic>)> uploadClip(String ref, Map<String, dynamic> meta, Uint8List blob) async {
    clips.add((ref, meta, blob));
    return (201, {'ok': true});
  }
}

/// A 64x48 grey frame; when [hand] the cash area (lower-left) is bright.
GrayFrame _frame({bool hand = false, bool elsewhere = false}) {
  const w = 64, h = 48;
  final y = Uint8List(w * h)..fillRange(0, w * h, 60);
  for (var r = 0; r < h; r++) {
    for (var c = 0; c < w; c++) {
      final inCash = c < 32 && r >= 24;
      final inOther = c >= 40 && r < 16;
      if ((hand && inCash) || (elsewhere && inOther)) y[r * w + c] = 220;
    }
  }
  return GrayFrame(w, h, y);
}

const _cash = [
  [0.0, 0.5],
  [0.5, 0.5],
  [0.5, 1.0],
  [0.0, 1.0]
];

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

late AppLocalizations en;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('clip crypto', () {
    test('opens the edge-sealed fixed vector (Python cryptography -> Dart)', () {
      final v = _vector();
      final clip = openClip(
          meta: _metaFor(v['meta'] as Map<String, dynamic>, '7'),
          ciphertext: base64Decode(v['ciphertext'] as String),
          keys: [_vectorKey(v)]);
      expect(clip.frames.length, 16);
      expect(utf8.decode(clip.frames.first, allowMalformed: true), contains('FAKEJPEG0'));
      expect(clip.durationS, closeTo(4.0, 0.01));
    });

    test('a stranger key cannot open it; tampering is caught', () {
      final v = _vector();
      final stranger = SoftwareE2E(Random(1)).generateIdentity();
      expect(
          () => openClip(
              meta: _metaFor(v['meta'] as Map<String, dynamic>, '7'),
              ciphertext: base64Decode(v['ciphertext'] as String),
              keys: [stranger]),
          throwsA(isA<ClipOpenError>().having((e) => e.code, 'code', 'no_key')));
      final ct = base64Decode(v['ciphertext'] as String);
      ct[5] ^= 1;
      expect(
          () => openClip(
              meta: _metaFor(v['meta'] as Map<String, dynamic>, '7'), ciphertext: ct, keys: [_vectorKey(v)]),
          throwsA(isA<ClipOpenError>().having((e) => e.code, 'code', 'bad_clip')));
    });

    test('Guard Box seal (Dart) opens with the owner key, envelope has the server shape', () {
      final rng = Random(7);
      final owner = SoftwareE2E(rng).generateIdentity();
      final frames = [for (var i = 0; i < 8; i++) (100.0 + i * 0.5, Uint8List.fromList([0xff, 0xd8, i, 0xff, 0xd9]))];
      final plain = encodeContainer(frames, 2);
      final sealed = sealClip(
          plain, [{'uid': 3, 'key_id': owner.keyId, 'pub': owner.publicKeyB64}], 2, 4.0, rng: rng);
      final m = sealed.meta;
      expect(m['scheme'], kClipScheme);
      expect(m['aad'], kClipAad);
      expect(base64Decode(m['nonce'] as String).length, 12);
      expect(base64Decode(m['eph_pub'] as String).length, 32);
      final wrap = (m['wraps'] as Map)['3'] as Map;
      expect(base64Decode(wrap['ct'] as String).length, 60); // base64(K) + tag
      final clip = openClip(meta: _metaFor(m, '3'), ciphertext: sealed.ct, keys: [owner]);
      expect(clip.frames.length, 8);
      expect(clip.frames[3], [0xff, 0xd8, 3, 0xff, 0xd9]);
      // the ciphertext carries no readable container
      expect(utf8.decode(sealed.ct, allowMalformed: true).contains('ACG1'), isFalse);
    });
  });

  group('guard box engine', () {
    test('zone motion only in the cash polygon, debounced', () {
      final m = ZoneMotion(zone: _cash);
      expect(m.feed(_frame()).inZone, isFalse); // background
      expect(m.feed(_frame(elsewhere: true)).inZone, isFalse); // not the cash area
      m.feed(_frame());
      expect(m.feed(_frame(hand: true)).inZone, isFalse); // 1st frame: not yet
      expect(m.feed(_frame(hand: true)).inZone, isTrue); // confirmed
    });

    test('alert with snapshot + clip_ref, then ONE sealed clip; cooldown', () async {
      final rng = Random(3);
      final owner = SoftwareE2E(rng).generateIdentity();
      final dev = _FakeDevice();
      var t = 1000.0;
      var hand = false;
      final eng = GuardBoxEngine(
        device: dev,
        fetch: () async => Uint8List.fromList([0xff, 0xd8, (t * 2).round() & 0xff, 0xff, 0xd9]),
        decode: (_) async => _frame(hand: hand),
        clock: () => t,
        rng: rng,
      );
      eng.applyConfig({
        'clip': {'enabled': true, 'recipients': [{'uid': 9, 'key_id': owner.keyId, 'pub': owner.publicKeyB64}]},
        'cameras': [
          {'id': 12, 'zones': {'zones': [{'type': 'cash', 'points': _cash}]}, 'tuning': {'cooldown_s': 180}}
        ],
      });
      expect(eng.hasZone, isTrue);
      for (var i = 0; i < 6; i++) {
        await eng.tick();
        t += 0.5;
      }
      hand = true;
      for (var i = 0; i < 4; i++) {
        await eng.tick();
        t += 0.5;
      }
      expect(dev.ingests.length, 1);
      final a = dev.ingests.first;
      expect(a['type'], 'motion'); // no model: honest motion-only
      expect((a['signals'] as Map)['detector'], 'motion_only');
      expect((a['signals'] as Map)['zone_breach'], isTrue);
      expect(a['snap'], greaterThan(0));
      expect((a['ref'] as String).length, 32);
      hand = false;
      for (var i = 0; i < 8; i++) {
        await eng.tick();
        t += 0.5;
      }
      expect(dev.clips.length, 1);
      final (ref, meta, blob) = dev.clips.first;
      expect(ref, a['ref']);
      expect(meta['duration_s'], inInclusiveRange(2.5, 5.5));
      expect(meta['frames'], greaterThanOrEqualTo(3));
      final clip = openClip(meta: _metaFor(meta, '9'), ciphertext: blob, keys: [owner]);
      expect(clip.frames.length, meta['frames']);
      // cooldown: more motion inside 180 s raises nothing new
      hand = true;
      for (var i = 0; i < 4; i++) {
        await eng.tick();
        t += 0.5;
      }
      expect(dev.ingests.length, 1);
      expect(eng.stats.events, 1);
      expect(eng.stats.clipsSent, 1);
    });

    test('with the person model: a person OUTSIDE the cash zone is not a cash alert', () async {
      final dev = _FakeDevice();
      var t = 0.0;
      var hand = false;
      final eng = GuardBoxEngine(
        device: dev,
        fetch: () async => Uint8List.fromList([0xff, 0xd8, 1, 0xff, 0xd9]),
        decode: (_) async => _frame(hand: hand),
        detect: (_) async => [
          [0.7, 0.0, 0.95, 0.3, 0.9]
        ],
        clock: () => t,
        cashZone: _cash,
      );
      for (var i = 0; i < 3; i++) {
        await eng.tick();
        t += 0.5;
      }
      hand = true;
      for (var i = 0; i < 4; i++) {
        await eng.tick();
        t += 0.5;
      }
      expect(dev.ingests, isEmpty);
      expect(eng.stats.detector, 'yolox_nano');
    });

    test('timing: motion + seal on CI host (reported, not a phone number)', () async {
      final rng = Random(11);
      final owner = SoftwareE2E(rng).generateIdentity();
      final m = ZoneMotion(zone: _cash);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        m.feed(_frame(hand: i.isOdd));
      }
      final motionMs = sw.elapsedMicroseconds / 1000 / 200;
      final jpeg = Uint8List(40 * 1024);
      final frames = [for (var i = 0; i < 9; i++) (i * 0.5, jpeg)];
      sw.reset();
      final plain = encodeContainer(frames, 2);
      sealClip(plain, [{'uid': 1, 'key_id': owner.keyId, 'pub': owner.publicKeyB64}], 2, 4.5, rng: rng);
      final sealMs = sw.elapsedMicroseconds / 1000;
      // ignore: avoid_print
      print('CASHGUARD_BENCH ${jsonEncode({'motion_ms_per_frame': motionMs, 'seal_ms_360kb_clip': sealMs})}');
      expect(motionMs, lessThan(20));
    });
  });

  group('LAN helpers', () {
    test('digest auth matches the RFC 2617 example', () {
      final h = digestHeader(
          'Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"',
          'GET',
          Uri.parse('http://www.nowhere.org/dir/index.html'),
          'Mufasa',
          'Circle Of Life',
          cnonce: '0a4f113b');
      expect(h, contains('response="6629fae49393a05397450978507c4ef1"'));
      expect(h, contains('opaque="5ccc069c403ebaf9f0171e9517f40e41"'));
    });

    test('WS-Discovery + ONVIF answers parse', () {
      const probe = '<d:ProbeMatches><d:ProbeMatch><d:XAddrs>http://192.168.1.64/onvif/device_service '
          'http://[fe80::1]/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches>';
      expect(parseXAddrs(probe), ['http://192.168.1.64/onvif/device_service']);
      const caps = '<tt:Media><tt:XAddr>http://192.168.1.64/onvif/Media</tt:XAddr></tt:Media>';
      expect(mediaXAddr(caps), 'http://192.168.1.64/onvif/Media');
      const prof = '<trt:Profiles token="Profile_1" fixed="true"><tt:Name>main</tt:Name></trt:Profiles>';
      expect(firstProfileToken(prof), 'Profile_1');
      const snap = '<trt:MediaUri><tt:Uri>http://192.168.1.64/onvif-http/snapshot?Profile_1&amp;x=1</tt:Uri></trt:MediaUri>';
      expect(xmlFirst(snap, 'Uri'), 'http://192.168.1.64/onvif-http/snapshot?Profile_1&amp;x=1');
      expect(vendorSnapshotUrls('hikvision', '10.0.0.5').single,
          'http://10.0.0.5/ISAPI/Streaming/channels/101/picture');
    });
  });

  group('screens', () {
    testWidgets('cash alert: never accusing, away pill, clip opens the player', (tester) async {
      _phone(tester);
      final cash = FakeCashGuard()..clipStatus = 'pending';
      await tester.pumpWidget(_app(
          WatchmanAlertsScreen(source: FakeWatchmanCash(), siteId: 1, owner: true, cash: cash)));
      await _settle(tester);
      expect(find.text(en.cgPossibleCashRemoval), findsNWidgets(2));
      expect(find.text(en.cgAwayPill), findsOneWidget);
      expect(find.text(en.cgClipWatchedGone), findsOneWidget);
      expect(find.textContaining('theft'), findsNothing);
      await tester.tap(find.text(en.cgWatchClip));
      await _settle(tester);
      expect(find.text(en.cgDecideTitle), findsOneWidget);
      expect(find.text(en.cgClipPending), findsOneWidget);
      expect(cash.calls, contains('clip:201'));
    });

    testWidgets('clip player: decrypts on the phone, plays, owner watch deletes', (tester) async {
      _phone(tester);
      final rng = Random(5);
      final owner = SoftwareE2E(rng).generateIdentity();
      final frames = [for (var i = 0; i < 8; i++) (i * 0.5, kTinyPng)];
      final sealed = sealClip(encodeContainer(frames, 2),
          [{'uid': 1, 'key_id': owner.keyId, 'pub': owner.publicKeyB64}], 2, 4.0, rng: rng);
      final cash = FakeCashGuard()
        ..clipMeta = _metaFor(sealed.meta, '1')
        ..clipBytes = sealed.ct
        ..keys = [owner];
      await tester.pumpWidget(_app(Scaffold(body: CashClipSheet(source: cash, eventId: 201, owner: true))));
      await _settle(tester, 4); // small clip: decrypted inline, no isolate
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(cash.calls, containsAll(['clip:201', 'download']));
      expect(find.text(en.cgClipSeconds('4')), findsOneWidget);
      expect(cash.calls, contains('viewed:201'));
      expect(find.text(en.cgClipDeletedNow), findsOneWidget);
    });

    testWidgets('a deleted clip says so honestly', (tester) async {
      _phone(tester);
      final cash = FakeCashGuard()..clipStatus = 'viewed';
      await tester.pumpWidget(_app(Scaffold(body: CashClipSheet(source: cash, eventId: 7, owner: true))));
      await _settle(tester);
      expect(find.textContaining('deleted'), findsWidgets);
    });

    testWidgets('away mode: I am away for 4 hours', (tester) async {
      _phone(tester);
      final cash = FakeCashGuard();
      await tester.pumpWidget(_app(CashGuardScreen(source: cash, siteId: 1)));
      await _settle(tester);
      expect(find.text(en.cgHandPocketOff), findsOneWidget);
      expect(find.text(en.cgPlanCaps('1', '5', '1')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, en.cgImAway));
      await _settle(tester);
      await tester.tap(find.text(en.cgAwayHours('4')));
      await _settle(tester);
      expect(cash.lastAway, {'on': true, 'hours': 4});
      expect(find.text(en.cgAwayOnSaved), findsOneWidget);
    });

    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('cash guard screens at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
          _phone(tester, height: 800);
          for (final e in cashguardShots.entries) {
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
