// mc-media2 — location / live location / contact card / inline video.
//
// Proves: the E2E share payload (round trip, validation, readable fallback,
// forward = still point), the location card (render, Bangla digits, "Open in
// Maps" geo: first then the browser), live location (updates only when moved
// or quiet, expiry, stop, a gone message ends the share), the contact card
// actions, the video player screen states with a fake controller, the inline
// video tile, and the MP4 metadata scrub.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/video_ctl.dart';
import 'package:assisto/messaging/media/video_player_screen.dart';
import 'package:assisto/messaging/media/video_prep.dart';
import 'package:assisto/messaging/media/video_tile.dart';
import 'package:assisto/messaging/share/contact_card.dart';
import 'package:assisto/messaging/share/live_location.dart';
import 'package:assisto/messaging/share/location_card.dart';
import 'package:assisto/messaging/share/share_flow.dart' show shareBubbleBody;
import 'package:assisto/messaging/share/share_payload.dart';
import 'package:assisto/p3/assisto_card.dart' show cardFallback;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: Center(child: child)),
    );

final _t0 = DateTime(2026, 10, 24, 15, 0);

LocationShare _live({int mins = 60, bool stopped = false, int atOffsetMin = 0}) => LocationShare(
      lat: 23.810331,
      lng: 90.412521,
      accuracy: 12,
      at: _t0.add(Duration(minutes: atOffsetMin)).millisecondsSinceEpoch,
      live: true,
      until: _t0.add(Duration(minutes: mins)).millisecondsSinceEpoch,
      stopped: stopped,
    );

class _FakeVideo implements VideoCtl {
  final ValueNotifier<VideoCtlState> s = ValueNotifier(const VideoCtlState());
  bool failInit = false;
  final calls = <String>[];
  _FakeVideo();

  @override
  ValueListenable<VideoCtlState> get state => s;
  @override
  Future<void> init() async {
    calls.add('init');
    s.value = failInit
        ? s.value.copyWith(error: 'codec')
        : s.value.copyWith(
            initialized: true,
            duration: const Duration(seconds: 75),
            size: const Size(640, 360));
  }

  @override
  Future<void> play() async {
    calls.add('play');
    s.value = s.value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    s.value = s.value.copyWith(playing: false);
  }

  @override
  Future<void> seekTo(Duration d) async {
    calls.add('seek:${d.inSeconds}');
    s.value = s.value.copyWith(position: d);
  }

  @override
  Future<void> setMuted(bool m) async {
    calls.add('mute:$m');
    s.value = s.value.copyWith(muted: m);
  }

  @override
  Widget view() => const ColoredBox(color: Colors.blue);
  @override
  Future<void> dispose() async => calls.add('dispose');
}

// --- a tiny synthetic MP4: ftyp, moov{mvhd, udta{©xyz}, trak{tkhd, meta}}, mdat
Uint8List _box(String type, List<int> body) {
  final size = 8 + body.length;
  return Uint8List.fromList([
    (size >> 24) & 255, (size >> 16) & 255, (size >> 8) & 255, size & 255,
    ...latin1.encode(type), ...body,
  ]);
}

Uint8List _mp4() {
  final xyz = _box('©xyz', latin1.encode('+23.8103+090.4125/'));
  final moov = _box('moov', [
    ..._box('mvhd', List.filled(20, 1)),
    ..._box('udta', xyz),
    ..._box('trak', [..._box('tkhd', List.filled(12, 2)), ..._box('meta', List.filled(10, 3))]),
  ]);
  return Uint8List.fromList(
      [..._box('ftyp', latin1.encode('isom0000')), ...moov, ..._box('mdat', List.filled(64, 7))]);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveLocation.instance = LiveLocation(persist: false);
  });

  // -------------------------------------------------------------------------
  group('share payload (inside the E2E envelope)', () {
    test('location round trip + readable fallback + forward is a still point', () {
      final pt = encodeLocation(_live(), '📍 Live location until 4:00 PM: https://maps.google.com/?q=23.810331,90.412521');
      expect(isShareText(pt), isTrue);
      final s = decodeShare(pt)!.location!;
      expect(s.live, isTrue);
      expect(s.lat, closeTo(23.810331, 1e-6));
      expect(s.accuracy, 12);
      expect(s.isLiveAt(_t0), isTrue);
      expect(s.isLiveAt(_t0.add(const Duration(minutes: 61))), isFalse);
      expect(shareFallback(pt), startsWith('📍 Live location'));
      // previews / notifications / copy use the readable line only
      expect(cardFallback(pt), shareFallback(pt));
      final fwd = decodeShare(shareForForward(pt))!.location!;
      expect(fwd.live, isFalse);
      expect(fwd.lat, s.lat);
      expect(mc2ForwardKind('location'), 'location');
      expect(mc2ForwardKind('text'), 'text');
    });

    test('maps links: geo: for the phone, https for the browser', () {
      const s = LocationShare(lat: 23.5, lng: 90.25, label: 'Home');
      expect(s.geoUri.toString(), 'geo:23.500000,90.250000?q=23.500000,90.250000(Home)');
      expect(s.webUri.toString(), 'https://maps.google.com/?q=23.500000,90.250000');
    });

    test('bad points and empty contacts are refused (ordinary text instead)', () {
      String enc(Map<String, dynamic> j) => encodeShare(j, 'x');
      expect(decodeShare(enc({'t': 'loc', 'lat': 123, 'lng': 90})), isNull);
      expect(decodeShare(enc({'t': 'loc', 'lat': 'a', 'lng': 90})), isNull);
      expect(decodeShare(enc({'t': 'contact', 'n': 'A'})), isNull);
      expect(decodeShare(enc({'t': 'gif'})), isNull);
      expect(decodeShare('hello'), isNull);
      expect(decodeShare('x\n${kShareMarker}not-base64!!'), isNull);
    });

    test('contact: numbers cleaned, deduped, capped at 5; a member card has a uid', () {
      final c = decodeShare(encodeContact(
              const ContactShare(name: 'Rahim', phones: ['+880 1711-000001', '01711000001', '01711000001']),
              'x'))!
          .contact!;
      expect(c.phones, ['+8801711000001', '01711000001']);
      final many = ContactShare.fromJson({
        't': 'contact',
        'n': 'B',
        'p': ['111', '222', '333', '444', '555', '666'],
      })!;
      expect(many.phones.length, 5);
      final m = decodeShare(encodeContact(const ContactShare(name: 'Mitu', uid: 42), 'x'))!.contact!;
      expect(m.uid, 42);
      expect(m.phones, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('location card', () {
    testWidgets('renders title, coords (Bangla digits) and opens geo: first', (tester) async {
      final opened = <Uri>[];
      LocationOpener.launcher = (u) async {
        opened.add(u);
        return u.scheme == 'https'; // no maps app: the browser answers
      };
      await tester.pumpWidget(_app(
          const LocationCard(
              share: LocationShare(lat: 23.81, lng: 90.41, accuracy: 9, label: 'Office'),
              mine: false,
              fg: Colors.black),
          lang: 'bn'));
      expect(find.text('Office'), findsOneWidget);
      expect(find.text('২৩.৮১০০০, ৯০.৪১০০০'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mc2-loc-open')));
      await tester.pumpAndSettle();
      expect(opened.map((u) => u.scheme).toList(), ['geo', 'https']);
      expect(find.byKey(const Key('mc2-loc-stop')), findsNothing);
    });

    testWidgets('an unopenable link says so honestly', (tester) async {
      LocationOpener.launcher = (u) async => false;
      await tester.pumpWidget(_app(const LocationCard(
          share: LocationShare(lat: 1, lng: 2), mine: false, fg: Colors.black)));
      await tester.tap(find.byKey(const Key('mc2-loc-open')));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.mc2OpenFailed), findsOneWidget);
    });

    testWidgets('live: until + last update; ended after expiry or stop', (tester) async {
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.pumpWidget(_app(LocationCard(
          share: _live(atOffsetMin: -5), mine: false, fg: Colors.black, clock: () => _t0)));
      expect(find.text(t.mc2LiveUntil('4:00 PM')), findsOneWidget);
      expect(find.text(t.mc2UpdatedMin('5')), findsOneWidget);
      await tester.pumpWidget(_app(LocationCard(
          share: _live(),
          mine: false,
          fg: Colors.black,
          clock: () => _t0.add(const Duration(minutes: 61)))));
      expect(find.text(t.mc2LiveEnded), findsOneWidget);
      await tester.pumpWidget(_app(LocationCard(
          share: _live(stopped: true), mine: false, fg: Colors.black, clock: () => _t0)));
      expect(find.text(t.mc2LiveEnded), findsOneWidget);
    });

    testWidgets('sender: Stop sharing sends a final "stopped" update', (tester) async {
      final sent = <String>[];
      final live = LiveLocation(
          persist: false,
          clock: () => _t0,
          transport: (s, pt) async => sent.add(pt),
          positions: () async => null);
      LiveLocation.instance = live;
      await tester.runAsync(() => live.start(LiveSession(
          chatKind: 'member', chatId: 5, messageId: '77', fallback: 'fb', last: _live())));
      await tester.pumpWidget(_app(LocationCard(
          share: _live(), mine: true, fg: Colors.black, messageId: '77', clock: () => _t0)));
      expect(find.byKey(const Key('mc2-loc-fg-note')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mc2-loc-stop')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(decodeShare(sent.single)!.location!.stopped, isTrue);
      expect(live.isActive('77'), isFalse);
      expect(find.byKey(const Key('mc2-loc-stop')), findsNothing);
      live.reset();
    });

    testWidgets('shareBubbleBody picks the right card, null for other text', (tester) async {
      expect(shareBubbleBody('text', 'hi', mine: false, fg: Colors.black), isNull);
      expect(shareBubbleBody('location', 'plain', mine: false, fg: Colors.black), isNull);
      final w = shareBubbleBody('location', encodeLocation(const LocationShare(lat: 1, lng: 2), 'x'),
          mine: false, fg: Colors.black);
      expect(w, isA<LocationCard>());
    });
  });

  // -------------------------------------------------------------------------
  group('live location controller (foreground only)', () {
    late List<String> pushed;
    late DateTime now;
    late LocationShare? pos;
    late Object? fail;
    LiveLocation mk() => LiveLocation(
        persist: false,
        clock: () => now,
        positions: () async => pos,
        transport: (s, pt) async {
          if (fail != null) throw fail!;
          pushed.add(pt);
        });

    setUp(() {
      pushed = [];
      now = _t0;
      pos = null;
      fail = null;
    });

    LiveSession sess() =>
        LiveSession(chatKind: 'group', chatId: 3, messageId: '9', fallback: 'fb', last: _live());

    test('pushes only when moved or after a quiet while', () async {
      final l = mk();
      await l.start(sess());
      pos = LocationShare(lat: 23.810331, lng: 90.412521 + 0.00005); // ~5 m
      now = _t0.add(const Duration(seconds: 30));
      await l.runOnce();
      expect(pushed, isEmpty);
      pos = const LocationShare(lat: 23.8120, lng: 90.4125); // ~190 m
      await l.runOnce();
      expect(pushed, hasLength(1));
      final p = decodeShare(pushed.single)!.location!;
      expect((p.live, p.seq, p.lat), (true, 1, 23.812));
      expect(p.until, _live().until); // the end never moves
      pos = const LocationShare(lat: 23.8120, lng: 90.4125);
      now = _t0.add(const Duration(minutes: 3)); // quiet > 2 min
      await l.runOnce();
      expect(pushed, hasLength(2));
      l.reset();
    });

    test('no fix = nothing sent; past the end = session gone', () async {
      final l = mk();
      await l.start(sess());
      await l.runOnce();
      expect(pushed, isEmpty);
      now = _t0.add(const Duration(minutes: 61));
      pos = const LocationShare(lat: 1, lng: 1);
      await l.runOnce();
      expect(pushed, isEmpty);
      expect(l.isActive('9'), isFalse);
    });

    test('a deleted / left / expired message ends the share; offline keeps it', () async {
      final l = mk();
      await l.start(sess());
      pos = const LocationShare(lat: 24, lng: 91);
      fail = ApiException('offline');
      await l.runOnce();
      expect(l.isActive('9'), isTrue);
      fail = ApiException('gone', 404);
      await l.runOnce();
      expect(l.isActive('9'), isFalse);
    });

    test('stop while offline is retried on the next tick', () async {
      final l = mk();
      await l.start(sess());
      fail = ApiException('offline');
      expect(await l.stop('9'), isFalse);
      expect(l.isActive('9'), isTrue);
      fail = null;
      await l.runOnce();
      expect(l.isActive('9'), isFalse);
      expect(decodeShare(pushed.single)!.location!.stopped, isTrue);
    });

    test('the ticker stops when Assisto goes to the background', () async {
      final l = mk();
      await l.start(sess());
      expect(l.timerArmed, isTrue);
      l.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(l.timerArmed, isFalse);
      l.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(l.timerArmed, isTrue);
      l.reset();
    });

    test('distance', () {
      expect(distanceM(23.8, 90.4, 23.8, 90.4), 0);
      expect(distanceM(23.8, 90.4, 23.809, 90.4), closeTo(1000, 15));
    });
  });

  // -------------------------------------------------------------------------
  group('contact card', () {
    late List<String> calls;
    setUp(() {
      calls = [];
      ContactCardActions.isOnAssisto = (ctx, p) async {
        calls.add('lookup:$p');
        return p == '01711000001';
      };
      ContactCardActions.message = (ctx, c) async => calls.add('message:${c.uid ?? c.phones.first}');
      ContactCardActions.addToContacts = (c) async {
        calls.add('add:${c.name}');
        return true;
      };
      ContactCardActions.call = (p) async {
        calls.add('call:$p');
        return true;
      };
    });

    testWidgets('received phone contact on Assisto: Message / Add / Call', (tester) async {
      await tester.pumpWidget(_app(const ContactCard(
          contact: ContactShare(name: 'Rahim', phones: ['01711000001']),
          mine: false,
          fg: Colors.black)));
      await tester.pumpAndSettle();
      expect(find.text('Rahim'), findsOneWidget);
      expect(find.byKey(const Key('mc2-contact-on-assisto')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mc2-contact-message')));
      await tester.tap(find.byKey(const Key('mc2-contact-add')));
      await tester.tap(find.byKey(const Key('mc2-contact-call')));
      await tester.pumpAndSettle();
      expect(calls, ['lookup:01711000001', 'message:01711000001', 'add:Rahim', 'call:01711000001']);
    });

    testWidgets('a number not on Assisto: no Message button, Bangla digits', (tester) async {
      await tester.pumpWidget(_app(
          const ContactCard(
              contact: ContactShare(name: 'Karim', phones: ['01999000000']), mine: false, fg: Colors.black),
          lang: 'bn'));
      await tester.pumpAndSettle();
      expect(find.text('০১৯৯৯০০০০০০'), findsOneWidget);
      expect(find.byKey(const Key('mc2-contact-message')), findsNothing);
      expect(find.byKey(const Key('mc2-contact-add')), findsOneWidget);
    });

    testWidgets('a My Circle member card: Message only (no number shared)', (tester) async {
      await tester.pumpWidget(_app(const ContactCard(
          contact: ContactShare(name: 'Mitu', uid: 42), mine: false, fg: Colors.black)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mc2-contact-call')), findsNothing);
      expect(find.byKey(const Key('mc2-contact-add')), findsNothing);
      await tester.tap(find.byKey(const Key('mc2-contact-message')));
      expect(calls, ['message:42']);
    });

    testWidgets('my own card: no lookup, no Message / Add', (tester) async {
      await tester.pumpWidget(_app(const ContactCard(
          contact: ContactShare(name: 'Rahim', phones: ['01711000001']), mine: true, fg: Colors.black)));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.byKey(const Key('mc2-contact-message')), findsNothing);
      expect(find.byKey(const Key('mc2-contact-add')), findsNothing);
      expect(find.byKey(const Key('mc2-contact-call')), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  group('video', () {
    late _FakeVideo fake;
    setUp(() {
      fake = _FakeVideo();
      VideoCtls.factory = (f) async => fake;
    });

    testWidgets('player: autoplay, pause, mute, seek; disposed on close', (tester) async {
      await tester.pumpWidget(_app(VideoPlayerScreen(file: File('/x/v.mp4'))));
      await tester.pumpAndSettle();
      expect(fake.calls, ['init', 'play']);
      expect(find.byKey(const Key('mc2-video-view')), findsOneWidget);
      // controls hidden after 3 s while playing; a tap shows them again
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const Key('mc2-video-toggle')), findsNothing);
      await tester.tap(find.byKey(const Key('mc2-video-view')));
      await tester.pump();
      expect(find.text('1:15'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mc2-video-toggle')));
      await tester.pump();
      expect(fake.calls.last, 'pause');
      await tester.tap(find.byKey(const Key('mc2-video-mute')));
      await tester.pump();
      expect(fake.calls.last, 'mute:true');
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      final slider = tester.widget<Slider>(find.byKey(const Key('mc2-video-seek')));
      slider.onChanged!(30000);
      slider.onChangeEnd!(30000);
      await tester.pump();
      expect(fake.calls.last, 'seek:30');
      expect(find.text('0:30'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(fake.calls.last, 'dispose');
    });

    testWidgets('player: a clip the phone cannot play -> honest error + open with', (tester) async {
      fake.failInit = true;
      await tester.pumpWidget(_app(VideoPlayerScreen(file: File('/x/v.mp4'))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mc2-video-error')), findsOneWidget);
      expect(find.byKey(const Key('mc2-video-open-with')), findsOneWidget);
      expect(fake.calls.contains('play'), isFalse);
    });

    testWidgets('player: loading state before init', (tester) async {
      final gate = Completer<void>();
      VideoCtls.factory = (f) async {
        await gate.future;
        return fake;
      };
      await tester.pumpWidget(_app(VideoPlayerScreen(file: File('/x/v.mp4'))));
      await tester.pump();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.mc2VideoLoading), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mc2-video-view')), findsOneWidget);
    });

    testWidgets('inline tile: download control until the file is here, then Play', (tester) async {
      final d = MediaDescriptor(
          kind: 'video',
          ref: 'a' * 32,
          key: Uint8List(32),
          nonce: Uint8List(12),
          sha256: 'b' * 64,
          size: 3 * 1024 * 1024,
          plainSize: 3 * 1024 * 1024,
          mime: 'video/mp4',
          durationMs: 65000);
      await tester.pumpWidget(_app(VideoTile(
          desc: d,
          box: const Size(240, 135),
          thumb: const SizedBox(),
          control: const Text('DL'))));
      expect(find.text('DL'), findsOneWidget);
      expect(find.text('1:05 · 3.0 MB'), findsOneWidget);
      var played = 0;
      await tester.pumpWidget(_app(VideoTile(
          desc: d,
          file: File('/x/v.mp4'),
          box: const Size(240, 135),
          thumb: const SizedBox(),
          onPlay: () => played++)));
      expect(find.byKey(const Key('mc2-video-play')), findsOneWidget);
      expect(find.text('1:05'), findsOneWidget);
      await tester.tap(find.byKey(Key('mc2-video-${d.ref}')));
      expect(played, 1);
    });

    test('descriptor knows video (mp4 cache name)', () {
      final d = MediaDescriptor.tryParse(jsonEncode({
        'md1': 1,
        'kind': 'video',
        'ref': 'c' * 32,
        'k': base64Encode(Uint8List(32)),
        'n': base64Encode(Uint8List(12)),
        'sha': 'd' * 64,
        'size': 10,
        'psize': 9,
        'mime': 'video/mp4',
        'ms': 1200,
      }))!;
      expect((d.kind, d.ext, d.durationMs), ('video', 'mp4', 1200));
    });

    test('MP4 scrub: udta / meta become free, sizes and media untouched', () async {
      final dir = await Directory.systemTemp.createTemp('mc2');
      final f = File('${dir.path}/v.mp4');
      final raw = _mp4();
      await f.writeAsBytes(raw);
      final n = await scrubMp4InPlace(f);
      final out = await f.readAsBytes();
      expect(n, 2);
      expect(out.length, raw.length);
      final s = latin1.decode(out);
      expect(s.contains('udta'), isFalse);
      expect(s.contains('meta'), isFalse);
      expect(s.contains('+23.8103'), isFalse); // the place is blanked too
      expect(s.contains('moov'), isTrue);
      expect(out.sublist(out.length - 64), List.filled(64, 7));
      // not an MP4 / damaged: nothing changed
      final junk = File('${dir.path}/j.bin')..writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(await scrubMp4InPlace(junk), 0);
      await dir.delete(recursive: true);
    });
  });
}
