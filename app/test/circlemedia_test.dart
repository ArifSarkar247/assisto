// circlemedia — multi-photo send + the photo / album bubble:
// album grid layouts 1..6 (2 side by side, 3 = large + two small, 4 = 2x2,
// more = 2x2 with +N), album folding in the chat list, the album link inside
// the E2E descriptor, the multi-pick limit (30 by default, the oldest
// phones' picker has none), photo prep (rotate, HD / Standard, no metadata),
// the preview (swipe, remove, caption, HD, send-bar slot), queueing one
// album through the existing media outbox (per-item progress, retry), and
// the viewer.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/album.dart';
import 'package:assisto/messaging/media/album_send_preview.dart';
import 'package:assisto/messaging/media/album_viewer.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_outbox.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_send.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/multi_pick.dart';
import 'package:assisto/messaging/media/photo_album_view.dart';
import 'package:assisto/messaging/media/photo_prep.dart';
import 'package:assisto/messaging/media/video_ctl.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'md1_media_test.dart' show FakeServer, MemStore;

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

Uint8List _jpeg(int w, int h, {int orientation = 1}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(30, 120, 200));
  if (orientation != 1) im.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

bool _hasExif(Uint8List b) {
  const sig = [0x45, 0x78, 0x69, 0x66]; // "Exif"
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] == sig[0] && b[i + 1] == sig[1] && b[i + 2] == sig[2] && b[i + 3] == sig[3]) {
      return true;
    }
  }
  return false;
}

MediaDescriptor _desc(String ref, {String kind = 'photo', AlbumRef? album, String cap = ''}) =>
    MediaDescriptor(
        kind: kind, ref: ref, key: Uint8List(32)..[0] = 1, nonce: Uint8List(12),
        sha256: 'e' * 64, size: 1000, plainSize: 968, mime: 'image/jpeg',
        width: 400, height: 300, thumb: null, caption: cap, album: album);

String _ref(int i) => '$i'.padLeft(32, 'd');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('cmt');
    MediaDirs.override = dir.path;
    MediaPrefs.metered = () async => true; // no auto download in tests
    MediaCache.instance = MediaCache(transport: FakeServer());
  });
  tearDown(() async {
    MediaDirs.override = null;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  group('album layouts 1 to 6', () {
    test('tiles, height and +N', () {
      expect(albumLayout(1).tiles, hasLength(1));
      final two = albumLayout(2);
      expect(two.tiles, hasLength(2));
      expect(two.tiles[0].y, two.tiles[1].y, reason: 'side by side');
      expect(two.tiles[0].w + two.tiles[1].w, 1.0);
      final three = albumLayout(3);
      expect(three.tiles, hasLength(3));
      expect(three.tiles[0].w, 1.0, reason: 'one large on top');
      expect(three.tiles[1].w, 0.5);
      expect(three.tiles[2].w, 0.5);
      expect(three.tiles[0].h, greaterThan(three.tiles[1].h));
      final four = albumLayout(4);
      expect(four.tiles, hasLength(4));
      expect(four.overflow, 0);
      expect({for (final t in four.tiles) (t.x, t.y)}, {(0.0, 0.0), (0.5, 0.0), (0.0, 0.5), (0.5, 0.5)});
      expect(albumLayout(5).tiles, hasLength(4));
      expect(albumLayout(5).overflow, 1);
      expect(albumLayout(6).overflow, 2);
      expect(albumLayout(30).overflow, 26);
      // every tile stays inside the grid
      for (var n = 1; n <= 6; n++) {
        final l = albumLayout(n);
        for (final t in l.tiles) {
          expect(t.x + t.w, lessThanOrEqualTo(1.0001));
          expect(t.y + t.h, lessThanOrEqualTo(l.heightFactor + 0.0001));
        }
      }
    });

    test('single photo keeps its real aspect ratio within min / max', () {
      final land = photoBubbleSize(4000, 3000, 260);
      expect(land.w, 260);
      expect(land.h, closeTo(195, 0.5));
      final tall = photoBubbleSize(1000, 5000, 260);
      expect(tall.h, closeTo(260 * 1.33, 0.5), reason: 'max height');
      expect(tall.w, 150, reason: 'min width');
      final pano = photoBubbleSize(6000, 500, 260);
      expect(pano.h, 110, reason: 'min height');
      expect(photoBubbleSize(null, null, 260).w, 260);
    });

    testWidgets('grid renders 1..6 items with +N on the fourth', (tester) async {
      for (var n = 1; n <= 6; n++) {
        final items = [
          for (var i = 0; i < n; i++)
            AlbumItem(id: '$i', desc: _desc(_ref(i), album: n > 1 ? AlbumRef(id: 'a', index: i, count: n) : null))
        ];
        await tester.pumpWidget(_app(Scaffold(
            body: Center(
                child: PhotoAlbumView(items: items, size: const Size(260, 260))))));
        expect(find.byKey(Key('cm-album-$n')), findsOneWidget);
        expect(find.byType(AlbumTile), findsNWidgets(n > 4 ? 4 : n));
        if (n > 4) {
          expect(find.text('+${n - 4}'), findsOneWidget);
        } else {
          expect(find.byKey(const Key('cm-album-more')), findsNothing);
        }
      }
    });
  });

  group('album link inside the E2E descriptor', () {
    test('descriptor round trip keeps the album; bad values are dropped', () {
      final d = _desc(_ref(1), album: const AlbumRef(id: 'abc', index: 2, count: 5));
      final back = MediaDescriptor.tryParse(d.encode())!;
      expect(back.album, const AlbumRef(id: 'abc', index: 2, count: 5));
      expect(MediaDescriptor.tryParse(_desc(_ref(1)).encode())!.album, isNull);
      expect(AlbumRef.tryParse({'id': 'x', 'i': 5, 'n': 5}), isNull);
      expect(AlbumRef.tryParse({'id': 'x', 'i': 0, 'n': 1}), isNull);
      expect(AlbumRef.tryParse('nope'), isNull);
      expect(newAlbumId(), isNot(newAlbumId()));
    });

    test('media job persists album + prep', () {
      final j = MediaJob(
          id: 'local-1-0', chatKind: 'member', chatId: 5, kind: 'photo', srcPath: '/x',
          name: 'a.jpg', mime: 'image/jpeg', plainSize: 10, at: DateTime(2026, 11, 3),
          album: const AlbumRef(id: 'q', index: 0, count: 3),
          prep: photoPrepSpec(turns: 1, hd: false));
      final back = MediaJob.fromJson(jsonDecode(jsonEncode(j.toJson())))!;
      expect(back.album, j.album);
      expect(back.prep, {'rot': 1, 'edge': kStdEdge, 'q': kStdQuality});
      expect(back.descriptor().album, j.album);
    });
  });

  group('album folding in the chat list', () {
    test('members fold into one row at the first member, in album order', () {
      // (key, index, label)
      final rows = <(String?, int, String)>[
        (null, 0, 'hello'),
        ('me:a', 1, 'a1'),
        ('me:a', 0, 'a0'),
        (null, 0, 'reply'),
        ('me:a', 2, 'a2'),
        ('them:b', 0, 'b0'), // an album with one member present stays a row
      ];
      final out = collapseAlbums<(String?, int, String)>(rows,
          albumOf: (r) => r.$1,
          indexOf: (r) => r.$2,
          merge: (ms) => ('me:a', -1, ms.map((m) => m.$3).join('+')));
      expect(out.map((r) => r.$3).toList(), ['hello', 'a0+a1+a2', 'reply', 'b0']);
    });

    test('CircleBubble picks the album items (view once / documents never)', () {
      CircleMessage m(String id, int i, {bool vo = false, String kind = 'photo'}) =>
          CircleMessage(
              id: id, text: '', mine: true, at: DateTime(2026), contentType: kind,
              viewOnce: vo,
              media: _desc(_ref(i), kind: kind, album: AlbumRef(id: 'z', index: i, count: 3)));
      final a = m('1', 0), b = m('2', 1), c = m('3', 2);
      expect(a.albumKey, 'me:z');
      expect(m('9', 0, vo: true).albumKey, '', reason: 'view once is never folded');
      final merged = a.copyWith(album: [a, b, c]);
      expect(CircleBubble.photoItemsOf(merged), hasLength(3));
      expect(CircleBubble.photoItemsOf(m('4', 0, kind: 'document')), isNull);
    });
  });

  group('multi pick (up to 30 photos and videos)', () {
    test('keeps the first 30 when the picker has no limit (old phones)', () async {
      final paths = <String>[];
      for (var i = 0; i < 35; i++) {
        final f = File('${dir.path}/p$i.jpg')..writeAsBytesSync(_jpeg(40, 30));
        paths.add(f.path);
      }
      final r = await prepareMultiPaths(paths, limit: 30, videoMax: 1024);
      expect(r.drafts, hasLength(30));
      expect(r.overLimit, 5);
      expect(r.drafts.every((d) => d.kind == 'photo' && File(d.path).existsSync()), isTrue);
      expect(r.drafts.first.width, 40);
    });

    test('videos ride along; a too-big video is left out honestly', () async {
      final oldFactory = VideoCtls.factory;
      VideoCtls.factory = (f) async => throw StateError('no player in tests');
      addTearDown(() => VideoCtls.factory = oldFactory);
      final small = File('${dir.path}/v1.mp4')..writeAsBytesSync(List.filled(100, 0));
      final big = File('${dir.path}/v2.mp4')..writeAsBytesSync(List.filled(5000, 0));
      final photo = File('${dir.path}/p.jpg')..writeAsBytesSync(_jpeg(40, 30));
      final r = await prepareMultiPaths([small.path, big.path, photo.path],
          limit: 30, videoMax: 1000);
      expect(r.tooBig, 1);
      expect(r.drafts.map((d) => d.kind).toList(), ['video', 'photo']);
      expect(isVideoPath('a/b.MOV'), isTrue);
      expect(isVideoPath('a/b.jpg'), isFalse);
    });

    test('the picker seam is asked for the limit (MediaLimits.photosPerSend)', () async {
      int? asked;
      final old = pickMultipleMediaPaths;
      pickMultipleMediaPaths = (limit) async {
        asked = limit;
        return [];
      };
      addTearDown(() => pickMultipleMediaPaths = old);
      expect(MediaLimits.photosPerSend, 30);
      expect(await pickMultiDrafts(limit: MediaLimits.photosPerSend, videoMax: 1), isNull);
      expect(asked, 30);
    });
  });

  group('photo prep (rotate, HD / Standard, no metadata)', () {
    test('Standard shrinks to 1600; EXIF orientation is applied and dropped', () {
      final out = photoPrepSync(_jpeg(3000, 1000, orientation: 6), 0, kStdEdge, kStdQuality)!;
      expect(out.height, 1600, reason: 'orientation 6 = portrait');
      expect(out.width, closeTo(533, 1));
      expect(_hasExif(out.bytes), isFalse);
    });

    test('rotate one quarter turn; HD keeps up to 2560', () {
      final out = photoPrepSync(_jpeg(3000, 1000), 1, kHdEdge, kHdQuality)!;
      expect(out.height, 2560);
      expect(out.width, closeTo(853, 1));
      expect(preppedSize(3000, 1000, turns: 1, hd: true), (853, 2560));
      expect(preppedSize(3000, 1000, turns: 0, hd: false), (1600, 533));
    });

    test('prep only when it changes something', () {
      expect(prepNeeded(photoPrepSpec(turns: 0, hd: true), 2000, 1500), isFalse);
      expect(prepNeeded(photoPrepSpec(turns: 0, hd: false), 2000, 1500), isTrue);
      expect(prepNeeded(photoPrepSpec(turns: 2, hd: true), 100, 100), isTrue);
      expect(photoPrepSync(Uint8List.fromList([1, 2, 3]), 0, 100, 80), isNull);
    });
  });

  group('send one album through the E2E outbox', () {
    test('N jobs share one album id; caption + reply on the first; prep runs before sealing',
        () async {
      final srv = FakeServer()..peerPub = _peer.publicKeyB64;
      final box = MediaOutbox(store: MemStore(), transport: srv)..identity = () async => _me;
      MediaCache.instance = MediaCache(transport: srv);
      final drafts = <MediaDraft>[];
      for (var i = 0; i < 3; i++) {
        drafts.add(await preparePhotoBytes(_jpeg(2400, 1200), 'p$i.jpg'));
      }
      final jobs = await queueAlbumChoice(
          AlbumSendChoice([
            AlbumSendItem(drafts[0], turns: 1),
            AlbumSendItem(drafts[1]),
            AlbumSendItem(drafts[2]),
          ], caption: ' trip ', hd: false),
          chatKind: 'member', chatId: 5, replyTo: '77', outbox: box);
      expect(jobs, hasLength(3));
      expect(jobs.map((j) => j.album!.id).toSet(), hasLength(1));
      expect(jobs.map((j) => j.album!.index).toList(), [0, 1, 2]);
      expect((jobs[0].caption, jobs[1].caption), ('trip', ''));
      expect((jobs[0].replyTo, jobs[1].replyTo), ('77', null));
      expect((jobs[0].width, jobs[0].height), (800, 1600), reason: 'rotated + Standard');
      expect(jobs.map((j) => j.id).toSet(), hasLength(3));
      await box.kick();
      box.stopTimer();
      expect(srv.sentMember, hasLength(3));
      final descs = [
        for (final (_, env) in srv.sentMember)
          MediaDescriptor.tryParse(_e2e.decrypt(
              self: _peer,
              senderPublicKey: _me.publicKey,
              ct: Ciphertext(
                  scheme: env['scheme'],
                  ciphertextB64: env['ciphertext'],
                  nonceB64: env['nonce'],
                  senderKeyId: env['sender_key_id']))!)!
      ];
      // in order, one album, E2E: nothing about the album in the clear
      expect(descs.map((d) => d.album!.index).toList(), [0, 1, 2]);
      expect((descs[0].width, descs[0].height), (800, 1600));
      expect(descs[0].mime, 'image/jpeg');
      for (final (_, env) in srv.sentMember) {
        expect(env.keys.where((k) => k.contains('alb')), isEmpty);
      }
    });

    test('a single item is a plain photo (no album)', () async {
      final box = MediaOutbox(store: MemStore(), transport: FakeServer());
      final d = await preparePhotoBytes(_jpeg(100, 80), 'p.jpg');
      final jobs = await queueAlbumChoice(AlbumSendChoice([AlbumSendItem(d)]),
          chatKind: 'group', chatId: 9, outbox: box);
      await box.kick();
      box.stopTimer();
      expect(jobs.single.album, isNull);
      expect(jobs.single.prep, isNull, reason: 'small + no rotation: sent as picked');
    });
  });

  group('preview', () {
    Future<List<MediaDraft>> drafts(int n) async => [
          for (var i = 0; i < n; i++) await preparePhotoBytes(_jpeg(60, 40), 'p$i.jpg')
        ];

    testWidgets('swipe count, remove one, caption, HD, Send returns the album', (tester) async {
      final ds = await tester.runAsync(() => drafts(3));
      AlbumSendChoice? got;
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      got = await Navigator.of(ctx).push<AlbumSendChoice>(MaterialPageRoute(
                          builder: (_) => AlbumSendPreview(
                              drafts: ds!,
                              allowViewOnce: true,
                              sendBarExtras: const [SizedBox(key: Key('extra-slot'))])));
                    },
                    child: const Text('go'),
                  ),
                ),
              ))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('1 of 3'), findsOneWidget);
      expect(find.byKey(const Key('e-vo-toggle')), findsOneWidget);
      expect(find.byKey(const Key('extra-slot')), findsOneWidget);
      await tester.tap(find.byKey(const Key('cm-thumb-1')));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cm-remove')));
      await tester.pumpAndSettle();
      expect(find.text('2 of 2'), findsOneWidget);
      expect(File(ds![1].path).existsSync(), isFalse, reason: 'removed item deleted');
      await tester.tap(find.byKey(const Key('cm-rotate')));
      await tester.tap(find.byKey(const Key('cm-hd-toggle')));
      await tester.enterText(find.byKey(const Key('cm-caption')), 'Eid at home');
      await tester.pump();
      await tester.tap(find.byKey(const Key('cm-send')));
      await tester.pumpAndSettle();
      expect(got!.items.map((i) => i.draft.path).toList(), [ds[0].path, ds[2].path]);
      expect(got!.items.last.turns, 1);
      expect(got!.caption, 'Eid at home');
      expect(got!.hd, isTrue);
      expect(got!.viewOnce, isFalse);
    });

    testWidgets('one item: no counter / strip; closing deletes the picked copy',
        (tester) async {
      final ds = await tester.runAsync(() => drafts(1));
      await tester.pumpWidget(_app(AlbumSendPreview(drafts: ds!)));
      expect(find.byKey(const Key('cm-preview-count')), findsNothing, reason: 'one item');
      expect(find.byKey(const Key('cm-strip')), findsNothing);
      await tester.pumpWidget(_app(const SizedBox()));
      expect(File(ds.first.path).existsSync(), isFalse);
    });

    testWidgets('add more stops at the limit', (tester) async {
      final ds = await tester.runAsync(() => drafts(2));
      final extra = await tester.runAsync(() => drafts(3));
      int? asked;
      await tester.pumpWidget(_app(AlbumSendPreview(
          drafts: ds!,
          limit: 4,
          onAddMore: (left) async {
            asked = left;
            return extra!;
          })));
      await tester.tap(find.byKey(const Key('cm-add-more')));
      await tester.pumpAndSettle();
      expect(asked, 2);
      expect(find.byKey(const Key('cm-thumb-3')), findsOneWidget);
      expect(find.text('1 of 4'), findsOneWidget);
      expect(find.byKey(const Key('cm-add-more')), findsNothing, reason: 'limit reached');
    });
  });

  group('upload progress + retry in the bubble', () {
    MediaJob job(String id, int i, {String state = 'queued', String err = ''}) => MediaJob(
        id: id, chatKind: 'member', chatId: 5, kind: 'photo', srcPath: '/none',
        name: 'a.jpg', mime: 'image/jpeg', plainSize: 10, at: DateTime(2026),
        width: 400, height: 300, album: AlbumRef(id: 'x', index: i, count: 3),
        state: state, error: err);

    testWidgets('per-item ring, "1 of 3 sent", failed item: Retry', (tester) async {
      final items = [
        AlbumItem(id: 's', desc: _desc(_ref(1))),
        AlbumItem(id: 'j1', job: job('j1', 1)),
        AlbumItem(id: 'j2', job: job('j2', 2)),
      ];
      MediaOutbox.instance.progress.value = {'j1': 0.4};
      await tester.pumpWidget(_app(Scaffold(
          body: PhotoBubbleShell(
              items: items, bg: Colors.teal, fg: Colors.white,
              meta: const PhotoMetaPill(children: [Text('10:30')])))));
      expect(find.byKey(const Key('cm-send-cancel-j1')), findsOneWidget);
      expect(find.byKey(const Key('cm-send-cancel-j2')), findsOneWidget);
      expect(find.text('1 of 3 sent'), findsOneWidget);
      expect(find.text('10:30'), findsOneWidget);
      final failedItems = [
        items[0],
        AlbumItem(id: 'j1', job: job('j1', 1, state: 'failed', err: 'Too big')),
        items[2],
      ];
      await tester.pumpWidget(_app(Scaffold(
          body: PhotoBubbleShell(
              items: failedItems, bg: Colors.teal, fg: Colors.white,
              meta: const PhotoMetaPill(children: [Text('10:30')])))));
      expect(find.text('Too big'), findsOneWidget);
      expect(find.byKey(const Key('cm-send-retry-j1')), findsOneWidget);
      expect(find.byKey(const Key('cm-album-retry')), findsOneWidget);
      expect(find.byKey(const Key('cm-album-remove')), findsOneWidget);
      MediaOutbox.instance.progress.value = const {};
    });

    testWidgets('a received photo with no caption has no frame and no caption row',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
          body: PhotoBubbleShell(
              items: [AlbumItem(id: '1', desc: _desc(_ref(1)))],
              bg: Colors.teal, fg: Colors.white,
              meta: const PhotoMetaPill(children: [Text('09:00')])))));
      final box = tester.getSize(find.byKey(const Key('cm-photo-bubble')));
      final pic = tester.getSize(find.byKey(const Key('cm-album-1')));
      expect(box, pic, reason: 'edge to edge: no padding around the photo');
      expect(find.byKey(const Key('cm-album-status')), findsNothing);
    });
  });

  group('viewer', () {
    testWidgets('swipes through the album, shows Save + Forward, blurred wait', (tester) async {
      final files = Directory('${dir.path}/files')..createSync(recursive: true);
      final bytes = _jpeg(40, 30);
      File('${files.path}/${_ref(1)}.jpg').writeAsBytesSync(bytes);
      File('${files.path}/${_ref(2)}.jpg').writeAsBytesSync(bytes);
      int? fwd;
      await tester.pumpWidget(_app(AlbumViewer(
          items: [_desc(_ref(1)), _desc(_ref(2), cap: 'second')],
          onForward: (i) => fwd = i)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.byKey(const Key('cm-viewer-save')), findsOneWidget);
      await tester.drag(find.byKey(const Key('cm-viewer-pager')), const Offset(-500, 0));
      // (no pumpAndSettle: a page still decoding shows a spinner)
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('2 of 2'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cm-viewer-forward')));
      expect(fwd, 1);
    });
  });
}
