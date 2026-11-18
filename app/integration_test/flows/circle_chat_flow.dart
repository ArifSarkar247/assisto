// circle-chat (18 Nov, board row 2) — My Circle chat PROVEN end to end on the
// CI emulator against the throw-away Django, with FOUR real accounts:
//
//   A = Reality Rahim (this app, driven through the UI)
//   B = Reality Karim, C = Reality Nadia, D = Reality Selim
//       (independent API clients = the other phones; B even runs the app's
//        own MediaOutbox / media crypto code as its "phone")
//
//   cc1 offline send -> clock -> network back -> delivered EXACTLY once, ticks
//   cc2 5 MB photo + 20 MB video BOTH ways: progress ring, a REAL network cut
//       (airplane mode) mid-upload and mid-download, resume (no restart),
//       thumbnails, decrypt + sha check on the other side
//   cc3 voice note recorded on A (emulator mic) -> B decrypts it; B's voice
//       note plays on A
//   cc4 group of 4: send, remove D (D can't read new messages; a STALE
//       roster copy for D is dropped by the server), add D back
//   cc5 reply, edit, delete for everyone, forward (UI long-press menu)
//   cc6 reinstall: key backup with a PIN -> a NEW sandbox + NEW device
//       session -> restore screen -> the old history decrypts again
//
// Opt-in group "chat" (reality.yml only=chat). Network toggling: the app
// prints REALITY_NET off|on, tools/reality/run_flows.sh switches airplane
// mode with adb (same handshake as e2e9). Test accounts only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/crypto/key_backup.dart';
import 'package:assisto/crypto/key_wiring.dart';
import 'package:assisto/messaging/media/media_api.dart';
import 'package:assisto/messaging/media/media_crypto.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_outbox.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_send.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/voice_player.dart';
import 'package:assisto/messaging/msg_notify.dart' show loadStoredIdentity;
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/screens/e2_restore_screen.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:assisto/state.dart' show Settings;

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;
const _phoneC = String.fromEnvironment('REALITY_PHONE_C', defaultValue: '01711000777');
const _phoneD = String.fromEnvironment('REALITY_PHONE_D', defaultValue: '01700000004');

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      return false;
    });

final _e2e = SoftwareE2E();

/// One "other phone": its API session + its own E2E identity.
class _Peer {
  _Peer(this.name, this.api, this.id);
  final String name;
  final ApiClient api;
  final IdentityKeyPair id;
}

class _Ctx {
  _Peer? b, c, d;
  int? gid; // the group of 4
}

final _ctx = _Ctx();

Future<ApiClient> _login(String phone, String device) async {
  final c = ApiClient();
  final appDevice = AppConfig.deviceId;
  AppConfig.deviceId = device;
  try {
    c.token = (await c.login(identifier: phone, password: Seed.password)).token;
  } finally {
    AppConfig.deviceId = appDevice;
  }
  c.lang = 'en';
  return c;
}

ApiClient _apiA(RFlow f) => ApiClient.detached(f.app.api.token ?? '')..lang = 'en';

/// A <-> [p] are in each other's My Circle (request + accept, real endpoints).
Future<void> _connect(ApiClient a, _Peer p, String phone) async {
  final have = _rows(await a.getJson('/circle/members'))
      .any((m) => '${m['name']}'.contains(p.name) && '${m['state'] ?? 'accepted'}' == 'accepted');
  if (have) return;
  try {
    await a.postJson('/circle/request', {'phone': phone, 'name': p.name, 'relation': 'friend'});
  } catch (_) {} // already requested
  final inc = _rows(await p.api.getJson('/circle/requests'))
      .where((r) => '${r['direction'] ?? ''}' == 'incoming')
      .toList();
  for (final r in inc) {
    await p.api.postJson('/circle/request/${r['id']}/act', {'event': 'accept'});
  }
}

Future<_Peer> _peer(String name, String phone, String device, {bool userB = false, RFlow? f}) async {
  final api = userB && f != null ? await f.h.backend(userB: true) : await _login(phone, device);
  final id = _e2e.generateIdentity();
  await api.postJson('/circle/keys',
      {'public_key': id.publicKeyB64, 'key_id': id.keyId, 'scheme': _e2e.scheme});
  return _Peer(name, api, id);
}

/// Sign-in (if this drive starts cold) + B, C, D + A's key published.
Future<void> _setup(RFlow f) async {
  for (var i = 0; i < 40 && f.app.loading; i++) {
    await f.pumpFor(const Duration(milliseconds: 250));
  }
  if (!f.app.loggedIn || !f.app.onboarded) {
    await f.step('A signs in (test account)', () async {
      if (f.app.locale?.languageCode != 'en') {
        await f.net(() => f.app.setLocale(const Locale('en')));
      }
      if (!f.app.loggedIn) {
        await f.net(() => f.app.login(identifier: Seed.phoneA, password: Seed.password));
      }
      await f.net(() => Settings.setBool('onboarded', true));
      f.app.markOnboarded();
      await f.pumpFor(const Duration(seconds: 3));
    });
  }
  await f.home();
  KeyWiring.instance.start(f.app);
  if (_ctx.b != null) return;
  await f.step('the other phones: B, C, D sign in, publish keys, join A\'s circle', () async {
    await f.net(() async {
      _ctx.b = await _peer('Karim', Seed.phoneB, 'cc-b', userB: true, f: f);
      _ctx.c = await _peer('Nadia', _phoneC, 'cc-c');
      _ctx.d = await _peer('Selim', _phoneD, 'cc-d');
      final a = _apiA(f);
      await _connect(a, _ctx.c!, _phoneC);
      await _connect(a, _ctx.d!, _phoneD);
    });
    await f.eventually('A has a published key (B sees it)', () async {
      final e = await _edgeTo(_ctx.b!.api, 'Rahim');
      return '${e['public_key'] ?? ''}'.isNotEmpty;
    }, seconds: 30);
  });
}

Future<Map<String, dynamic>> _edgeTo(ApiClient api, String name) async =>
    _rows(await api.getJson('/circle/members')).firstWhere((m) => '${m['name']}'.contains(name));

/// Ask the CI host to switch airplane mode (adb) and wait for the real state.
Future<void> _airplane(RFlow f, bool on) async {
  final file = 'cc_net_${on ? 'off' : 'on'}_${DateTime.now().millisecondsSinceEpoch}';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_NET ${on ? 'off' : 'on'} $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) break;
  }
  await f.eventually(on ? 'backend UNREACHABLE (airplane mode on)' : 'backend reachable again',
      () async => (await _reachable()) != on,
      seconds: on ? 30 : 90);
}

Future<bool> _reachable() async {
  final u = Uri.parse(AppConfig.apiBase);
  try {
    final s = await Socket.connect(u.host, u.hasPort ? u.port : 80,
        timeout: const Duration(seconds: 2));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _openChatWith(RFlow f, String name) async {
  await f.openRoute('circle');
  if (await f.appears(find.byKey(const Key('bbl2-later')), seconds: 3)) {
    await f.tap(find.byKey(const Key('bbl2-later')), settleSeconds: 2);
  }
  await f.waitFor(find.text(name), seconds: 20, what: '$name in the My Circle list');
  await f.tap(find.text(name).first, settleSeconds: 3);
  await f.waitFor(find.byType(CircleChatScreen), what: 'chat with $name');
}

Future<void> _openGroup(RFlow f, String name) async {
  await f.openRoute('circle');
  if (await f.appears(find.byKey(const Key('bbl2-later')), seconds: 3)) {
    await f.tap(find.byKey(const Key('bbl2-later')), settleSeconds: 2);
  }
  await f.waitFor(find.text(name), seconds: 20, what: 'group $name in the list');
  await f.tap(find.text(name).first, settleSeconds: 3);
  await f.waitFor(find.byType(CircleGroupChatScreen), what: 'group chat');
}

/// [p]'s 1:1 messages from A, decrypted (id -> {text, row}).
Future<List<(String, Map<String, dynamic>)>> _fromA(_Peer p) async {
  final edge = await _edgeTo(p.api, 'Rahim');
  final peer = base64Decode('${edge['public_key']}');
  final out = <(String, Map<String, dynamic>)>[];
  final msgs = _rows(await p.api.getJson('/circle/${edge['id']}/messages?limit=200'))
      .where((m) => m['mine'] != true)
      .toList()
    ..sort((a, b) => (a['id'] as num).compareTo(b['id'] as num));
  for (final m in msgs) {
    if ('${m['ciphertext'] ?? ''}'.isEmpty) {
      out.add(('', m));
      continue;
    }
    String? pt;
    try {
      pt = _e2e.decrypt(
          self: p.id,
          senderPublicKey: peer,
          ct: Ciphertext(
              ciphertextB64: '${m['ciphertext']}',
              nonceB64: '${m['nonce']}',
              senderKeyId: '${m['sender_key_id'] ?? ''}',
              scheme: '${m['scheme'] ?? _e2e.scheme}'));
    } catch (_) {}
    out.add((pt ?? '', m));
  }
  return out;
}

/// [p] sends A a 1:1 text; returns the server id.
Future<int> _sendToA(_Peer p, String text) async {
  final edge = await _edgeTo(p.api, 'Rahim');
  final ct = _e2e.encrypt(
      self: p.id, recipientPublicKey: base64Decode('${edge['public_key']}'), plaintext: text);
  final r = await p.api.postJson('/circle/${edge['id']}/messages', {
    'content_type': 'text',
    'client_msg_id': 'cc-${p.name}-${DateTime.now().microsecondsSinceEpoch}',
    ...ct.toEnvelopeFields(),
  });
  return (r['id'] as num).toInt();
}

/// [p]'s view of group [gid]: decrypted texts of A's messages + 404 check.
Future<List<(String, Map<String, dynamic>)>> _groupFromA(_Peer p, int gid) async {
  final roster = _rows(await p.api.getJson('/circle/groups/$gid/members'));
  final me = roster.firstWhere((m) => m['is_self'] == true);
  final a = roster.firstWhere((m) => '${m['name']}'.contains('Rahim'));
  final aPub = base64Decode('${a['public_key']}');
  final out = <(String, Map<String, dynamic>)>[];
  final msgs = _rows(await p.api.getJson('/circle/groups/$gid/messages?limit=200'))
      .where((m) => m['mine'] != true)
      .toList()
    ..sort((x, y) => (x['id'] as num).compareTo(y['id'] as num));
  for (final m in msgs) {
    final pr = m['per_recipient'];
    final mine = pr is Map ? pr['${me['member_id']}'] : null;
    String pt = '';
    if (mine is Map) {
      try {
        pt = _e2e.decrypt(
                self: p.id,
                senderPublicKey: aPub,
                ct: Ciphertext(
                    ciphertextB64: '${mine['ciphertext']}',
                    nonceB64: '${mine['nonce']}',
                    senderKeyId: '${m['sender_key_id'] ?? ''}',
                    scheme: '${m['scheme'] ?? _e2e.scheme}')) ??
            '';
      } catch (_) {}
    }
    out.add((pt, m));
  }
  return out;
}

// ---------------------------------------------------------------- network
/// Real HTTP, slowed to a phone-like rate so a REAL network cut (airplane
/// mode) lands in the middle of a 20 MB transfer. Logs every media call.
class _Slow extends http.BaseClient {
  _Slow(this.bytesPerSec);
  final int bytesPerSec;
  final http.Client _in = http.Client();
  final List<String> log = [];
  final List<int> putOffsets = [];
  final List<(int, int)> ranges = []; // (from, status)

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request && request.method == 'PUT') {
      final n = request.bodyBytes.length;
      putOffsets.add(int.tryParse(request.url.queryParameters['offset'] ?? '') ?? -1);
      await Future<void>.delayed(Duration(milliseconds: n * 1000 ~/ bytesPerSec));
    }
    final r = await _in.send(request);
    final range = request.headers['Range'] ?? '';
    log.add('${request.method} ${request.url.path} ${range.isEmpty ? '' : range} -> ${r.statusCode}');
    if (request.url.path.contains('/circle/media/dl/')) {
      final from = range.startsWith('bytes=') ? int.tryParse(range.substring(6).split('-').first) ?? 0 : 0;
      ranges.add((from, r.statusCode));
      return http.StreamedResponse(_throttle(r.stream), r.statusCode,
          contentLength: r.contentLength,
          request: r.request,
          headers: r.headers,
          reasonPhrase: r.reasonPhrase);
    }
    return r;
  }

  Stream<List<int>> _throttle(Stream<List<int>> s) async* {
    const piece = 64 * 1024;
    await for (final chunk in s) {
      for (var i = 0; i < chunk.length; i += piece) {
        final part = chunk.sublist(i, min(i + piece, chunk.length));
        await Future<void>.delayed(Duration(milliseconds: part.length * 1000 ~/ bytesPerSec));
        yield part;
      }
    }
  }
}

class _MemJobs implements MediaJobStore {
  List<Map<String, dynamic>> rows = [];
  @override
  Future<List<Map<String, dynamic>>> load() async => rows;
  @override
  Future<void> save(List<Map<String, dynamic>> r) async => rows = r;
}

class _NoLegacy implements LegacySecrets {
  const _NoLegacy();
  @override
  Future<String?> read(String name) async => null;
  @override
  Future<void> delete(String name) async {}
}

/// A [w]x[h] uncompressed PNG (~w*h*3 bytes): a real image the phone can show.
Uint8List _png(int w, int h, int seed) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, (x * 7 + seed) & 0xff, (y * 5 + seed) & 0xff, ((x ^ y) + seed) & 0xff);
    }
  }
  return img.encodePng(im, level: 0);
}

/// [mb] MB of incompressible bytes (a synthetic "video" payload).
Uint8List _blob(int mb, int seed) {
  final r = Random(seed);
  final block = Uint8List.fromList(List.generate(64 * 1024, (_) => r.nextInt(256)));
  final out = Uint8List(mb * 1024 * 1024);
  for (var i = 0; i < out.length; i += block.length) {
    out.setRange(i, min(i + block.length, out.length), block);
    out[i] = i >> 16 & 0xff; // no two blocks identical
  }
  return out;
}

Future<String> _tmpFile(String name, Uint8List bytes) async {
  final d = await Directory.systemTemp.createTemp('cc');
  final f = File('${d.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}

/// A queues [draft] in the open 1:1 chat through the app's own send screens
/// (photo preview / video confirm), exactly what follows the gallery picker.
Future<MediaJob> _queueFromUi(RFlow f, MediaDraft draft, int chatId) async {
  final ctx = f.tester.element(find.byType(CircleChatScreen));
  MediaJob? job;
  var done = false;
  unawaited(confirmAndQueueMedia(ctx, draft, chatKind: 'member', chatId: chatId).then((j) {
    job = j;
    done = true;
  }));
  await f.pumpFor(const Duration(seconds: 2));
  final send = draft.kind == 'photo' ? const Key('md1-photo-send') : const Key('md1-doc-send');
  await f.tap(find.byKey(send), settleSeconds: 2);
  for (var i = 0; i < 60 && !done; i++) {
    await f.pumpFor(const Duration(milliseconds: 500));
  }
  if (job == null) throw TestFailure('the ${draft.kind} was not queued');
  return job!;
}

/// B downloads + decrypts [ref] with the app's real transport (sha checked).
Future<File> _peerDownload(_Peer p, MediaDescriptor d) async {
  final t = HttpMediaTransport(token: () => p.api.token);
  final u = await t.downloadUrl(d.ref);
  final dir = await Directory.systemTemp.createTemp('ccdl');
  final enc = File('${dir.path}/${d.ref}.enc');
  final sink = enc.openWrite();
  try {
    await t.download('${u['url']}', sink);
  } finally {
    await sink.close();
  }
  final out = File('${dir.path}/${d.ref}.${d.ext}');
  final ok = await openFile(enc.path, out.path, d.key, d.nonce, d.sha256);
  if (!ok) throw TestFailure('${d.kind}: sha256 / decrypt failed on ${p.name}');
  return out;
}

/// [p]'s newest 1:1 media message from A of [kind] -> its descriptor.
Future<MediaDescriptor?> _mediaFromA(_Peer p, String kind, {String? name}) async {
  for (final (pt, m) in (await _fromA(p)).reversed) {
    if ('${m['content_type']}' != kind) continue;
    final d = MediaDescriptor.tryParse(pt);
    if (d != null && (name == null || d.name == name)) return d;
  }
  return null;
}

/// B's "phone" sends A a media file with the app's own MediaOutbox code.
Future<MediaJob> _peerSendMedia(RFlow f, _Peer p, MediaOutbox out, String kind, String path,
    {required String name, required String mime, int? w, int? h, int? ms, String thumb = ''}) async {
  final edge = await f.net(() => _edgeTo(p.api, 'Rahim'));
  final job = MediaJob(
      id: 'cc-${p.name}-$kind-${DateTime.now().microsecondsSinceEpoch}',
      chatKind: 'member',
      chatId: (edge['id'] as num).toInt(),
      kind: kind,
      srcPath: path,
      name: name,
      mime: mime,
      plainSize: File(path).lengthSync(),
      at: DateTime.now(),
      width: w,
      height: h,
      durationMs: ms,
      thumbB64: thumb);
  await f.net(() => out.add(job));
  await f.eventually('${p.name}\'s phone sent the $kind', () async => (await out.all()).isEmpty,
      seconds: 180);
  // the sender's copy is "adopted" into the (shared, in-process) media cache —
  // on a real second phone it lives on THAT phone: remove it from A's cache.
  final root = MediaDirs.rootSync;
  if (root != null) {
    for (final e in Directory('$root/files').listSync()) {
      if (e.path.split('/').last.startsWith(job.ref)) {
        try {
          e.deleteSync();
        } catch (_) {}
      }
    }
  }
  return job;
}

/// Type into the chat input found by its hint (works when it already holds
/// text, e.g. while editing, where the hint itself is not shown).
Future<void> _type(RFlow f, String hint, String text) async {
  final field = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint);
  await f.waitFor(field, what: 'chat input "$hint"');
  await f.tester.tap(field.first, warnIfMissed: false);
  await f.tester.pump();
  await f.tester.enterText(field.first, text);
  await f.tester.pump(const Duration(milliseconds: 400));
}

void registerCircleChatFlows() {
  // ------------------------------------------------------------------ cc1
  realityFlow('cc1_offline_once', 'My Circle chat',
      'Offline: written with the clock -> network back -> delivered EXACTLY once -> ✓ ✓✓ blue ✓✓',
      (f) async {
    await _setup(f);
    final b = _ctx.b!;
    final text = 'Offline once $_tag';
    await f.step('open the chat with B; airplane mode ON', () async {
      await _openChatWith(f, Seed.nameB);
      await _airplane(f, true);
    });
    await f.step('offline: write -> clock (queued on the phone)', () async {
      await _type(f, f.t.circleMessageHint, text);
      await f.tapSend(settleSeconds: 6);
      await f.waitFor(find.byKey(const ValueKey('tick-pending')), seconds: 10, what: 'clock icon');
      final q = await f.net(() => Outbox.instance.all());
      if (!q.any((i) => i.text == text)) throw TestFailure('not queued: ${q.map((i) => i.text)}');
      await f.shot('offline-clock');
    });
    await f.step('network back -> ✓ sent; B gets it exactly ONCE', () async {
      await _airplane(f, false);
      await f.eventually('the outbox is empty', () async => (await Outbox.instance.all()).isEmpty,
          seconds: 90);
      await f.eventually('B decrypts it', () async {
        final got = (await _fromA(b)).where((x) => x.$1 == text).length;
        if (got > 1) throw TestFailure('delivered $got times');
        return got == 1;
      }, seconds: 60);
      await f.pumpFor(const Duration(seconds: 10)); // a late duplicate flush would land now
      final n = await f.net(() async => (await _fromA(b)).where((x) => x.$1 == text).length);
      if (n != 1) throw TestFailure('B has $n copies (want exactly 1)');
      if (_sees(text).evaluate().length != 1) {
        throw TestFailure('A shows ${_sees(text).evaluate().length} bubbles for one message');
      }
      await f.waitFor(find.byKey(const ValueKey('tick-sent')), seconds: 25, what: '✓ sent');
      await f.shot('online-sent');
    });
    await f.step('B\'s phone syncs -> ✓✓; B opens -> blue ✓✓', () async {
      final edgeB = await f.net(() => _edgeTo(b.api, 'Rahim'));
      await f.net(() => b.api.postJson('/circle/receipts/sync'));
      await f.waitFor(find.byKey(const ValueKey('tick-delivered')), seconds: 30, what: '✓✓ delivered');
      await f.net(() => b.api.postJson('/circle/${edgeB['id']}/seen'));
      await f.waitFor(find.byKey(const ValueKey('tick-read')), seconds: 30, what: 'blue ✓✓ read');
      await f.shot('ticks-read');
    });
  }, timeout: const Duration(minutes: 7));

  // ------------------------------------------------------------------ cc2
  realityFlow('cc2_media_both_ways', 'My Circle chat',
      '5 MB photo + 20 MB video both ways: progress, real network cut mid-transfer, resume (no restart), thumbnails, decrypt on the other side',
      (f) async {
    await _setup(f);
    final b = _ctx.b!;
    final slow = _Slow(1500 * 1024);
    final upBefore = MediaOutbox.instance.transport;
    final dlBefore = MediaCache.instance.transport;
    MediaOutbox.instance.transport = HttpMediaTransport(client: slow);
    MediaCache.instance.transport = HttpMediaTransport(client: slow);
    try {
      late int edgeAB;
      final photoName = 'cc_photo_$_tag.png';
      final videoName = 'cc_video_$_tag.mp4';
      late Uint8List photo;
      await f.step('A: 5 MB photo -> preview -> Send -> progress -> B decrypts it', () async {
        edgeAB = ((await f.net(() => _edgeTo(_apiA(f), 'Karim')))['id'] as num).toInt();
        await _openChatWith(f, Seed.nameB);
        photo = _png(1300, 1300, 3);
        final path = await f.net(() => _tmpFile(photoName, photo));
        final thumb = await f.net(() => tinyThumbB64(photo));
        final job = await _queueFromUi(
            f,
            MediaDraft(kind: 'photo', path: path, name: photoName, mime: 'image/png',
                size: photo.length, width: 1300, height: 1300, thumbB64: thumb),
            edgeAB);
        var sawRing = false;
        for (var i = 0; i < 120; i++) {
          if (find.byKey(Key('md1-send-cancel-${job.id}')).evaluate().isNotEmpty) sawRing = true;
          if ((await f.net(() => MediaOutbox.instance.all())).every((j) => j.id != job.id)) break;
          if (i == 3) await f.shot('photo-uploading');
          await f.pumpFor(const Duration(milliseconds: 500));
        }
        if (!sawRing) f.note('photo: upload finished before the progress ring was sampled');
        final d = await f.net(() async {
          MediaDescriptor? x;
          for (var i = 0; i < 20 && x == null; i++) {
            x = await _mediaFromA(b, 'photo', name: photoName);
            if (x == null) await Future<void>.delayed(const Duration(seconds: 2));
          }
          return x;
        });
        if (d == null) throw TestFailure('B never got the photo');
        if (d.thumb == null || d.thumb!.isEmpty) throw TestFailure('photo descriptor has no thumbnail');
        final file = await f.net(() => _peerDownload(b, d));
        final got = await f.net(() => file.readAsBytes());
        if (got.length != photo.length) throw TestFailure('photo size ${got.length} != ${photo.length}');
        f.note('photo A->B: ${(photo.length / 1048576).toStringAsFixed(1)} MB, thumb ${d.thumb!.length} B');
        await f.shot('photo-sent');
      });

      await f.step('A: 20 MB video -> REAL network cut at ~30% -> resumes at the server offset', () async {
        final video = _blob(20, 7);
        final path = await f.net(() => _tmpFile(videoName, video));
        final thumb = await f.net(() => tinyThumbB64(_png(64, 36, 9)));
        slow.putOffsets.clear();
        final job = await _queueFromUi(
            f,
            MediaDraft(kind: 'video', path: path, name: videoName, mime: 'video/mp4',
                size: video.length, width: 1280, height: 720, durationMs: 20000, thumbB64: thumb),
            edgeAB);
        // wait for ~30 % of the upload, then pull the network
        var p = 0.0;
        for (var i = 0; i < 240 && p < 0.3; i++) {
          p = MediaOutbox.instance.progress.value[job.id] ?? p;
          await f.pumpFor(const Duration(milliseconds: 250));
        }
        if (p < 0.3) throw TestFailure('upload progress never reached 30 % (last $p)');
        await f.shot('video-uploading');
        await _airplane(f, true);
        await f.pumpFor(const Duration(seconds: 20));
        await f.shot('video-upload-offline');
        await _airplane(f, false);
        await f.eventually('the video job is sent (the outbox retries by itself)',
            () async => (await MediaOutbox.instance.all()).every((j) => j.id != job.id),
            seconds: 300);
        final offs = slow.putOffsets.where((o) => o >= 0).toList();
        final restarted = [for (var i = 1; i < offs.length; i++) if (offs[i] == 0) i];
        if (restarted.isNotEmpty) throw TestFailure('upload restarted from 0: $offs');
        f.note('video upload PUT offsets (KiB): ${offs.map((o) => o ~/ 1024).toList()}');
        final d = await f.net(() async {
          MediaDescriptor? x;
          for (var i = 0; i < 20 && x == null; i++) {
            x = await _mediaFromA(b, 'video', name: videoName);
            if (x == null) await Future<void>.delayed(const Duration(seconds: 2));
          }
          return x;
        });
        if (d == null) throw TestFailure('B never got the video');
        if (d.thumb == null) throw TestFailure('video descriptor has no thumbnail');
        final file = await f.net(() => _peerDownload(b, d));
        final same = await f.net(() async => (await file.readAsBytes()).length == video.length);
        if (!same) throw TestFailure('B\'s decrypted video has the wrong size');
        await f.shot('video-sent');
      });

      final outB = MediaOutbox(store: _MemJobs(), transport: HttpMediaTransport(token: () => b.api.token));
      outB.identity = () async => b.id;
      await f.step('B -> A: 5 MB photo; A shows the thumbnail, downloads, opens it', () async {
        await f.back();
        final bp = _png(1300, 1300, 11);
        final name = 'cc_bphoto_$_tag.png';
        final path = await f.net(() => _tmpFile(name, bp));
        final thumb = await f.net(() => tinyThumbB64(bp));
        final job = await _peerSendMedia(f, b, outB, 'photo', path,
            name: name, mime: 'image/png', w: 1300, h: 1300, thumb: thumb);
        await _openChatWith(f, Seed.nameB);
        final any = find.byWidgetPredicate((w) =>
            w.key == Key('md1-dl-${job.ref}') ||
            w.key == Key('md1-dl-cancel-${job.ref}') ||
            w.key == Key('md1-photo-${job.ref}'));
        await f.waitFor(any, seconds: 40, what: 'B\'s photo bubble');
        if (find.byType(ImageFiltered).evaluate().isEmpty &&
            find.byKey(Key('md1-photo-${job.ref}')).evaluate().isEmpty) {
          throw TestFailure('no blurred thumbnail before the download');
        }
        await f.shot('bphoto-thumb');
        if (find.byKey(Key('md1-dl-${job.ref}')).evaluate().isNotEmpty) {
          await f.tap(find.byKey(Key('md1-dl-${job.ref}')), settleSeconds: 1);
        }
        await f.waitFor(find.byKey(Key('md1-photo-${job.ref}')), seconds: 90, what: 'photo opened');
        await f.shot('bphoto-open');
      });

      await f.step('B -> A: 20 MB video; REAL cut mid-download; retry resumes with Range (206)', () async {
        final bv = _blob(20, 13);
        final name = 'cc_bvideo_$_tag.mp4';
        final path = await f.net(() => _tmpFile(name, bv));
        final thumb = await f.net(() => tinyThumbB64(_png(64, 36, 15)));
        await f.back();
        final job = await _peerSendMedia(f, b, outB, 'video', path,
            name: name, mime: 'video/mp4', w: 1280, h: 720, ms: 20000, thumb: thumb);
        slow.ranges.clear();
        await _openChatWith(f, Seed.nameB);
        final dl = find.byKey(Key('md1-dl-${job.ref}'));
        if (await f.appears(dl, seconds: 25)) await f.tap(dl, settleSeconds: 1);
        var p = 0.0;
        for (var i = 0; i < 240 && p < 0.3; i++) {
          p = MediaCache.instance.states.value[job.ref]?.progress ?? p;
          await f.pumpFor(const Duration(milliseconds: 250));
        }
        if (p < 0.3) throw TestFailure('download progress never reached 30 % (last $p)');
        await f.shot('bvideo-downloading');
        await _airplane(f, true);
        // long enough for the stalled stream to time out and the automatic
        // resume attempts to give up -> the honest "network" retry button
        await f.pumpFor(const Duration(seconds: 75));
        await f.shot('bvideo-cut');
        await _airplane(f, false);
        final retry = find.byKey(Key('md1-dl-${job.ref}'));
        if (await f.appears(retry, seconds: 10)) await f.tap(retry, settleSeconds: 1);
        await f.eventually('the video is downloaded + decrypted on A', () async {
          final root = MediaDirs.rootSync;
          if (root == null) return false;
          return File('$root/files/${job.ref}.mp4').existsSync() &&
              MediaCache.instance.states.value[job.ref] == null;
        }, seconds: 240);
        final resumed = slow.ranges.where((r) => r.$1 > 0 && r.$2 == 206).toList();
        f.note('download calls (from, status): ${slow.ranges}');
        if (resumed.isEmpty) throw TestFailure('no resumed (Range, 206) download: ${slow.ranges}');
        final size = File('${MediaDirs.rootSync}/files/${job.ref}.mp4').lengthSync();
        if (size != bv.length) throw TestFailure('A\'s video is $size bytes, want ${bv.length}');
        await f.shot('bvideo-done');
      });
    } finally {
      MediaOutbox.instance.transport = upBefore;
      MediaCache.instance.transport = dlBefore;
    }
    f.note('video bytes are synthetic (no real mp4 is played); the app\'s 720p '
        'compression step after the gallery picker is not part of this run');
  }, timeout: const Duration(minutes: 18));

  // ------------------------------------------------------------------ cc3
  realityFlow('cc3_voice_note', 'My Circle chat',
      'Voice note: recorded on A (emulator mic) -> B decrypts a real m4a; B\'s voice note plays on A',
      (f) async {
    await _setup(f);
    final b = _ctx.b!;
    late MediaDescriptor got;
    await f.step('A records 3 s and sends', () async {
      await _openChatWith(f, Seed.nameB);
      await f.tap(find.byKey(const Key('wa2-mic')), settleSeconds: 1);
      await f.waitFor(find.byKey(const Key('md1-rec-time')), seconds: 10, what: 'recorder running');
      await f.pumpFor(const Duration(seconds: 3));
      await f.shot('recording');
      await f.tap(find.byKey(const Key('md1-rec-send')), settleSeconds: 2);
      await f.eventually('the voice job is sent',
          () async => (await MediaOutbox.instance.all()).every((j) => j.kind != 'voice'),
          seconds: 90);
      final d = await f.net(() async {
        MediaDescriptor? x;
        for (var i = 0; i < 20 && x == null; i++) {
          x = await _mediaFromA(b, 'voice');
          if (x == null) await Future<void>.delayed(const Duration(seconds: 2));
        }
        return x;
      });
      if (d == null) throw TestFailure('B never got the voice note');
      got = d;
      final file = await f.net(() => _peerDownload(b, d));
      final bytes = await f.net(() => file.readAsBytes());
      if (bytes.length < 1000) throw TestFailure('voice note is only ${bytes.length} bytes');
      final ftyp = String.fromCharCodes(bytes.sublist(4, 8));
      f.note('A\'s voice note: ${bytes.length} B, ${d.durationMs} ms, container "$ftyp"');
      await f.shot('voice-sent');
    });
    await f.step('B sends a voice note back -> A taps play -> it plays', () async {
      final mine = await f.net(() => _peerDownload(b, got));
      final path = await f.net(() async {
        final p = '${mine.path}.b.m4a';
        await mine.copy(p);
        return p;
      });
      await f.back();
      final outB = MediaOutbox(store: _MemJobs(), transport: HttpMediaTransport(token: () => b.api.token));
      outB.identity = () async => b.id;
      final job = await _peerSendMedia(f, b, outB, 'voice', path,
          name: 'voice_$_tag.m4a', mime: 'audio/mp4', ms: got.durationMs ?? 3000);
      await _openChatWith(f, Seed.nameB);
      await f.pumpFor(const Duration(seconds: 8)); // the bubble + auto download
      await f.waitFor(find.byKey(const Key('md1-voice-play')), seconds: 30, what: 'voice bubble');
      await f.tap(find.byKey(const Key('md1-voice-play')).last, settleSeconds: 1);
      var played = false;
      for (var i = 0; i < 40 && !played; i++) {
        final s = VoicePlayer.instance.state.value;
        played = s.playing || s.positionMs > 0;
        await f.pumpFor(const Duration(milliseconds: 500));
      }
      if (!played) throw TestFailure('B\'s voice note did not play on A (ref ${job.ref})');
      await f.shot('voice-playing');
    });
    f.note('the CI emulator mic records silence/host noise; audio quality and the '
        'earpiece/speaker route need a real phone');
  }, timeout: const Duration(minutes: 8));

  // ------------------------------------------------------------------ cc4
  realityFlow('cc4_group_of_four', 'My Circle chat',
      'Group of 4: everyone decrypts; D removed -> 404 + no copy for D (stale roster dropped); D added back -> reads new only',
      (f) async {
    await _setup(f);
    final b = _ctx.b!, c = _ctx.c!, d = _ctx.d!;
    final name = 'Four $_tag';
    late int gid;
    late Map<String, int> edge; // A's edge id per peer
    await f.step('A makes a group with B, C, D', () async {
      await f.net(() async {
        final a = _apiA(f);
        final g = await a.postJson('/circle/groups', {'name': name});
        gid = (g['id'] as num).toInt();
        edge = {};
        for (final p in [b, c, d]) {
          final e = await _edgeTo(a, p.name);
          edge[p.name] = (e['id'] as num).toInt();
          await a.postJson('/circle/groups/$gid/members', {'member_id': e['id']});
        }
      });
      _ctx.gid = gid;
      await _openGroup(f, name);
    });
    final t1 = 'Hello four $_tag';
    await f.step('A sends -> B, C and D each decrypt their own copy', () async {
      await _type(f, f.t.circleGroupMessageHint, t1);
      await f.tapSend(settleSeconds: 4);
      for (final p in [b, c, d]) {
        await f.eventually('${p.name} decrypts', () async =>
            (await _groupFromA(p, gid)).any((x) => x.$1 == t1), seconds: 40);
      }
      await f.shot('group-four');
    });
    late int gmD;
    final t2 = 'After D left $_tag';
    await f.step('A removes D -> D gets 404; A\'s next message has no copy for D', () async {
      await f.net(() async {
        final a = _apiA(f);
        final roster = _rows(await a.getJson('/circle/groups/$gid/members'));
        gmD = (roster.firstWhere((m) => '${m['name']}'.contains(d.name))['member_id'] as num).toInt();
        await a.postJson('/circle/groups/$gid/members/$gmD/remove');
      });
      await f.pumpFor(const Duration(seconds: 2));
      await _type(f, f.t.circleGroupMessageHint, t2);
      await f.tapSend(settleSeconds: 4);
      for (final p in [b, c]) {
        await f.eventually('${p.name} decrypts', () async =>
            (await _groupFromA(p, gid)).any((x) => x.$1 == t2), seconds: 40);
      }
      final blocked = await f.net(() async {
        try {
          await d.api.getJson('/circle/groups/$gid/messages');
          return false;
        } on ApiException catch (e) {
          return e.status == 404 || e.status == 403;
        }
      });
      if (!blocked) throw TestFailure('removed D can still read the group');
      final leak = await f.net(() async {
        final rows = await _groupFromA(b, gid);
        final m = rows.firstWhere((x) => x.$1 == t2).$2;
        final pr = m['per_recipient'];
        return pr is Map && pr.containsKey('$gmD');
      });
      if (leak) throw TestFailure('A\'s phone still sealed a copy for removed D');
      await f.shot('group-after-remove');
    });
    final t3 = 'Stale roster $_tag';
    await f.step('a STALE queued envelope still sealed for D -> the server drops D\'s copy', () async {
      final ok = await f.net(() async {
        final a = _apiA(f);
        final me = await loadStoredIdentity();
        if (me == null) return 'no identity';
        final roster = _rows(await a.getJson('/circle/groups/$gid/members'));
        final per = <String, dynamic>{};
        final ids = <int>[];
        for (final p in [b, c, d]) {
          final row = roster.where((m) => '${m['name']}'.contains(p.name)).firstOrNull;
          final id = row == null ? gmD : (row['member_id'] as num).toInt();
          final ct = _e2e.encrypt(self: me, recipientPublicKey: p.id.publicKey, plaintext: t3);
          per['$id'] = {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64};
          ids.add(id);
        }
        await Outbox.instance.add(OutboxItem(
            id: 'cc4-stale-$_tag',
            chatId: gid,
            chatKind: 'group',
            text: t3,
            at: DateTime.now(),
            envelope: {
              'recipient_ids': ids,
              'per_recipient': per,
              'sender_key_id': me.keyId,
              'scheme': _e2e.scheme,
              'client_msg_id': 'cc4-stale-$_tag',
            }));
        final r = await Outbox.instance.flush(
            transport: FnOutboxTransport(get: a.getJson, post: (p, bd) => a.postJson(p, bd)),
            identity: loadStoredIdentity,
            onlyGroup: gid);
        return r.sent.contains('cc4-stale-$_tag') ? 'ok' : 'not sent (${r.waiting} waiting)';
      });
      if (ok != 'ok') throw TestFailure('stale envelope: $ok');
      await f.eventually('B and C read it; the stored row has no copy for D', () async {
        final rows = await _groupFromA(c, gid);
        final hit = rows.where((x) => x.$1 == t3).toList();
        if (hit.isEmpty) return false;
        final pr = hit.first.$2['per_recipient'];
        if (pr is Map && pr.containsKey('$gmD')) throw TestFailure('server kept D\'s stale copy');
        return (await _groupFromA(b, gid)).any((x) => x.$1 == t3);
      }, seconds: 30);
    });
    final t4 = 'Welcome back D $_tag';
    await f.step('D added back (same membership row) -> reads ONLY what came after', () async {
      await f.net(() => _apiA(f).postJson('/circle/groups/$gid/members', {'member_id': edge[d.name]}));
      await f.pumpFor(const Duration(seconds: 3));
      await _type(f, f.t.circleGroupMessageHint, t4);
      await f.tapSend(settleSeconds: 4);
      await f.eventually('D decrypts the new message', () async =>
          (await _groupFromA(d, gid)).any((x) => x.$1 == t4), seconds: 40);
      final seen = await f.net(() async => (await _groupFromA(d, gid)).map((x) => x.$1).toSet());
      for (final hidden in [t2, t3]) {
        if (seen.contains(hidden)) throw TestFailure('re-added D can read "$hidden" (sent while removed)');
      }
      await f.shot('group-d-back');
    });
    f.note('add/remove ran through the real API (the same calls the group info screen makes); '
        'the per-member sealing has no shared group key, so "rotation" = the next message is '
        'sealed only to current members');
  }, timeout: const Duration(minutes: 7));

  // ------------------------------------------------------------------ cc5
  realityFlow('cc5_reply_edit_delete_forward', 'My Circle chat',
      'Long-press menu: reply (quote link), edit (B sees the new text + edited), delete for everyone (B sees it gone), forward to the group',
      (f) async {
    await _setup(f);
    final b = _ctx.b!;
    final q = 'Question from B $_tag';
    late int qid;
    Future<void> longPress(String text) async {
      final t = _sees(text).last;
      await f.waitFor(t, seconds: 30, what: '"$text"');
      await f.tester.longPress(t, warnIfMissed: false);
      await f.pumpFor(const Duration(milliseconds: 1500));
    }

    Future<void> menu(String label) async {
      final m = find.text(label).last;
      await f.tester.ensureVisible(m);
      await f.pumpFor(const Duration(milliseconds: 400));
      await f.tap(m, settleSeconds: 1.5);
    }

    await f.step('B asks; A replies from the long-press menu (quote kept)', () async {
      qid = await f.net(() => _sendToA(b, q));
      await _openChatWith(f, Seed.nameB);
      await longPress(q);
      await menu(f.t.circleActionReply);
      await _type(f, f.t.circleMessageHint, 'Answer $_tag');
      await f.tapSend(settleSeconds: 3);
      await f.eventually('B sees the reply linked to its question', () async {
        final r = (await _fromA(b)).where((x) => x.$1 == 'Answer $_tag').toList();
        return r.isNotEmpty && '${r.last.$2['reply_to']}' == '$qid';
      }, seconds: 40);
      await f.shot('reply');
    });
    await f.step('A edits it -> B decrypts the NEW text, marked edited', () async {
      await longPress('Answer $_tag');
      await menu(f.t.circleActionEdit);
      await _type(f, f.t.circleMessageHint, 'Answer edited $_tag');
      await f.tapSend(settleSeconds: 3);
      await f.eventually('B: new text + edited_at', () async {
        final r = (await _fromA(b)).where((x) => x.$1 == 'Answer edited $_tag').toList();
        return r.isNotEmpty && r.last.$2['edited_at'] != null;
      }, seconds: 40);
      await f.shot('edited');
    });
    await f.step('A deletes it for everyone -> B has a tombstone, no ciphertext', () async {
      await longPress('Answer edited $_tag');
      await menu(f.t.circleActionDeleteEveryone);
      await f.tap(find.text(f.t.delete).last, settleSeconds: 3);
      await f.eventually('B: deleted=everyone, ciphertext gone', () async {
        final rows = await _fromA(b);
        if (rows.any((x) => x.$1 == 'Answer edited $_tag')) return false;
        return rows.any((x) => '${x.$2['deleted']}' == 'everyone');
      }, seconds: 40);
      await f.shot('deleted-everyone');
    });
    await f.step('A forwards B\'s question to the group -> C decrypts it, marked forwarded', () async {
      final gid = _ctx.gid;
      if (gid == null) {
        f.note('forward skipped: the group of four (cc4) did not run');
        return;
      }
      await longPress(q);
      await menu(f.t.circleActionForward);
      await f.tap(find.byKey(Key('md2-fwd-group-$gid')), settleSeconds: 3);
      await f.eventually('C decrypts the forward in the group', () async {
        final r = (await _groupFromA(_ctx.c!, gid)).where((x) => x.$1 == q).toList();
        return r.isNotEmpty && r.last.$2['forwarded'] == true;
      }, seconds: 40);
      await f.shot('forwarded');
    });
  }, timeout: const Duration(minutes: 7));

  // ------------------------------------------------------------------ cc6
  realityFlow('cc6_reinstall_restore', 'My Circle chat',
      'Reinstall: Security-PIN key backup -> NEW sandbox + NEW device session -> restore screen -> old history decrypts with the same key',
      (f) async {
    await _setup(f);
    final b = _ctx.b!;
    const pin = '4826';
    final olds = <String>[for (var i = 0; i < 5; i++) 'Before reinstall $i $_tag'];
    late IdentityKeyPair before;
    await f.step('A has history from B and a key backup under a PIN', () async {
      for (final t in olds) {
        await f.net(() => _sendToA(b, t));
      }
      await _openChatWith(f, Seed.nameB);
      await f.waitFor(_sees(olds.last), seconds: 30, what: 'history on A');
      final ok = await f.net(() async {
        before = (await IdentityVault.instance.peek())!;
        return KeyBackupService.instance.backupWithPin(pin);
      });
      if (ok != true) throw TestFailure('key backup with PIN failed');
      await f.back();
    });
    await f.step('"reinstall": empty sandbox, signed in again as a new device -> restore screen', () async {
      final dir = await f.net(() => Directory.systemTemp.createTemp('cc_fresh'));
      final store = SecretStore(dir: () async => dir, legacy: const _NoLegacy());
      final vault = IdentityVault(store: store);
      final fresh = await f.net(() => _login(Seed.phoneA, 'cc-reinstall-$_tag'));
      final svc = KeyBackupService(vault: vault, store: store);
      svc.get = (p) => fresh.getJson(p);
      svc.post = (p, bd) async {
        final r = await fresh.postJsonRaw(p, bd);
        final st = (r['_status'] as num?)?.toInt() ?? 0;
        if (st >= 200 && st < 300) return r;
        throw BackupHttpError(st, r);
      };
      final noKey = await f.net(() => vault.peek());
      if (noKey != null) throw TestFailure('the fresh sandbox already has a key');
      final meta = await f.net(() => svc.meta());
      if (meta == null || meta['exists'] != true) throw TestFailure('no backup visible after reinstall');
      await f.pushScreen(E2RestoreScreen(service: svc, meta: meta));
      await f.shot('restore-screen');
      await f.tester.enterText(find.byKey(const Key('e2r-pin')), pin);
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.tap(find.byKey(const Key('e2r-restore')), settleSeconds: 2);
      await f.eventually('restored (the screen closes)',
          () async => find.byType(E2RestoreScreen).evaluate().isEmpty, seconds: 60);
      final after = await f.net(() => vault.get());
      if (after.keyId != before.keyId) {
        throw TestFailure('restored key ${after.keyId} != old key ${before.keyId}');
      }
      // the new install reads the OLD history from the server with it
      final n = await f.net(() async {
        final edge = await _edgeTo(fresh, 'Karim');
        final peer = base64Decode('${edge['public_key']}');
        final rows = _rows(await fresh.getJson('/circle/${edge['id']}/messages?limit=200'))
            .where((m) => m['mine'] != true);
        var ok = 0;
        for (final m in rows) {
          try {
            final pt = _e2e.decrypt(
                self: after,
                senderPublicKey: peer,
                ct: Ciphertext(
                    ciphertextB64: '${m['ciphertext']}',
                    nonceB64: '${m['nonce']}',
                    senderKeyId: '${m['sender_key_id'] ?? ''}',
                    scheme: '${m['scheme'] ?? _e2e.scheme}'));
            if (olds.contains(pt)) ok++;
          } catch (_) {}
        }
        return ok;
      });
      if (n != olds.length) throw TestFailure('only $n of ${olds.length} old messages decrypt after restore');
      f.note('restored key ${after.keyId}; $n/${olds.length} old messages decrypt on the new install');
      await f.shot('restored');
    });
    f.note('a real uninstall cannot run inside the test process: the reinstall is an EMPTY '
        'secret sandbox + a NEW device sign-in (what a reinstall leaves); the chat screen of a '
        'cold-started new install is the owner two-phone check');
  }, timeout: const Duration(minutes: 6));
}
