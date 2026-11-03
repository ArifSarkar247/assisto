// viewonce (owner My Circle order 3 Nov 16:30, parts F + G) — PROVEN:
// F  media limits: one MediaLimits source (owner defaults + server values),
//    the 3-minute trim threshold, the trim window, the 720p / 25 MB plan,
//    the compress flow (trim -> compress -> size shown before Send).
// G  view once: photo / video / voice open ONCE (the server claim decides;
//    a refused second open fetches nothing), FLAG_SECURE on every viewer,
//    the honest "another camera" line, dashed "1" tile + "Opened <time>",
//    group counts, and NO preview in notifications or the chat list.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_preview.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_limits.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/video_ctl.dart';
import 'package:assisto/messaging/media/video_limits_flow.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/messaging/view_once.dart';
import 'package:assisto/messaging/view_once_preview.dart';
import 'package:assisto/photo_studio/ps_engines.dart' show SecureScreen;
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart' show mediaPreviewLabel, mediaPreviewIcon;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _en = lookupAppLocalizations(const Locale('en'));
final _bn = lookupAppLocalizations(const Locale('bn'));

Widget _app(Widget child, {Locale locale = const Locale('en'), ThemeData? theme}) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: theme ?? AssistoTheme.light,
      home: Scaffold(body: child),
    );

class _Secure implements SecureScreen {
  final calls = <String>[];
  @override
  Future<bool> enable() async {
    calls.add('on');
    return true;
  }

  @override
  Future<void> disable() async => calls.add('off');
}

class _FakeVideo implements VideoCtl {
  final ValueNotifier<VideoCtlState> s = ValueNotifier(const VideoCtlState());
  @override
  ValueListenable<VideoCtlState> get state => s;
  @override
  Future<void> init() async => s.value = s.value.copyWith(
      initialized: true, duration: const Duration(seconds: 20), size: const Size(1280, 720));
  @override
  Future<void> play() async => s.value = s.value.copyWith(playing: true);
  @override
  Future<void> pause() async => s.value = s.value.copyWith(playing: false);
  @override
  Future<void> seekTo(Duration d) async {}
  @override
  Future<void> setMuted(bool m) async {}
  @override
  Widget view() => const ColoredBox(color: Colors.blue);
  @override
  Future<void> dispose() async {}
}

class _FakeCompressor implements VideoCompressor {
  final calls = <Map<String, int>>[];
  int outSize = 9 * 1024 * 1024;
  bool fail = false;
  @override
  Future<VideoCompressOut?> compress(
      {required String src,
      required String dst,
      required int startMs,
      required int endMs,
      required int shortSide,
      required int bitrate}) async {
    calls.add({'start': startMs, 'end': endMs, 'short': shortSide, 'bitrate': bitrate});
    if (fail) return null;
    File(dst)
      ..createSync(recursive: true)
      ..writeAsBytesSync(Uint8List(16));
    return VideoCompressOut(dst, outSize);
  }

  @override
  Future<int> progress() async => 40;
  @override
  Future<void> cancel() async {}
}

// a real 1x1 PNG
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

MediaDescriptor _desc(String ref, {String kind = 'photo'}) => MediaDescriptor(
      kind: kind,
      ref: ref,
      key: Uint8List(32),
      nonce: Uint8List(12),
      sha256: 'a' * 64,
      size: 10,
      plainSize: _png.length,
      mime: kind == 'photo' ? 'image/png' : (kind == 'video' ? 'video/mp4' : 'audio/mp4'),
      durationMs: kind == 'photo' ? null : 4000,
    );

void main() {
  late Directory tmp;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('viewonce');
    MediaDirs.override = tmp.path;
    ViewOnceStore.instance.resetForTest();
    MediaLimits.resetForTest();
  });
  tearDown(() {
    MediaDirs.override = null;
    MediaLimits.resetForTest();
    videoCompressor = const ChannelVideoCompressor();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('F media limits', () {
    test('owner defaults: video 3 min / 25 MB / 720p, files 100 MB, 30 at once, voice 15 min', () {
      expect(MediaLimits.videoSeconds, 180);
      expect(MediaLimits.video, 25 * 1024 * 1024);
      expect(MediaLimits.videoHeight, 720);
      expect(MediaLimits.document, 100 * 1024 * 1024);
      expect(MediaLimits.photosPerSend, 30);
      expect(MediaLimits.voiceSeconds, 900);
      expect(MediaLimits.of('video'), MediaLimits.video);
      expect(MediaLimits.of('document'), MediaLimits.document);
    });

    test('server values win (Owner Admin, no new build); junk keeps the default', () {
      MediaLimits.apply({
        'video_max_seconds': 120,
        'photos_per_send': 20,
        'video_max_bytes': 30 * 1024 * 1024,
        'voice_max_seconds': 0, // a typo never means "nothing allowed"
        'view_once_days': 7,
      });
      expect(MediaLimits.videoSeconds, 120);
      expect(MediaLimits.photosPerSend, 20);
      expect(MediaLimits.video, 30 * 1024 * 1024);
      expect(MediaLimits.voiceSeconds, 900);
      expect(MediaLimits.viewOnceDays, 7);
    });

    test('trim threshold: over 3 min needs the trim screen, 3:00 does not', () {
      expect(MediaLimits.needsTrim(180000), isFalse);
      expect(MediaLimits.needsTrim(180400), isFalse); // container rounding
      expect(MediaLimits.needsTrim(181000), isTrue);
      expect(MediaLimits.needsTrim(null), isFalse);
      expect(planVideo(durationMs: 200000, size: 5 << 20, width: 640, height: 360),
          VideoPlan.trimThenCompress);
    });

    test('720p / 25 MB plan + bitrate keeps 3 minutes under the cap', () {
      expect(planVideo(durationMs: 60000, size: 40 << 20, width: 640, height: 360),
          VideoPlan.compress); // too big
      expect(planVideo(durationMs: 60000, size: 8 << 20, width: 1920, height: 1080),
          VideoPlan.compress); // above 720p
      expect(planVideo(durationMs: 60000, size: 8 << 20, width: 720, height: 1280),
          VideoPlan.sendAsIs); // portrait 720p, small: as picked
      final br = MediaLimits.videoBitrateFor(180);
      final bytes = (br + 64000) * 180 / 8;
      expect(bytes, lessThan(MediaLimits.video));
      expect(MediaLimits.videoBitrateFor(5), 2500000); // capped for short clips
    });

    test('trim window stays inside the clip and at most 3 minutes', () {
      var w = clampTrim(0, 300000, 300000, 180000);
      expect(w.end - w.start, 180000);
      w = clampTrim(100000, 300000, 300000, 180000, movedStart: true);
      expect((w.start, w.end), (100000, 280000));
      w = clampTrim(-5, 1000, 300000, 180000);
      expect(w.start, 0);
    });

    testWidgets('long video: trim screen -> compress to 720p -> new size before Send',
        (tester) async {
      final fake = _FakeCompressor();
      videoCompressor = fake;
      final src = File('${tmp.path}/in.mp4')..writeAsBytesSync(Uint8List(32));
      final draft = MediaDraft(
          kind: 'video',
          path: src.path,
          name: 'VID-1.mov',
          mime: 'video/quicktime',
          size: 80 << 20,
          width: 1920,
          height: 1080,
          durationMs: 300000);
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      late Future<MediaDraft?> done;
      await tester.runAsync(() async {
        done = prepareVideoForSend(ctx, draft);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text(_en.vo1TrimTitle), findsOneWidget);
      expect(find.byKey(const Key('vo1-trim-range')), findsOneWidget);
      expect(find.textContaining('3:00'), findsWidgets); // window = 3 minutes
      await tester.tap(find.byKey(const Key('vo1-trim-done')));
      await tester.runAsync(() async {
        for (var i = 0; i < 20 && fake.calls.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      late MediaDraft? out;
      await tester.runAsync(() async => out = await done);
      expect(fake.calls.single['start'], 0);
      expect(fake.calls.single['end'], 180000);
      expect(fake.calls.single['short'], 720);
      expect(out, isNotNull);
      expect(out!.size, 9 << 20);
      expect(out!.durationMs, 180000);
      expect(out!.mime, 'video/mp4');
      expect(out!.name, 'VID-1.mp4');
      expect(src.existsSync(), isFalse); // the big original is gone
    });

    testWidgets('no encoder + too big: honest message, nothing sent', (tester) async {
      final fake = _FakeCompressor()..fail = true;
      videoCompressor = fake;
      final src = File('${tmp.path}/in2.mp4')..writeAsBytesSync(Uint8List(32));
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      late Future<MediaDraft?> done;
      await tester.runAsync(() async {
        done = prepareVideoForSend(
            ctx,
            MediaDraft(
                kind: 'video',
                path: src.path,
                name: 'v.mp4',
                mime: 'video/mp4',
                size: 60 << 20,
                width: 1920,
                height: 1080,
                durationMs: 60000));
        for (var i = 0; i < 20 && fake.calls.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      late MediaDraft? out;
      await tester.runAsync(() async => out = await done);
      expect(out, isNull);
      await tester.pump();
      expect(find.textContaining("Couldn't make this video smaller"), findsOneWidget);
    });
  });

  group('G view once', () {
    Future<(Future<bool>, BuildContext)> start(WidgetTester tester, ViewOnceDeps deps,
        {String id = '701', String kind = 'photo', _Secure? secure}) async {
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      late Future<bool> done;
      await tester.runAsync(() async {
        done = openViewOnce(ctx, msgId: id, desc: _desc('r$id', kind: kind), deps: deps);
        for (var i = 0; i < 40 && (secure?.calls.isEmpty ?? true); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      return (done, ctx);
    }

    testWidgets('server claim first; photo shown once with FLAG_SECURE + honest line',
        (tester) async {
      final secure = _Secure();
      final claims = <String>[];
      final file = File('${tmp.path}/vo/a.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png);
      final deps = ViewOnceDeps(
          fetch: (_) async => throw StateError('legacy path must not run'),
          ack: (_) async => throw StateError('no ack owed'),
          secure: secure,
          claim: (id) async {
            claims.add(id);
            return const VoClaim.ok('/api/v1/circle/media/dl/x?u=1&e=2&s=3');
          },
          fetchUrl: (d, url) async => file);
      final (done, _) = await start(tester, deps, secure: secure);
      expect(claims, ['701']);
      expect(find.byKey(const Key('e-vo-image')), findsOneWidget);
      expect(file.existsSync(), isFalse); // memory only
      expect(secure.calls, ['on']);
      expect(find.byKey(const Key('vo1-honest')), findsOneWidget);
      expect(find.text(_en.vo1HonestLine), findsOneWidget);
      expect(find.byIcon(Icons.share_rounded), findsNothing);
      expect(find.byIcon(Icons.save_alt_rounded), findsNothing);
      expect(await ViewOnceStore.instance.owed(), 0); // the server already knows
      await tester.tap(find.byKey(const Key('e-vo-close')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => expect(await done, isTrue));
      expect(secure.calls, ['on', 'off']);
    });

    testWidgets('server refuses a second open: nothing is downloaded', (tester) async {
      var fetched = false;
      final deps = ViewOnceDeps(
          fetch: (_) async => null,
          ack: (_) async {},
          secure: _Secure(),
          claim: (_) async => const VoClaim.refused('already_opened'),
          fetchUrl: (d, url) async {
            fetched = true;
            return null;
          });
      final (done, _) = await start(tester, deps, id: '702');
      await tester.runAsync(() async => expect(await done, isFalse));
      expect(fetched, isFalse);
      await tester.pump();
      expect(find.text(_en.vo1AlreadyOpened), findsOneWidget);
      expect(await ViewOnceStore.instance.isOpened('702'), isTrue);
    });

    test('server answers map to the right refusal', () {
      expect(voClaimFrom(body: {'ok': true, 'url': '/u'}).url, '/u');
      expect(voClaimFrom(status: 409).reason, 'already_opened');
      expect(voClaimFrom(body: {'reason': 'expired'}, status: 410).reason, 'expired');
      expect(voClaimFrom().reason, 'offline');
    });

    testWidgets('view-once VIDEO plays in a FLAG_SECURE viewer; file deleted on close',
        (tester) async {
      final old = VideoCtls.factory;
      VideoCtls.factory = (_) async => _FakeVideo();
      addTearDown(() => VideoCtls.factory = old);
      final secure = _Secure();
      final file = File('${tmp.path}/vo/v.mp4')
        ..createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(8));
      final deps = ViewOnceDeps(
          fetch: (_) async => null,
          ack: (_) async {},
          secure: secure,
          claim: (_) async => const VoClaim.ok('/u'),
          fetchUrl: (d, url) async => file);
      final (done, _) = await start(tester, deps, id: '703', kind: 'video', secure: secure);
      expect(secure.calls, ['on']);
      expect(find.text(_en.vo1ViewerTitleVideo), findsOneWidget);
      expect(find.byKey(const Key('vo1-honest')), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new_rounded), findsNothing); // no "open with"
      await tester.tap(find.byKey(const Key('e-vo-close')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => expect(await done, isTrue));
      expect(secure.calls, ['on', 'off']);
      expect(file.existsSync(), isFalse);
    });

    testWidgets('view-once VOICE: FLAG_SECURE viewer, file deleted on close', (tester) async {
      final secure = _Secure();
      final file = File('${tmp.path}/vo/s.m4a')
        ..createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(8));
      final deps = ViewOnceDeps(
          fetch: (_) async => null,
          ack: (_) async {},
          secure: secure,
          claim: (_) async => const VoClaim.ok('/u'),
          fetchUrl: (d, url) async => file);
      final (done, _) = await start(tester, deps, id: '704', kind: 'voice', secure: secure);
      expect(secure.calls, ['on']);
      expect(find.byKey(const Key('vo1-voice')), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-vo-close')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => expect(await done, isTrue));
      expect(file.existsSync(), isFalse);
    });

    testWidgets('tiles: dashed "1" + Video / Voice, sender "Opened <time>", group count, expired',
        (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 5));
      var taps = 0;
      await tester.pumpWidget(_app(Column(children: [
        ViewOnceTile(
            key: const ValueKey('a'), mine: false, opened: false, fg: Colors.black,
            kind: 'video', onOpen: () => taps++),
        const ViewOnceTile(key: ValueKey('b'), mine: false, opened: false, fg: Colors.black, kind: 'voice'),
        ViewOnceTile(key: const ValueKey('c'), mine: true, opened: true, fg: Colors.black, openedAt: at),
        const ViewOnceTile(
            key: ValueKey('d'), mine: true, opened: false, fg: Colors.black, openCount: 2, openTotal: 5),
        const ViewOnceTile(
            key: ValueKey('e'), mine: false, opened: false, fg: Colors.black, expired: true),
      ])));
      expect(find.text(_en.circleVideo), findsOneWidget);
      expect(find.text(_en.vo1Voice), findsOneWidget);
      expect(find.textContaining('Opened '), findsOneWidget);
      expect(find.text(_en.vo1OpenedCount('2', '5')), findsOneWidget);
      expect(find.text(_en.vo1Expired), findsOneWidget);
      expect(find.byType(ViewOnceBadge), findsNWidgets(5));
      await tester.tap(find.byKey(const ValueKey('a')));
      expect(taps, 1);
      // every tile is a 48 dp target
      expect(tester.getSize(find.byKey(const ValueKey('a'))).height, greaterThanOrEqualTo(48));
    });

    testWidgets('bn + dark: tile and toggle render (Bangla digits)', (tester) async {
      var v = false;
      await tester.pumpWidget(_app(
          StatefulBuilder(
              builder: (c, set) => Column(children: [
                    const ViewOnceTile(
                        mine: true, opened: false, fg: Colors.white, openCount: 1, openTotal: 3),
                    ViewOnceSwitch(value: v, onChanged: (x) => set(() => v = x)),
                  ])),
          locale: const Locale('bn'),
          theme: AssistoTheme.dark));
      expect(find.text(_bn.vo1OpenedCount('১', '৩')), findsOneWidget);
      await tester.tap(find.byKey(const Key('vo1-toggle')));
      await tester.pump();
      expect(v, isTrue);
      expect(tester.getSize(find.byKey(const Key('vo1-toggle'))).width, greaterThanOrEqualTo(48));
    });
  });

  group('G never previewed', () {
    final d = MediaDescriptor(
        kind: 'photo',
        ref: 'r',
        key: Uint8List(32),
        nonce: Uint8List(12),
        sha256: 'b' * 64,
        size: 1,
        plainSize: 1,
        caption: 'secret caption');

    test('notification text: "Photo, view once" — never the caption', () {
      final vo = markViewOnce(d.encode());
      expect(mediaNotifText(_en, 'photo', plaintext: vo), 'Photo, view once');
      expect(mediaNotifText(_en, 'photo', plaintext: vo), isNot(contains('secret')));
      expect(mediaNotifText(_en, voPreviewKind('video')), 'Video, view once');
      expect(mediaNotifText(_en, voPreviewKind('voice')), 'Voice, view once');
      expect(mediaNotifText(_bn, voPreviewKind('photo')), _bn.vo1PreviewPhoto);
      // a normal photo still shows its caption
      expect(mediaNotifText(_en, 'photo', plaintext: d.encode()), contains('secret caption'));
    });

    test('chat list: server flag -> "Photo, view once" with the 1 icon', () {
      final pv = ChatPreview.fromRow({
        'last': {
          'id': 9,
          'content_type': 'photo',
          'ciphertext': '',
          'nonce': '',
          'mine': false,
          'view_once': true,
        },
      }, identity: null);
      expect(pv.kind, PreviewKind.media);
      expect(pv.text, '');
      expect(isVoPreviewKind(pv.contentType), isTrue);
      expect(mediaPreviewLabel(_en, pv.contentType), 'Photo, view once');
      expect(mediaPreviewIcon(pv.contentType), Icons.looks_one_outlined);
      expect(mediaPreviewLabel(_en, 'photo'), _en.circlePhoto); // unchanged
    });
  });
}
