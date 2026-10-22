// md1 — My Circle E2E media on the phone: descriptor (envelope fields),
// metadata scrub (EXIF GPS gone, orientation kept), the media outbox
// (chunked resumable upload, retry after a drop, waiting for a key, honest
// permanent failure, cancel, group fan-out), the download cache (decrypt,
// sha mismatch = damaged, 404 = gone), auto-download policy, the attach
// sheet, the viewer's Save/Share, the voice bubble and the recorder sheet.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/media_api.dart';
import 'package:assisto/messaging/media/media_crypto.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_outbox.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/voice_bubble.dart';
import 'package:assisto/messaging/media/voice_player.dart';
import 'package:assisto/messaging/media/voice_recorder_sheet.dart';
import 'package:assisto/widgets/circle_attach_sheet.dart';
import 'package:assisto/widgets/circle_media_viewer.dart';
import 'package:crypto/crypto.dart' as hc;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();
final _peer2 = _e2e.generateIdentity();

/// In-memory server that behaves like core/views_md1_media.py.
class FakeServer implements MediaTransport {
  final blobs = <String, Map<String, dynamic>>{}; // ref -> {kind,size,sha,data,complete}
  final sentMember = <(int, Map<String, dynamic>)>[];
  final sentGroup = <(int, Map<String, dynamic>)>[];
  String peerPub = '';
  List<Map<String, dynamic>> roster = [];
  int failPutsAfter = -1; // throw a network error on the N-th put
  int puts = 0;
  MediaHttpError? createError;
  int _n = 0;

  @override
  Future<Map<String, dynamic>> createBlob(String kind, int size, String sha256) async {
    if (createError != null) throw createError!;
    final ref = (++_n).toRadixString(16).padLeft(32, 'a');
    blobs[ref] = {'kind': kind, 'size': size, 'sha': sha256, 'data': BytesBuilder(), 'complete': false};
    return {'ref': ref, 'received': 0};
  }

  int _recv(String ref) => (blobs[ref]!['data'] as BytesBuilder).length;

  @override
  Future<Map<String, dynamic>> blobStatus(String ref) async {
    final b = blobs[ref];
    if (b == null) throw const MediaHttpError(404);
    return {'received': _recv(ref), 'complete': b['complete']};
  }

  @override
  Future<Map<String, dynamic>> putChunk(String ref, int offset, Uint8List bytes) async {
    puts++;
    if (failPutsAfter >= 0 && puts == failPutsAfter) {
      throw const SocketException('drop');
    }
    if (offset != _recv(ref)) {
      throw MediaHttpError(409, body: {'received': _recv(ref)});
    }
    (blobs[ref]!['data'] as BytesBuilder).add(bytes);
    return {'received': _recv(ref)};
  }

  @override
  Future<Map<String, dynamic>> finish(String ref) async {
    final b = blobs[ref]!;
    final data = (b['data'] as BytesBuilder).toBytes();
    if (data.length != b['size'] || hc.sha256.convert(data).toString() != b['sha']) {
      throw MediaHttpError(409, body: {'complete': false});
    }
    b['complete'] = true;
    return {'complete': true};
  }

  @override
  Future<void> cancelBlob(String ref) async => blobs.remove(ref);

  @override
  Future<Map<String, dynamic>> downloadUrl(String ref) async {
    if (blobs[ref]?['complete'] != true) throw const MediaHttpError(404);
    return {'url': '/dl/$ref', 'size': blobs[ref]!['size']};
  }

  Uint8List? tamper;
  @override
  Future<void> download(String url, IOSink sink,
      {void Function(int got)? onBytes, bool Function()? cancelled}) async {
    final ref = url.split('/').last;
    final data = tamper ?? (blobs[ref]!['data'] as BytesBuilder).toBytes();
    sink.add(data);
    onBytes?.call(data.length);
  }

  @override
  Future<Map<String, dynamic>> peerKey(int memberId) async => {'public_key': peerPub};

  @override
  Future<List<Map<String, dynamic>>> groupRoster(int groupId) async => roster;

  @override
  Future<Map<String, dynamic>> sendMember(int memberId, Map<String, dynamic> env) async {
    sentMember.add((memberId, env));
    return {'id': 900 + sentMember.length};
  }

  @override
  Future<Map<String, dynamic>> sendGroup(int groupId, Map<String, dynamic> env) async {
    sentGroup.add((groupId, env));
    return {'id': 800 + sentGroup.length};
  }
}

class MemStore implements MediaJobStore {
  List<Map<String, dynamic>> rows = [];
  @override
  Future<List<Map<String, dynamic>>> load() async =>
      rows.map((r) => Map<String, dynamic>.from(r)).toList();
  @override
  Future<void> save(List<Map<String, dynamic>> r) async => rows = r;
}

/// A tiny JPEG skeleton: SOI, APP0 JFIF, APP1 EXIF (orientation 6 + a GPS
/// IFD pointer + "GPSDATA" bytes), COM, DQT, SOF0 (w=40,h=30), SOS, data, EOI.
Uint8List jpegWithGps() {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8]);
  b.add([0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
  final tiff = <int>[
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x02, 0x00,
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x25, 0x88, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x26, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    ...'GPSDATA-23.8103N-90.4125E'.codeUnits,
  ];
  final app1 = [...'Exif'.codeUnits, 0, 0, ...tiff];
  b.add([0xFF, 0xE1, (app1.length + 2) >> 8, (app1.length + 2) & 0xff, ...app1]);
  final com = 'Dhaka home'.codeUnits;
  b.add([0xFF, 0xFE, 0, com.length + 2, ...com]);
  b.add([0xFF, 0xDB, 0x00, 0x05, 0x00, 0x01, 0x02]);
  b.add([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 30, 0x00, 40, 0x01, 0x01, 0x11, 0x00]);
  b.add([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x12, 0x34, 0x56]);
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

bool _contains(Uint8List hay, String needle) =>
    latin1.decode(hay, allowInvalid: true).contains(needle);

Future<MediaJob> _job(Directory dir, String kind, int size,
    {String chatKind = 'member', int chatId = 5}) async {
  final f = File('${dir.path}/src-${DateTime.now().microsecondsSinceEpoch}.bin');
  final data = Uint8List.fromList(List.generate(size, (i) => (i * 7 + 3) & 0xff));
  await f.writeAsBytes(data);
  return MediaJob(
    id: 'local-${DateTime.now().microsecondsSinceEpoch}',
    chatKind: chatKind,
    chatId: chatId,
    kind: kind,
    srcPath: f.path,
    name: kind == 'document' ? 'rent-receipt.pdf' : 'IMG-1.jpg',
    mime: kind == 'document' ? 'application/pdf' : 'image/jpeg',
    plainSize: size,
    at: DateTime.now(),
    width: 1600,
    height: 1200,
    thumbB64: base64Encode([1, 2, 3]),
    caption: 'our new room',
  );
}

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    );

class FakeVoice implements VoiceBackend {
  final calls = <String>[];
  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _done = StreamController<void>.broadcast();
  @override
  Future<void> play(String path) async => calls.add('play $path');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> seek(Duration d) async => calls.add('seek ${d.inMilliseconds}');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Stream<Duration> get position => _pos.stream;
  @override
  Stream<Duration> get duration => _dur.stream;
  @override
  Stream<void> get completed => _done.stream;
}

class FakeRecorder implements RecorderBackend {
  final amp = StreamController<double>.broadcast();
  String path = '';
  @override
  Future<void> start(String p) async {
    path = p;
    File(p).writeAsBytesSync(List.filled(4000, 7));
  }

  @override
  Future<String?> stop() async => path;
  @override
  Future<void> cancel() async {}
  @override
  Stream<double> amplitude() => amp.stream;
  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('md1t');
    MediaDirs.override = dir.path;
  });
  tearDown(() async {
    MediaDirs.override = null;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  group('descriptor = the envelope plaintext', () {
    test('round trip keeps every field; bad shapes are refused', () {
      final d = MediaDescriptor(
          kind: 'voice', ref: 'r' * 32, key: randomBytes(32), nonce: randomBytes(12),
          sha256: 'a' * 64, size: 1000, plainSize: 984, mime: 'audio/mp4',
          name: 'voice.m4a', durationMs: 4200, wave: const [1, 31, 40, -3]);
      final back = MediaDescriptor.tryParse(d.encode())!;
      expect(back.kind, 'voice');
      expect(back.key, d.key);
      expect(back.nonce, d.nonce);
      expect(back.durationMs, 4200);
      expect(back.wave, [1, 31, 31, 0]); // clamped
      expect(back.ext, 'm4a');
      expect(MediaDescriptor.tryParse('hello'), isNull);
      expect(MediaDescriptor.tryParse('{"md1":1,"kind":"video"}'), isNull);
      final bad = d.toJson()..['k'] = base64Encode([1, 2]);
      expect(MediaDescriptor.tryParse(jsonEncode(bad)), isNull);
      // a received file name can never carry a path
      final evil = d.toJson()..['name'] = '../../shared_prefs/x.xml';
      expect(MediaDescriptor.tryParse(jsonEncode(evil))!.name, 'x.xml');
    });
  });

  group('photo metadata scrub (on the phone, before encryption)', () {
    test('EXIF/GPS, comments gone; orientation + image data kept', () {
      final raw = jpegWithGps();
      expect(_contains(raw, 'GPSDATA'), isTrue);
      expect(jpegOrientation(raw), 6);
      final out = scrubJpeg(raw);
      expect(_contains(out, 'GPSDATA'), isFalse);
      expect(_contains(out, 'Dhaka home'), isFalse);
      expect(jpegOrientation(out), 6, reason: 'stays upright');
      expect(jpegSize(out), (30, 40), reason: 'orientation 6 swaps w/h');
      expect(out.sublist(out.length - 5), raw.sublist(raw.length - 5));
      expect(_contains(out, 'JFIF'), isTrue);
    });

    test('PNG text / EXIF chunks are dropped', () {
      List<int> chunk(String type, List<int> data) =>
          [0, 0, 0, data.length, ...type.codeUnits, ...data, 0, 0, 0, 0];
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ...chunk('IHDR', List.filled(13, 1)),
        ...chunk('tEXt', 'GPS=23.8,90.4'.codeUnits),
        ...chunk('eXIf', 'EXIFGPS'.codeUnits),
        ...chunk('IDAT', [1, 2, 3]),
        ...chunk('IEND', const []),
      ]);
      final out = scrubPng(png);
      expect(_contains(out, 'GPS'), isFalse);
      expect(_contains(out, 'IDAT'), isTrue);
      expect(_contains(out, 'IEND'), isTrue);
    });
  });

  group('media outbox', () {
    test('seal -> chunked upload -> E2E message; the server never gets the key', () async {
      final srv = FakeServer()..peerPub = _peer.publicKeyB64;
      final box = MediaOutbox(store: MemStore(), transport: srv)
        ..identity = () async => _me;
      MediaCache.instance = MediaCache(transport: srv);
      final job = await _job(dir, 'photo', 1300 * 1024); // 3 chunks
      await box.add(job);
      await box.kick();
      box.stopTimer();
      expect(srv.sentMember, hasLength(1));
      final (mid, env) = srv.sentMember.single;
      expect(mid, 5);
      expect(env['content_type'], 'photo');
      expect(env['client_msg_id'], job.id);
      final ref = env['blob_ref'] as String;
      expect(srv.blobs[ref]!['complete'], isTrue);
      // envelope = routing + ciphertext only: no key / name / caption in clear
      for (final k in ['key', 'k', 'name', 'caption', 'cap', 'mime', 'thumb']) {
        expect(env.containsKey(k), isFalse, reason: k);
      }
      expect(jsonEncode(env).contains('our new room'), isFalse);
      // the peer decrypts the descriptor and then the file
      final pt = _e2e.decrypt(self: _peer, senderPublicKey: _me.publicKey,
          ct: Ciphertext(scheme: env['scheme'], ciphertextB64: env['ciphertext'],
              nonceB64: env['nonce'], senderKeyId: env['sender_key_id']))!;
      final d = MediaDescriptor.tryParse(pt)!;
      expect((d.ref, d.caption, d.width, d.plainSize), (ref, 'our new room', 1600, 1300 * 1024));
      final cipher = (srv.blobs[ref]!['data'] as BytesBuilder).toBytes();
      expect(d.sha256, hc.sha256.convert(cipher).toString());
      expect(openBytes(d.key, d.nonce, cipher), File(job.srcPath).existsSync()
          ? File(job.srcPath).readAsBytesSync() : isNotNull);
      // queue empty; my plaintext copy became the cache file
      expect(await box.all(), isEmpty);
      expect(File('${dir.path}/files/$ref.jpg').existsSync(), isTrue);
      expect(Directory('${dir.path}/up').listSync(), isEmpty, reason: 'enc copy removed');
    });

    test('a dropped connection resumes at the server offset (no restart)', () async {
      final srv = FakeServer()
        ..peerPub = _peer.publicKeyB64
        ..failPutsAfter = 2;
      final box = MediaOutbox(store: MemStore(), transport: srv)
        ..identity = () async => _me;
      final job = await _job(dir, 'document', 1500 * 1024); // 3 chunks
      final store = MemStore();
      final box2 = MediaOutbox(store: store, transport: srv)
        ..identity = () async => _me;
      store.rows = [job.toJson()];
      expect(await box2.process(job), MediaStep.waiting, reason: 'drop on chunk 2');
      final left = await box2.all();
      expect(left.single.state, 'queued', reason: 'kept: clock + retry');
      expect(left.single.ref, isNotEmpty);
      expect(srv.sentMember, isEmpty);
      await box2.kick();
      box2.stopTimer();
      expect(srv.sentMember, hasLength(1));
      expect(srv.puts, 4, reason: '1 ok + 1 dropped + the 2 missing chunks only');
      box.stopTimer();
    });

    test('no peer key yet: uploads, then waits silently (never a key error)', () async {
      final srv = FakeServer();
      final box = MediaOutbox(store: MemStore(), transport: srv)
        ..identity = () async => _me;
      await box.add(await _job(dir, 'voice', 2000));
      await box.kick();
      box.stopTimer();
      expect(srv.sentMember, isEmpty);
      expect((await box.all()).single.failed, isFalse);
      srv.peerPub = _peer.publicKeyB64;
      await box.kick();
      box.stopTimer();
      expect(srv.sentMember, hasLength(1));
      expect(srv.blobs, hasLength(1), reason: 'no second upload');
    });

    test('a refused upload (daily limit) fails honestly with the server sentence', () async {
      final srv = FakeServer()
        ..createError = const MediaHttpError(429,
            reason: 'daily_quota', detail: "Today's sending limit is used up (300 MB).");
      final box = MediaOutbox(store: MemStore(), transport: srv)
        ..identity = () async => _me;
      await box.add(await _job(dir, 'photo', 100));
      await box.kick();
      box.stopTimer();
      final j = (await box.all()).single;
      expect(j.failed, isTrue);
      expect(j.error, contains('300 MB'));
      srv.createError = null;
      srv.peerPub = _peer.publicKeyB64;
      await box.retry(j.id);
      await box.kick();
      box.stopTimer();
      expect(srv.sentMember, hasLength(1));
    });

    test('cancel removes the job, local copies and the server blob', () async {
      final srv = FakeServer()..peerPub = '';
      final box = MediaOutbox(store: MemStore(), transport: srv)
        ..identity = () async => _me;
      final job = await _job(dir, 'document', 5000);
      await box.add(job);
      await box.kick();
      box.stopTimer();
      expect(srv.blobs, hasLength(1));
      await box.cancel(job.id);
      expect(await box.all(), isEmpty);
      expect(srv.blobs, isEmpty);
      expect(File(job.srcPath).existsSync(), isFalse);
    });

    test('group: one upload, the key travels in every member\'s envelope', () async {
      final srv = FakeServer()
        ..roster = [
          {'id': 11, 'is_self': true, 'public_key': _me.publicKeyB64},
          {'id': 12, 'public_key': _peer.publicKeyB64},
          {'id': 13, 'public_key': _peer2.publicKeyB64},
          {'id': 14, 'public_key': ''},
        ];
      final box = MediaOutbox(store: MemStore(), transport: srv)
        ..identity = () async => _me;
      await box.add(await _job(dir, 'voice', 3000, chatKind: 'group', chatId: 7));
      await box.kick();
      box.stopTimer();
      final (gid, env) = srv.sentGroup.single;
      expect(gid, 7);
      expect(env['recipient_ids'], [12, 13]);
      final per = (env['per_recipient'] as Map).cast<String, dynamic>();
      for (final (id, who) in [('12', _peer), ('13', _peer2)]) {
        final e = (per[id] as Map).cast<String, dynamic>();
        final pt = _e2e.decrypt(self: who, senderPublicKey: _me.publicKey,
            ct: Ciphertext(scheme: _e2e.scheme, ciphertextB64: e['ciphertext'],
                nonceB64: e['nonce'], senderKeyId: _me.keyId));
        expect(MediaDescriptor.tryParse(pt!)!.ref, env['blob_ref']);
      }
      expect(srv.blobs, hasLength(1));
    });
  });

  group('download cache', () {
    Future<(FakeServer, MediaDescriptor, Uint8List)> uploaded() async {
      final srv = FakeServer();
      final plain = Uint8List.fromList(List.generate(70000, (i) => i & 0xff));
      final key = randomBytes(32), nonce = randomBytes(12);
      final cipher = sealBytes(key, nonce, plain);
      final ref = 'b' * 32;
      srv.blobs[ref] = {'complete': true, 'size': cipher.length,
          'data': BytesBuilder()..add(cipher)};
      return (srv, MediaDescriptor(kind: 'document', ref: ref, key: key, nonce: nonce,
          sha256: hc.sha256.convert(cipher).toString(), size: cipher.length,
          plainSize: plain.length, name: 'a.pdf', mime: 'application/pdf'), plain);
    }

    test('downloads, checks sha256, decrypts into the private cache', () async {
      final (srv, d, plain) = await uploaded();
      final cache = MediaCache(transport: srv);
      final f = await cache.fetch(d);
      expect(f, isNotNull);
      expect(f!.readAsBytesSync(), plain);
      expect(f.path.startsWith(dir.path), isTrue);
      expect(cache.cachedSync(d)?.path, f.path);
      expect(cache.states.value, isEmpty);
    });

    test('a swapped / damaged blob is refused (damaged), never shown', () async {
      final (srv, d, _) = await uploaded();
      srv.tamper = Uint8List.fromList(List.filled(d.size, 9));
      final cache = MediaCache(transport: srv);
      expect(await cache.fetch(d), isNull);
      expect(cache.states.value[d.ref]?.error, 'damaged');
      expect(cache.cachedSync(d), isNull);
    });

    test('expired on the server -> gone (honest "ask them to send again")', () async {
      final (_, d, _) = await uploaded();
      final cache = MediaCache(transport: FakeServer());
      expect(await cache.fetch(d), isNull);
      expect(cache.states.value[d.ref]?.error, 'gone');
    });

    test('auto-download: Wi-Fi yes by default, mobile data only when allowed', () async {
      MediaPrefs.metered = () async => false;
      expect(await MediaPrefs.shouldAutoDownload('photo'), isTrue);
      MediaPrefs.metered = () async => true;
      expect(await MediaPrefs.shouldAutoDownload('photo'), isFalse);
      await MediaPrefs.setMobileAuto('photo', true);
      expect(await MediaPrefs.shouldAutoDownload('photo'), isTrue);
      expect(await MediaPrefs.shouldAutoDownload('document'), isFalse);
      MediaPrefs.metered = () async => null; // unknown = careful
      expect(await MediaPrefs.shouldAutoDownload('voice'), isFalse);
    });
  });

  group('UI', () {
    testWidgets('attach sheet lists only the working kinds', (tester) async {
      await tester.pumpWidget(_app(Builder(
          builder: (c) => TextButton(
              onPressed: () => showCircleAttachSheet(c), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      for (final k in ['gallery', 'camera', 'voice', 'document']) {
        expect(find.byKey(Key('attach-$k')), findsOneWidget, reason: k);
      }
      for (final k in ['video', 'contact', 'location', 'liveLocation']) {
        expect(find.byKey(Key('attach-$k')), findsNothing, reason: k);
      }
    });

    testWidgets('viewer: pinch-zoom page with Save + Share for a decrypted photo',
        (tester) async {
      String? did;
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');
      await tester.pumpWidget(_app(CircleMediaViewer(
          items: [MediaViewerItem(id: '1', bytes: png)],
          onSave: (_) => did = 'save',
          onShare: (_) => did = 'share')));
      await tester.pump();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byKey(const Key('mv-share')));
      expect(did, 'share');
      await tester.tap(find.byKey(const Key('mv-save')));
      expect(did, 'save');
    });

    testWidgets('voice bubble plays, pauses and seeks through one player', (tester) async {
      final fake = FakeVoice();
      VoicePlayer.backendFactory = () => fake;
      await tester.pumpWidget(_app(const VoiceNoteBody(
          path: '/x/v.m4a', durationMs: 10000, wave: [3, 9, 20, 31, 12], fg: Colors.black)));
      expect(find.text('0:10'), findsOneWidget);
      await tester.tap(find.byKey(const Key('md1-voice-play')));
      await tester.pump();
      expect(fake.calls.last, 'play /x/v.m4a');
      expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
      await tester.tap(find.byKey(const Key('md1-voice-play')));
      await tester.pump();
      expect(fake.calls.last, 'pause');
      final wave = tester.getRect(find.byKey(const Key('md1-voice-wave')));
      await tester.tapAt(Offset(wave.left + wave.width / 2, wave.center.dy));
      await tester.pump();
      expect(fake.calls.last, startsWith('seek '));
      final ms = int.parse(fake.calls.last.split(' ').last);
      expect(ms, inInclusiveRange(4000, 6000));
      await VoicePlayer.instance.stop();
    });

    testWidgets('recorder sheet: records, shows the time, sends a voice draft',
        (tester) async {
      final rec = FakeRecorder();
      recorderFactory = () => rec;
      MediaDraft? got;
      await tester.pumpWidget(_app(Builder(
          builder: (c) => TextButton(
              onPressed: () async => got = await showModalBottomSheet<MediaDraft>(
                  context: c, builder: (_) => const VoiceRecorderSheet()),
              child: const Text('rec')))));
      await tester.tap(find.text('rec'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump(const Duration(milliseconds: 300));
      rec.amp.add(-12);
      await tester.pump();
      expect(find.byKey(const Key('md1-rec-time')), findsOneWidget);
      await tester.tap(find.byKey(const Key('md1-rec-send')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(got?.kind, 'voice');
      expect(got?.mime, 'audio/mp4');
      expect(got!.durationMs, greaterThanOrEqualTo(1000));
      expect(levelFromDb(0), 31);
      expect(levelFromDb(-60), 0);
      expect(compactWave(List.generate(480, (i) => i % 32)), hasLength(48));
    });
  });
}
