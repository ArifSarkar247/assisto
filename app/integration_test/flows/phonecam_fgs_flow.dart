// guardbox-play — "old phone = CCTV camera" END TO END on the emulator with
// the camera FOREGROUND SERVICE (owner standing order 18 Nov: nothing hidden
// from Play — the screen-off watch ships in the Play build too).
//
// Runs ONLY in .github/workflows/guardbox-fgs.yml (REALITY_ONLY=start,pcfgs)
// on an API-33 emulator with an EMULATED back camera (-camera-back emulated,
// like the release gate's circle leg) against the throw-away Django
// (settings_e2eproof + seed_camflows: A's place "Camflows Shop", owner-away
// = armed). A sidecar (tools/e2e/pcfgs_sidecar.sh) does what only the shell
// can: power key (screen off / on), dumpsys of the services + notification,
// and tapping Stop IN THE NOTIFICATION. It answers each request with an ack
// file in the app's files dir.
//
// Through the UI a shop owner uses, on ONE phone (the camera phone) with the
// family member B as the SECOND ACCOUNT (a viewer of A's place):
//   pair with the code -> Start -> the camera service runs (foreground,
//   notification) -> motion -> B gets the alert push + the photo
//   -> B opens LIVE VIEW (a real WebRTC peer: video bytes arrive) -> live ends
//   -> the camera watches again WITHOUT asking anything (bug fix: the
//      permission reason popped up after every live view)
//   -> SCREEN OFF (power key): the service holds the camera, frames flow,
//      a second motion alert with a photo reaches B
//   -> screen on -> Stop in the NOTIFICATION -> the run ends on screen, the
//      service is gone (dumpsys) -> Start again + the on-screen Stop works.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/phonecam/phone_camera_screen.dart';
import 'package:assisto/screens/shop_live_rtc.dart';
import 'package:assisto/shop_api.dart';

import '../support/harness.dart';

const _apiBase = String.fromEnvironment('REALITY_API_BASE', defaultValue: 'http://10.0.2.2:8700');
const _siteName = 'Camflows Shop';
const _ch = MethodChannel('com.assisto/shopbox');

Finder _k(String k) => find.byKey(ValueKey(k));

List<Map<String, dynamic>> _list(dynamic v) =>
    ((v ?? const []) as List).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      return false;
    });

/// The camera service as Android lists it.
Future<Map<String, dynamic>> _svc() async =>
    ((await _ch.invokeMapMethod<String, dynamic>('camSvcState')) ?? const {}).cast<String, dynamic>();

int _seq = 0;

/// Ask the sidecar (shell) to do [cmd]; waits for its ack file. NEVER pumps
/// (the screen may be off: no frames).
Future<String> _sidecar(RFlow f, String cmd, {int seconds = 60}) async {
  final tag = '${cmd.toLowerCase()}${++_seq}';
  final got = await f.net<String?>(() async {
    final dir = (await getApplicationSupportDirectory()).path;
    final ack = File('$dir/pcfgs_ack_$tag');
    // ignore: avoid_print
    print('PCFGS:$cmd:$tag');
    final end = DateTime.now().add(Duration(seconds: seconds));
    var again = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(end)) {
      if (await ack.exists()) return (await ack.readAsString()).trim();
      if (DateTime.now().isAfter(again)) {
        // ignore: avoid_print
        print('PCFGS:$cmd:$tag'); // a logcat line can be lost: ask again
        again = DateTime.now().add(const Duration(seconds: 15));
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return null;
  });
  if (got == null) throw TestFailure('sidecar never answered $cmd ($tag)');
  return got;
}

/// Poll with real time only (no pump: safe while the screen is off).
Future<void> _waitNet(RFlow f, String what, Future<bool> Function() probe, {int seconds = 60}) async {
  final ok = await f.net(() async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      try {
        if (await probe()) return true;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
    return false;
  });
  if (ok != true) throw TestFailure('timed out after ${seconds}s: $what');
}

/// The running view hides its status after 15 s: a tap shows it again.
Future<void> _reveal(RFlow f) async {
  if (_k('pcStop').evaluate().isNotEmpty || _k('pcRecordingBanner').evaluate().isEmpty) return;
  final sc = find.byType(Scaffold).hitTestable();
  if (sc.evaluate().isEmpty) return;
  await f.tester.tapAt(f.tester.getCenter(sc.last));
  await f.pumpFor(const Duration(milliseconds: 800));
}

/// Wait for a status line on the running view (revealing it as needed).
Future<void> _status(RFlow f, String text, {double seconds = 30}) async {
  final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await _reveal(f);
    if (_sees(text).evaluate().isNotEmpty) return;
    await f.tester.pump(const Duration(milliseconds: 500));
  }
  throw TestFailure('timed out after ${seconds}s waiting for "$text"');
}

Future<List<Map<String, dynamic>>> _snapEvents(ApiClient api, int site, int cam) async {
  final d = await api.getJson('/shop/events?site=$site&camera=$cam');
  return _list(d['events']).where((e) => '${e['snapshot_url'] ?? ''}'.isNotEmpty).toList();
}

/// The alert photo, fetched as the viewer B (signed link, our runner host).
Future<Uint8List> _photo(String url, String token) async {
  final u = Uri.parse(url);
  final local = Uri.parse(_apiBase).replace(path: u.path, query: u.query.isEmpty ? null : u.query);
  final hc = HttpClient();
  try {
    final req = await hc.getUrl(local);
    req.headers.set('Authorization', 'Token $token');
    final res = await req.close();
    final b = await res.fold<BytesBuilder>(BytesBuilder(), (bb, c) => bb..add(c));
    if (res.statusCode != 200) throw TestFailure('photo ${res.statusCode} for ${local.path}');
    return b.takeBytes();
  } finally {
    hc.close(force: true);
  }
}

Future<void> _save(String name, List<int> bytes) async {
  final out = await Harness.I.outDir();
  await File('${out.path}/$name').writeAsBytes(bytes, flush: true);
}

Future<void> _flow(RFlow f) async {
  await f.home();
  final a = await f.h.backend();
  final b = await f.h.backend(userB: true);
  late int site, bId, camId;
  late String code;
  final shots = <int>[];

  await f.step('A\'s place + B is a viewer (the second account) + a pairing code', () async {
    final s = await f.net(() => a.shopSites());
    final row = _list(s['sites']).where((x) => x['name'] == _siteName).toList();
    if (row.isEmpty) throw TestFailure('seed_camflows made no "$_siteName"');
    site = (row.first['id'] as num).toInt();
    final v = await f.net(() => a.postJson('/shop/sites/$site/viewers',
        {'phone': Seed.phoneB, 'live_ok': true}));
    bId = (v['user_id'] as num).toInt();
    final p = await f.net(() => a.getJson('/shop/phonecam/pair?site=$site'));
    code = '${p['code']}';
    if (code.isEmpty || code == 'null') throw TestFailure('no pairing code: $p');
  });

  await f.step('THIS phone: pair with the code', () async {
    PhoneCameraScreen.debugNoPersonModel = true; // the fake camera shows no person
    await f.pushScreen(PhoneCameraScreen(initialCode: code), settleSeconds: 3);
    await f.tap(_k('pcClaim'), settleSeconds: 4);
    await f.waitFor(_k('pcStart'), seconds: 25, what: 'paired: the Start button');
    await f.shot('paired');
    final cams = await f.net(() => a.shopCameras(site));
    final phone = _list(cams['cameras']).where((c) => c['vendor'] == 'phone').toList();
    if (phone.isEmpty) throw TestFailure('no phone camera on the server: ${cams['cameras']}');
    camId = (phone.last['id'] as num).toInt();
  });

  await f.step('Start -> watching + the camera foreground service with its notification', () async {
    await f.tap(_k('pcStart'), settleSeconds: 3);
    if (await f.appears(_k('perm-reason-camera'), seconds: 3)) {
      f.note('camera reason shown once (first ask)');
      await f.tap(_k('perm-reason-yes'), settleSeconds: 3);
    }
    await f.waitFor(_k('pcRecordingBanner'), seconds: 20, what: 'the recording banner');
    await _status(f, f.t.pcWatching, seconds: 30);
    await f.eventually('the camera service runs in the foreground', () async {
      final s = await _svc();
      return s['running'] == true && s['foreground'] == true;
    }, seconds: 20);
    await _reveal(f);
    await f.waitFor(_k('pcSvcOn'), seconds: 10, what: 'the "keeps watching with the screen off" line');
    final r = await _sidecar(f, 'DUMP');
    f.note('dump started: $r');
    await f.shot('running');
  });

  final t0 = ((await f.net(() => a.getJson('/ci-e2e/outbox?kind=none')))['now'] as num).toDouble();
  await f.step('motion -> alert with a photo -> B (second account) gets the push + the photo', () async {
    await f.eventually('an alert with a photo from the phone camera', () async {
      final ev = await _snapEvents(b, site, camId);
      if (ev.isEmpty) return false;
      shots.add((ev.first['id'] as num).toInt());
      return true;
    }, seconds: 150);
    await f.eventually('the push to B', () async {
      final o = await a.getJson('/ci-e2e/outbox?kind=push&user=$bId&since=$t0');
      return _list(o['rows']).isNotEmpty;
    }, seconds: 30);
    final ev = (await f.net(() => _snapEvents(b, site, camId))).first;
    final jpg = await f.net(() => _photo('${ev['snapshot_url']}', b.token ?? ''));
    if (jpg.length < 1000 || jpg[0] != 0xFF || jpg[1] != 0xD8) {
      throw TestFailure('the alert photo is not a JPEG (${jpg.length} bytes)');
    }
    await f.net(() => _save('pcfgs_alert1.jpg', jpg));
    f.note('alert 1: ${ev['type']} photo ${jpg.length} B');
  });

  await f.step('B opens live view -> real video arrives -> live ends', () async {
    final st = await f.net(() => b.shopLiveStart(camId));
    final sid = (st['id'] as num).toInt();
    final ice = _list(st['ice']?['ice_servers']);
    var gotVideo = false;
    final peer = await f.net(() => LivePeer.create(ice,
        sender: false,
        relayHold: Duration.zero,
        onCandidate: (c) => b.shopLiveSignal(sid, 'candidate', c),
        onRemoteVideo: () => gotVideo = true));
    try {
      final offer = await f.net(() => peer.createOffer());
      await f.net(() => b.shopLiveSignal(sid, 'offer', offer));
      var after = 0;
      var answered = false;
      var bytes = 0;
      await f.eventually('the camera phone answers and video bytes arrive', () async {
        final r = await b.shopLivePoll(sid, after);
        after = (r['seq'] as num?)?.toInt() ?? after;
        for (final m in _list(r['messages'])) {
          final p = m['payload'];
          if (m['kind'] == 'answer' && p is Map && !answered) {
            await peer.setRemote(p.cast<String, dynamic>());
            answered = true;
          } else if (m['kind'] == 'candidate' && p is Map) {
            try {
              await peer.addCandidate(p.cast<String, dynamic>());
            } catch (_) {}
          }
        }
        if (!answered) return false;
        bytes = (await peer.pathInfo())['bytes'] as int;
        return gotVideo && bytes > 20000;
      }, seconds: 60);
      f.note('live: $bytes bytes, video track ${gotVideo ? 'yes' : 'no'}');
      await _status(f, f.t.pcLiveNow, seconds: 10);
      await f.shot('live-on-camera-phone');
    } finally {
      await f.net(() => b.shopLiveSignal(sid, 'bye', const {}).catchError((_) => <String, dynamic>{}));
      await f.net(() => b.shopLiveEnd(sid, relayed: false, seconds: 10).catchError((_) => <String, dynamic>{}));
      await f.net(() => peer.dispose());
    }
  });

  await f.step('after live: watching again by itself, no question asked (bug fix)', () async {
    await _status(f, f.t.pcWatching, seconds: 40);
    if (_k('perm-reason-camera').evaluate().isNotEmpty) {
      throw TestFailure('the camera reason dialog came back after live view (camera stopped)');
    }
    await f.shot('watching-again');
  });

  await f.step('SCREEN OFF: the service holds the camera, frames flow, a 2nd alert with a photo reaches B', () async {
    final before = await f.net(() => _snapEvents(b, site, camId));
    final t1 = ((await f.net(() => a.getJson('/ci-e2e/outbox?kind=none')))['now'] as num).toDouble();
    f.note('screen off: ${await _sidecar(f, 'SLEEP')}');
    var n0 = -1;
    await _waitNet(f, 'the service opened the camera (screen off)', () async {
      final s = await _svc();
      return s['camera_open'] == true && s['foreground'] == true;
    }, seconds: 40);
    await _waitNet(f, 'frames keep coming from the service camera', () async {
      final fr = await _ch.invokeMapMethod<String, dynamic>('bgFrame');
      final n = (fr?['n'] as num?)?.toInt() ?? -1;
      if (n0 < 0) {
        n0 = n;
        return false;
      }
      return n > n0 + 5;
    }, seconds: 30);
    final j = await f.net(() => _ch.invokeMethod<Uint8List>('bgJpeg', {'quality': 80}));
    if (j != null) await f.net(() => _save('pcfgs_screenoff_frame.jpg', j));
    f.note('dump screen off: ${await _sidecar(f, 'DUMP')}');
    // a motion-only alert waits 3 min after the previous one (cooldown)
    await _waitNet(f, 'a NEW alert with a photo while the screen is off', () async {
      final ev = await _snapEvents(b, site, camId);
      return ev.length > before.length;
    }, seconds: 300);
    await _waitNet(f, 'the push to B (screen off)', () async {
      final o = await a.getJson('/ci-e2e/outbox?kind=push&user=$bId&since=$t1');
      return _list(o['rows']).isNotEmpty;
    }, seconds: 30);
    final ev = (await f.net(() => _snapEvents(b, site, camId))).first;
    final jpg = await f.net(() => _photo('${ev['snapshot_url']}', b.token ?? ''));
    if (jpg.length < 1000 || jpg[0] != 0xFF || jpg[1] != 0xD8) {
      throw TestFailure('the screen-off alert photo is not a JPEG');
    }
    await f.net(() => _save('pcfgs_alert2_screen_off.jpg', jpg));
    f.note('alert 2 (screen off): ${ev['type']} photo ${jpg.length} B');
    f.note('screen on: ${await _sidecar(f, 'WAKE')}');
  });

  await f.step('screen on: the screen takes the camera back', () async {
    await f.pumpFor(const Duration(seconds: 3));
    await f.eventually('the service released the camera', () async => (await _svc())['camera_open'] != true,
        seconds: 20);
    await _status(f, f.t.pcWatching, seconds: 30);
    await f.shot('screen-on-again');
  });

  await f.step('Stop IN THE NOTIFICATION ends the run; the camera service is gone', () async {
    final r = await _sidecar(f, 'NOTIFSTOP', seconds: 90);
    f.note('notification stop: $r');
    if (!r.startsWith('tapped')) throw TestFailure('the notification Stop button was not found: $r');
    await f.waitFor(_k('pcStart'), seconds: 20, what: 'the run ended on screen (Start shown)');
    await f.eventually('Android no longer lists the camera service', () async {
      final s = await _svc();
      return s['running'] != true && s['listed'] == false;
    }, seconds: 20);
    f.note('dump stopped: ${await _sidecar(f, 'DUMP')}');
    await f.shot('stopped-from-notification');
  });

  await f.step('Start again + the on-screen Stop also ends the service', () async {
    await f.tap(_k('pcStart'), settleSeconds: 3);
    await f.eventually('service on again', () async => (await _svc())['running'] == true, seconds: 20);
    await _reveal(f);
    await f.tap(_k('pcStop'), settleSeconds: 3);
    await f.waitFor(_k('pcStart'), seconds: 15, what: 'Start after the on-screen Stop');
    await f.eventually('service gone after the on-screen Stop', () async {
      final s = await _svc();
      return s['running'] != true && s['listed'] == false;
    }, seconds: 20);
    f.note('dump stopped2: ${await _sidecar(f, 'DUMP')}');
  });

  PhoneCameraScreen.debugNoPersonModel = false;
  await f.net(() => a.shopDeleteCamera(camId).catchError((_) => <String, dynamic>{}));
  f.note('alerts with photo: ${shots.length + 1}; outbox since ${jsonEncode(t0)}');
}

void registerPhonecamFgsFlows() {
  realityFlow('pcfgs1_phone_camera_fgs', 'CCTV phone camera',
      'Old phone = camera: pair -> Start -> camera foreground service + notification -> motion alert '
      'with photo to the second account -> live view (real video) -> screen OFF keeps watching '
      '(2nd alert with photo) -> Stop in the notification -> service gone -> on-screen Stop',
      _flow,
      timeout: const Duration(minutes: 18));
}
