// cctvplay (owner order 9 Nov 14:45, item 3): remote playback of the PHONE
// camera's alert clips — sealed preview (ACG1 frames) + sealed full MP4 open
// only with the viewer's key; the viewer's full-video panel: honest limits,
// ask -> wait -> play, rolled over / budget / offline states; bn + en, 200 %.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/cashguard/clip_crypto.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/video_ctl.dart';
import 'package:assisto/phonecam/phonecam_clips.dart';
import 'package:assisto/phonecam/phonecam_full_video.dart';
import 'package:assisto/theme.dart';

import 'cctvguard_fakes.dart' show FakeNetCtl;

Widget _app(Widget home, {String lang = 'en', double scale = 1.0}) => MaterialApp(
      key: UniqueKey(),
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: home)),
    );

Map<String, dynamic> _mine(Map<String, dynamic> meta, int uid) => {
      for (final e in meta.entries)
        if (e.key != 'wraps') e.key: e.value,
      'wrap': (meta['wraps'] as Map)['$uid'],
    };

class _Src implements PhoneCamClipSource {
  final List<Map<String, dynamic>> states;
  final Object? askError;
  int asks = 0, gets = 0;
  final Uint8List ct;
  final List<IdentityKeyPair> keys;
  _Src(this.states, {this.askError, Uint8List? ct, this.keys = const []}) : ct = ct ?? Uint8List(0);

  @override
  Future<Map<String, dynamic>> fullState(int eventId) async =>
      states[min(gets++, states.length - 1)];

  @override
  Future<Map<String, dynamic>> requestFull(int eventId) async {
    asks++;
    if (askError != null) throw askError!;
    return {...states.first, 'status': 'requested'};
  }

  @override
  Future<Uint8List> download(String url) async => ct;

  @override
  Future<List<IdentityKeyPair>> myKeys() async => keys;
}

Map<String, dynamic> _base(String status, {bool online = true}) => {
      'status': status,
      'camera_online': online,
      'clip_s': 10,
      'keep_h': 24,
      'est_mb': 1.5,
      'budget': {'cap_mb': 300, 'used_mb': 120.0, 'left_mb': 180.0, 'enforced': false, 'paused': false},
    };

void main() {
  final rng = Random(7);
  final e2e = SoftwareE2E(rng);
  final owner = e2e.generateIdentity();
  final family = e2e.generateIdentity();
  final stranger = e2e.generateIdentity();
  final recips = [
    {'uid': 1, 'key_id': owner.keyId, 'pub': owner.publicKeyB64},
    {'uid': 2, 'key_id': family.keyId, 'pub': family.publicKeyB64},
  ];

  group('pure', () {
    test('clip refs + file names', () {
      final r = newClipRef(rng);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(r), isTrue);
      expect(refOfClipName('/x/${clipFileName(r)}'), r);
      expect(refOfClipName('clip_1762675200000.mp4'), isNull); // older, unnamed clip
    });

    test('heartbeat block parsing', () {
      final c = PhoneClipCfg.fromJson({
        'enabled': true,
        'recipients': recips,
        'fps': 1.5,
        'width': 320,
        'max_kb': 600,
        'left_today': 19,
      });
      expect((c.enabled, c.canSeal, c.leftToday, c.maxKb), (true, true, 19, 600));
      expect(PhoneClipCfg.fromJson(null).enabled, isFalse);
      final q = VideoRequest.listFrom([
        {'key': 'e5', 'kind': 'event', 'ref': 'ab' * 16},
        {'key': 's1762675200', 'kind': 'segment', 'start': 1762675200},
        'junk',
      ]);
      expect(q.map((e) => (e.key, e.kind)).toList(), [('e5', 'event'), ('s1762675200', 'segment')]);
      expect(q.first.ref, 'ab' * 16);
    });

    test('preview: frames sealed for owner AND family, nobody else', () {
      final frames = [for (var i = 0; i < 15; i++) Uint8List.fromList(List.filled(900, i))];
      final s = buildPreview(frames, recips, maxKb: 600, rng: rng)!;
      expect(s.meta['format'], 'acg1');
      expect(s.meta['frames'], 15);
      expect(s.meta['duration_s'], 10.0);
      for (final (uid, k) in [(1, owner), (2, family)]) {
        final clip = openClip(meta: _mine(s.meta, uid), ciphertext: s.ct, keys: [k]);
        expect(clip.frames.length, 15);
        expect(clip.frames[3].first, 3);
      }
      expect(() => openClip(meta: _mine(s.meta, 1), ciphertext: s.ct, keys: [stranger]),
          throwsA(isA<ClipOpenError>()));
    });

    test('preview fits its size cap by dropping every other frame', () {
      final big = [for (var i = 0; i < 20; i++) Uint8List(60 * 1024)];
      final s = buildPreview(big, recips, maxKb: 600, rng: rng)!;
      expect(s.meta['frames'], lessThanOrEqualTo(9));
      expect(s.ct.length, lessThan(600 * 1024));
      expect(buildPreview([Uint8List(10)], recips), isNull); // < 2 frames
      expect(buildPreview(big, const []), isNull); // nobody to seal for
    });

    test('full video: sealed MP4 opens only with a recipient key', () {
      final mp4 = Uint8List.fromList([0, 0, 0, 24, ...'ftypmp42'.codeUnits, ...List.filled(5000, 9)]);
      final s = sealVideo(mp4, recips, 10, rng: rng);
      expect((s.meta['format'], s.meta['aad']), ('mp4', kVideoAad));
      expect(s.ct.sublist(4, 8), isNot(equals('ftyp'.codeUnits)));
      expect(openVideo(meta: _mine(s.meta, 2), ciphertext: s.ct, keys: [family]), mp4);
      expect(() => openVideo(meta: _mine(s.meta, 2), ciphertext: s.ct, keys: [stranger]),
          throwsA(isA<ClipOpenError>()));
    });
  });

  group('viewer panel', () {
    late VideoCtlFactory saved;
    setUp(() => saved = VideoCtls.factory);
    tearDown(() => VideoCtls.factory = saved);

    testWidgets('ask -> camera phone answers -> plays on this phone (en)', (tester) async {
      final mp4 = Uint8List.fromList(List.filled(4000, 5));
      final s = sealVideo(mp4, recips, 10, rng: rng);
      final ready = {..._base('ready'), 'url': 'https://x/m/v.bin', 'meta': _mine(s.meta, 2), 'size': s.ct.length, 'sealed_for_you': true};
      final src = _Src([_base('none'), _base('requested'), ready], ct: s.ct, keys: [family]);
      final ctl = FakeNetCtl();
      VideoCtls.factory = (_) async => ctl;
      await tester.pumpWidget(_app(PhoneCamFullVideo(
          source: src,
          eventId: 9,
          every: const Duration(milliseconds: 10),
          tempDir: () async => Directory.systemTemp)));
      await tester.pump();
      expect(find.text('Full video from the camera phone'), findsOneWidget);
      expect(find.textContaining('About 10 seconds, about 1.5 MB'), findsOneWidget);
      expect(find.textContaining('180 MB left of 300 MB'), findsOneWidget);
      expect(find.textContaining('online'), findsOneWidget);
      await tester.tap(find.text('Get the full video'));
      await tester.pump();
      expect(src.asks, 1);
      expect(find.text('Asking the camera phone…'), findsOneWidget);
      // the panel checks again -> requested -> ready -> opened (isolate)
      for (var i = 0; i < 20 && ctl.state.value.playing == false; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(ctl.state.value.playing, isTrue);
      expect(find.byType(AspectRatio), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(ctl.disposed, isTrue);
    });

    testWidgets('rolled over on the camera phone, offline, budget — honest (bn, 200%)', (tester) async {
      await tester.pumpWidget(_app(
          PhoneCamFullVideo(source: _Src([_base('missing')]), eventId: 1, initial: _base('missing')),
          lang: 'bn',
          scale: 2.0));
      await tester.pump();
      expect(find.textContaining('আর ক্যামেরা-ফোনে নেই'), findsOneWidget);
      expect(find.textContaining('৩০০ MB'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_app(PhoneCamFullVideo(
          source: _Src([_base('none', online: false)]), eventId: 1, initial: _base('none', online: false))));
      await tester.pump();
      expect(find.textContaining('offline now'), findsOneWidget);

      final src = _Src([_base('none')],
          askError: ApiException('This month\'s video/relay budget is used up', 402));
      await tester.pumpWidget(_app(PhoneCamFullVideo(source: src, eventId: 1, initial: _base('none'))));
      await tester.pump();
      await tester.tap(find.text('Get the full video'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('budget is used up'), findsOneWidget);
      expect(find.text('Get the full video'), findsNothing);
    });

    testWidgets('a ready video waits for a tap; keeps asking stops after the limit', (tester) async {
      await tester.pumpWidget(_app(PhoneCamFullVideo(
          source: _Src([_base('ready')]), eventId: 1, initial: _base('ready'))));
      await tester.pump();
      expect(find.text('Play the full video'), findsOneWidget);
      await tester.pumpWidget(_app(PhoneCamFullVideo(
          source: _Src([_base('requested')]),
          eventId: 1,
          initial: _base('requested'),
          maxChecks: 0)));
      await tester.pump();
      expect(find.textContaining('Still waiting'), findsOneWidget);
    });
  });
}
