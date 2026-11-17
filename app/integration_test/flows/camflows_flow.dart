// camflows — CCTV BRAND CLOUDS end to end on the emulator (owner order
// 9 Nov: "add-camera flows END TO END with fakes in CI").
//
// Runs ONLY in .github/workflows/camflows.yml (REALITY_ONLY=start,camflows)
// against the throw-away Django with settings_e2eproof + E2E_VENDOR_SIM=1:
// the real app UI, the real server, and FAKE vendor clouds behind the vendor
// seams (backend/ci_e2e/vendor_sim.py — EZVIZ, Imou + Imou OAuth, Dahua
// DoLynk; a real HLS test stream; a fake Imou consent page).
//
// Each brand, through the UI a shop owner uses:
//   add camera (label serial + code + consent tick | one-tap Imou account)
//   -> the device and its channels appear -> import
//   -> the camera appears in CCTV -> live view opens the vendor HLS
//      (the phone's player really fetches the fake stream)
//   -> a camera alarm in the vendor cloud arrives as a Guard alert with its
//      snapshot (Imou: PUSHED to our callback; EZVIZ: the minute poll;
//      Imou OAuth + Dahua: the brand-cloud tick) + a push to the owner
//   -> the daily numbers ("Alerts: N.") count it -> unlink.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/cctvconnect/cctv_connect_screen.dart';
import 'package:assisto/shop_api.dart';

import '../support/harness.dart';

const _apiBase = String.fromEnvironment('REALITY_API_BASE', defaultValue: 'http://10.0.2.2:8700');
const _siteName = 'Camflows Shop';
final _tag = (DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0');

class _Brand {
  final String id; // flow id
  final String pid; // cctvconnect provider id
  final String sim; // simulator vendor
  final String serial;
  final String code;
  final int channels;
  final bool oauth;
  final String deliver; // callback | store
  final String tick; // '' | ezviz_poll_alarms | cctv_connect_tick
  final String feature;
  const _Brand(this.id, this.pid, this.sim, this.serial, this.code, this.channels,
      {this.oauth = false, this.deliver = 'store', this.tick = '', required this.feature});
}

final _brands = [
  _Brand('cf1_imou_devbind', 'imou', 'imou', 'CFIM$_tag', 'SAFE01', 1,
      deliver: 'callback',
      feature: 'Imou: serial + Safety Code + consent tick -> camera -> live HLS -> PUSHED alarm '
          'as Guard alert with snapshot -> daily count -> unlink'),
  _Brand('cf2_imou_oauth', 'imou', 'imou', 'CFIO$_tag', 'OAUTH1', 1,
      oauth: true,
      tick: 'cctv_connect_tick',
      feature: 'Imou one-tap account link (fake Imou consent page) -> devices -> live HLS -> '
          'polled alarm as Guard alert with snapshot -> daily count -> unlink'),
  _Brand('cf3_ezviz', 'ezviz', 'ezviz', 'CFEZ$_tag', 'ABCDEF', 2,
      tick: 'ezviz_poll_alarms',
      feature: 'EZVIZ: link (serial + Verification Code) -> NVR channel list -> live URL -> '
          'POLLED alarm (no paid Message Service) as Guard alert with snapshot -> daily count -> unlink'),
  _Brand('cf4_dahua', 'dolynk', 'dolynk', 'CFDH$_tag', 'DH1234', 2,
      tick: 'cctv_connect_tick',
      feature: 'Dahua DoLynk: link -> NVR channel list -> live HLS -> alarm as Guard alert '
          'with snapshot -> daily count -> unlink'),
];

// ---------------------------------------------------------------- helpers
ApiClient _api(RFlow f) {
  final c = ApiClient.detached(f.app.api.token ?? '');
  c.lang = 'en';
  return c;
}

List<Map<String, dynamic>> _list(dynamic v) =>
    ((v ?? const []) as List).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

Future<Map<String, dynamic>> _sim(ApiClient api, Map<String, dynamic> body) =>
    api.postJson('/ci-e2e/vendor-sim', body);

Finder _k(String k) => find.byKey(ValueKey(k));

/// Any Text / RichText on screen containing [s].
Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      return false;
    });

/// Drag the screen's main VERTICAL list until [target] is built (lazy lists).
Future<void> _reveal(RFlow f, Finder target, {int drags = 30}) async {
  for (var i = 0; i < drags && target.evaluate().isEmpty; i++) {
    final sc = find
        .byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)
        .hitTestable();
    if (sc.evaluate().isEmpty) break;
    await f.tester.drag(sc.last, const Offset(0, -320), warnIfMissed: false);
    await f.tester.pump(const Duration(milliseconds: 350));
  }
  if (target.evaluate().isNotEmpty) await f.tester.ensureVisible(target.first);
  await f.pumpFor(const Duration(milliseconds: 400));
}

Future<void> _tapK(RFlow f, String k, {double settle = 2}) async {
  await _reveal(f, _k(k));
  await f.tap(_k(k), settleSeconds: settle);
}

/// The phone's browser on the vendor's consent page. The test stands in for
/// it: our /oauth/go -> 302 to Imou's H5 page (on the runner the fake page
/// answers for open.imoulife.com) -> "Allow" -> 302 to OUR redirect URI.
Future<List<String>> _browser(Uri start) async {
  final trail = <String>[];
  final hc = HttpClient();
  var u = start;
  try {
    for (var i = 0; i < 8; i++) {
      if (u.host == 'open.imoulife.com') {
        u = Uri.parse('$_apiBase/api/v1/ci-e2e/imou/h5').replace(queryParameters: u.queryParameters);
      }
      final req = await hc.getUrl(u);
      req.followRedirects = false;
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      trail.add('${res.statusCode} ${u.path}');
      final loc = res.headers.value('location');
      if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
        u = u.resolve(loc);
        continue;
      }
      if (u.path.endsWith('/ci-e2e/imou/h5')) {
        final m = RegExp(r"id=allow href='([^']+)'").firstMatch(body);
        if (m == null) throw StateError('no Allow on the consent page');
        trail.add('tap Allow');
        u = u.resolve(m.group(1)!.replaceAll('&amp;', '&'));
        continue;
      }
      trail.add(body.replaceAll(RegExp(r'<[^>]+>'), ' ').trim().split('\n').first);
      break;
    }
  } finally {
    hc.close(force: true);
    trail.add('done');
  }
  return trail;
}

Future<int> _alertsToday(ApiClient api, int site) async {
  final d = await api.getJson('/shop/sites/$site/activity');
  return (d['alerts'] as num?)?.toInt() ?? 0;
}

// ---------------------------------------------------------------- the flow
Future<void> _brandFlow(RFlow f, _Brand b) async {
  await f.home();
  final api = _api(f);
  late int site;
  int? linkId;
  int? camId;
  int? channelNo;
  late int alerts0;

  await f.step('a place + the ${b.pid} cloud is offered + a camera in the vendor cloud', () async {
    final s = await f.net(() => api.shopSites());
    final row = _list(s['sites']).where((x) => x['name'] == _siteName).toList();
    if (row.isEmpty) throw TestFailure('seed_camflows made no "$_siteName"');
    site = (row.first['id'] as num).toInt();
    final p = await f.net(() => api.getJson('/cctv/connect/providers?site=$site'));
    final prov = _list(p['providers']).where((x) => x['id'] == b.pid).toList();
    final mode = b.oauth ? 'oauth' : 'device_code';
    if (prov.isEmpty || !(prov.first['modes'] as List).contains(mode)) {
      throw TestFailure('${b.pid} not offered with $mode: ${p['providers']}');
    }
    await f.net(() => _sim(api, {
          'op': 'add_device', 'vendor': b.sim, 'serial': b.serial, 'code': b.code,
          'channels': b.channels, 'oauth_user': b.oauth, 'name': 'Shop NVR ${b.serial.substring(2, 4)}'
        }));
    alerts0 = await f.net(() => _alertsToday(api, site));
  });

  await f.step('CCTV -> "Connect DVR brand app"', () async {
    await f.openRoute('watchman', settleSeconds: 4);
    await f.waitFor(find.text(_siteName), seconds: 25, what: 'the place card');
    await _tapK(f, 'wm-brand-cloud', settle: 3);
    await f.waitFor(_k('ccnList'), seconds: 20, what: 'brand cloud screen');
    await f.shot('brand-clouds');
  });

  if (!b.oauth) {
    await f.step('label serial + code + consent tick -> Connect', () async {
      await _tapK(f, 'ccnBrand-${b.pid}');
      await f.waitFor(_k('ccnSerial'), what: 'link sheet');
      await f.tester.enterText(_k('ccnSerial'), b.serial);
      await f.tester.enterText(_k('ccnCode'), b.code);
      await f.pumpFor(const Duration(milliseconds: 500));
      // the consent tick is required: Connect stays disabled without it
      final btn = f.tester.widget<ButtonStyleButton>(_k('ccnConnect'));
      if (btn.onPressed != null) throw TestFailure('Connect enabled before the consent tick');
      await _tapK(f, 'ccnConsent', settle: 1);
      await f.shot('sheet-filled');
      final mark = f.httpMark;
      await _tapK(f, 'ccnConnect', settle: 4);
      if (await f.appears(_k('ccnMsg'), seconds: 2)) {
        throw TestFailure('link refused: ${f.tester.widget<Text>(_k('ccnMsg')).data}');
      }
      f.expectHttp('POST', '/cctv/connect/${b.pid}/link', since: mark);
    });
  } else {
    await f.step('one tap "Link my Imou account" -> Imou consent page -> Allow -> back', () async {
      final trail = <String>[];
      CctvConnectScreen.debugOpenUrl = (u) async {
        try {
          trail.addAll(await _browser(u));
        } catch (e) {
          trail.addAll(['browser error: $e', 'done']);
        }
        return true;
      };
      try {
        await _tapK(f, 'ccnOauth-${b.pid}', settle: 2);
        await f.eventually('the browser leg finished', () async => trail.contains('done'), seconds: 30);
        f.note('browser: ${trail.join(' > ')}');
        if (!trail.any((x) => x.contains('/cctv/imou/oauth/callback'))) {
          throw TestFailure('never reached our redirect URI: $trail');
        }
        // back from the browser: the screen reloads by itself.
        // flag-cctv-e2e: NEVER pump while paused — a paused app schedules no
        // frames, so pump() waited forever (run 44174170213: this step hung
        // 7 min, then the next flow died on '!inTest'). Walk the real
        // Android order and wait in real time while in the background.
        final lc = f.tester.binding;
        for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
          lc.handleAppLifecycleStateChanged(s);
        }
        await f.tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
        for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
          lc.handleAppLifecycleStateChanged(s);
        }
        await f.pumpFor(const Duration(seconds: 2));
      } finally {
        CctvConnectScreen.debugOpenUrl = null;
      }
      final p = await f.net(() => api.getJson('/cctv/connect/providers?site=$site'));
      final l = _list(p['links']).where((x) => x['provider'] == b.pid && x['mode'] == 'oauth').toList();
      if (l.isEmpty) throw TestFailure('no OAuth link on the server: ${p['links']}');
      linkId = (l.last['id'] as num).toInt();
      await f.waitFor(_k('ccnChoose-$linkId'), seconds: 15, what: 'the new link card');
      await f.shot('oauth-linked');
      await _tapK(f, 'ccnChoose-$linkId', settle: 3);
    });
  }

  await f.step('the device + its channels appear -> import one channel', () async {
    final p = await f.net(() => api.getJson('/cctv/connect/providers?site=$site'));
    final l = _list(p['links']).where((x) => x['provider'] == b.pid && x['status'] != 'revoked').toList();
    linkId ??= (l.last['id'] as num).toInt();
    final d = await f.net(() => api.getJson('/cctv/connect/links/$linkId/devices'));
    final dev = _list(d['devices']).where((x) => x['serial'] == b.serial).toList();
    if (dev.isEmpty) throw TestFailure('device ${b.serial} not listed: ${d['devices']}');
    final chans = _list(dev.first['channels']);
    if (chans.length != b.channels) throw TestFailure('channels ${chans.length} != ${b.channels}');
    channelNo = (chans.first['no'] as num).toInt();
    await f.waitFor(_k('ccnCh-${b.serial}-$channelNo'), seconds: 20, what: 'channel list');
    // an NVR: keep only the first channel (the owner picks what to add)
    for (final c in chans.skip(1)) {
      await _tapK(f, 'ccnCh-${b.serial}-${c['no']}', settle: 0.6);
    }
    await f.shot('channels');
    final mark = f.httpMark;
    await _tapK(f, 'ccnImport', settle: 3);
    await f.waitFor(_k('ccnResult'), seconds: 15, what: 'import result');
    f.expectHttp('POST', '/cctv/connect/links/$linkId/import', since: mark);
    await f.shot('imported');
    final cams = await f.net(() => api.shopCameras(site));
    final mine = _list(cams['cameras'])
        .where((c) => (c['source'] as Map?)?['device_serial'] == b.serial)
        .toList();
    if (mine.length != 1) throw TestFailure('expected 1 imported camera, got ${mine.length}');
    camId = (mine.first['id'] as num).toInt();
    if (mine.first['cloud_alarms'] != true) throw TestFailure('camera not cloud-linked: ${mine.first}');
  });

  await f.step('the camera appears in CCTV with its live button', () async {
    await f.back(); // devices -> brand clouds
    await f.back(); // brand clouds -> CCTV (reloads)
    await f.pumpFor(const Duration(seconds: 2));
    await _reveal(f, _k('wm-vlive-$camId'));
    await f.waitFor(_k('wm-vlive-$camId'), seconds: 15, what: 'live button of the new camera');
    await f.shot('camera-in-cctv');
  });

  await f.step('live view opens the vendor HLS (the phone fetches the stream)', () async {
    final mark = f.httpMark;
    await _tapK(f, 'wm-vlive-$camId', settle: 3);
    final live = _k('vendorLiveStop');
    final err = _k('vendorLiveMsg');
    final again = _k('vendorLiveAgain'); // shown once starting failed / ended
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(end) && live.evaluate().isEmpty && again.evaluate().isEmpty) {
      await f.pumpFor(const Duration(milliseconds: 500));
    }
    if (live.evaluate().isEmpty) {
      await f.shot('live-failed');
      final txt = err.evaluate().isEmpty ? 'nothing' : f.tester.widget<Text>(err).data;
      throw TestFailure('live did not start: $txt');
    }
    f.expectHttp('POST', '/watchman/cameras/$camId/vendor_live', since: mark);
    await f.eventually('the player fetched the vendor playlist + a segment', () async {
      final s = await _sim(api, {'op': 'state', 'vendor': b.sim, 'serial': b.serial});
      final hits = ((s['hls_hits'] ?? const []) as List).map((e) => '$e').toList();
      return hits.any((h) => h.endsWith('.m3u8')) && hits.any((h) => h.endsWith('.ts'));
    }, seconds: 25);
    await f.pumpFor(const Duration(seconds: 3));
    await f.shot('live');
    await _tapK(f, 'vendorLiveStop', settle: 2);
    await f.back(); // the stopped live view stays until the owner leaves it
  });

  await f.step('a camera alarm in the vendor cloud -> Guard alert with snapshot + push', () async {
    final t0 = ((await f.net(() => api.getJson('/ci-e2e/outbox?kind=none')))['now'] as num).toDouble();
    final r = await f.net(() => _sim(api, {
          'op': 'push_alarm', 'vendor': b.sim, 'serial': b.serial, 'channel': channelNo,
          'kind': 'human', 'deliver': b.deliver
        }));
    if (b.deliver == 'callback') f.note('Imou callback answered ${r['callback']}');
    if (b.tick.isNotEmpty) {
      final tk = await f.net(() => api.postJson('/ci-e2e/tick', {'job': b.tick, 'advance_min': 0}));
      f.note('${b.tick}: ${tk['output']}');
    }
    Map<String, dynamic>? ev;
    await f.eventually('the alert with a snapshot', () async {
      final d = await api.getJson('/shop/events?site=$site&camera=$camId');
      // (a cloud health check may add a camera_health row: look for the alarm)
      final rows = _list(d['events']).where((e) => '${e['snapshot_url'] ?? ''}'.isNotEmpty).toList();
      ev = rows.isEmpty ? null : rows.first;
      return ev != null;
    }, seconds: 30);
    f.note('alert type ${ev!['type']}');
    await f.eventually('a push to the owner', () async {
      final o = await api.getJson('/ci-e2e/outbox?kind=push&user=me&since=$t0');
      return _list(o['rows']).isNotEmpty;
    }, seconds: 20);
    // the owner opens the alerts: the photo is there
    await _reveal(f, find.text(f.t.wmAlerts).evaluate().isEmpty ? _sees('Alerts (') : find.text(f.t.wmAlerts));
    final btn = find.text(f.t.wmAlerts).evaluate().isNotEmpty ? find.text(f.t.wmAlerts) : _sees('Alerts (');
    await f.tap(btn, settleSeconds: 4);
    // flag-cctv-e2e: the photo DRAWN (AlertSnapshot's first frame), not a
    // semantics label (semantics are off in the reality harness, so
    // bySemanticsLabel never matched); a failed / deleted photo is a failure
    await f.waitFor(find.byKey(const ValueKey('wm-snap-ok')), seconds: 30, what: 'alert photo');
    await f.pumpFor(const Duration(seconds: 1));
    if (find.byKey(const ValueKey('wm-snap-error')).evaluate().isNotEmpty ||
        find.text(f.t.wmSnapshotGone).evaluate().isNotEmpty) {
      throw TestFailure('the alert photo did not load on the phone');
    }
    await f.shot('alert-with-photo');
    await f.back();
  });

  await f.step('the daily numbers count it', () async {
    final a1 = await f.net(() => _alertsToday(api, site));
    if (a1 < alerts0 + 1) throw TestFailure('alerts today $alerts0 -> $a1');
    await _tapK(f, 'wm-activity', settle: 4);
    await f.waitFor(_sees('Alerts: $a1.'), seconds: 20, what: 'the summary line "Alerts: $a1."');
    await f.shot('daily-count');
    await f.back();
  });

  // gap-cctv3: the camera's own recording (Imou devbind only — the OAuth
  // project path has no record API in the simulator): Past clips -> the
  // camera's recordings -> an hour of today -> the server's HLS answer
  if (b.pid == 'imou' && !b.oauth) {
    await f.step('Past clips -> camera recordings -> play an hour', () async {
      await _tapK(f, 'wm-past-clips', settle: 4);
      await f.waitFor(_k('gcv-clips-rec-$camId'), seconds: 20, what: 'the recordings entry');
      await f.shot('past-clips-recordings-entry');
      await _tapK(f, 'gcv-clips-rec-$camId', settle: 3);
      await f.waitFor(_k('gcv-pb-timeline'), seconds: 15, what: 'the day timeline');
      final h = DateTime.now().hour;
      await _tapK(f, 'gcv-pb-hour-$h', settle: 6);
      // the simulated Imou cloud lists the recording but (like an old
      // firmware) gives no HLS address -> the honest "watch it in Imou Life"
      // card; a real HLS answer opens the player instead. Never a blank.
      await f.eventually('the player or an honest message', () async =>
          _k('gcv-pb-player').evaluate().isNotEmpty ||
          _k('gcv-pb-play-error').evaluate().isNotEmpty ||
          _k('gcv-pb-problem-sdkOnly').evaluate().isNotEmpty, seconds: 30);
      if (find.text(f.t.gcvPbRecordsTitle).evaluate().isEmpty) {
        throw TestFailure('the hour\'s recording list did not show');
      }
      f.note(_k('gcv-pb-player').evaluate().isNotEmpty
          ? 'HLS player opened'
          : _k('gcv-pb-problem-sdkOnly').evaluate().isNotEmpty
              ? 'recording listed; no HLS from the simulated cloud (honest Imou Life message)'
              : 'player could not reach the video host (honest message shown)');
      await f.shot('camera-recording-hour');
      await f.back();
      await f.back();
    });
  }

  await f.step('unlink -> the camera keeps its history, no cloud live, the vendor lets go', () async {
    await _tapK(f, 'wm-brand-cloud', settle: 3);
    await f.waitFor(_k('ccnRemove-$linkId'), seconds: 15, what: 'the link card');
    await _tapK(f, 'ccnRemove-$linkId', settle: 1.5);
    final yes = find.descendant(of: find.byType(AlertDialog), matching: find.text(f.t.ccnRemove));
    await f.tap(yes, settleSeconds: 3);
    await f.waitFor(find.text(f.t.ccnRemoved), seconds: 10, what: '"Link removed"');
    await f.shot('unlinked');
    final p = await f.net(() => api.getJson('/cctv/connect/providers?site=$site'));
    if (_list(p['links']).any((x) => x['id'] == linkId)) throw TestFailure('link still listed');
    final cams = await f.net(() => api.shopCameras(site));
    final row = _list(cams['cameras']).where((c) => c['id'] == camId).toList();
    if (row.isEmpty) throw TestFailure('the camera (and its alert history) should stay');
    if (row.first['cloud_alarms'] == true) throw TestFailure('camera still cloud-linked');
    if (!b.oauth) {
      final s = await f.net(() => _sim(api, {'op': 'state', 'vendor': b.sim, 'serial': b.serial}));
      if (s['owner'] != null) throw TestFailure('vendor still holds the device: ${s['owner']}');
    }
    await f.back();
    await f.pumpFor(const Duration(seconds: 2));
    if (_k('wm-vlive-$camId').evaluate().isNotEmpty) throw TestFailure('live button still shown');
    // keep the plan's camera count for the next brand (the alert history stays)
    await f.net(() => api.shopDeleteCamera(camId!));
  });
}

void registerCamflowsFlows() {
  for (final b in _brands) {
    realityFlow(b.id, 'CCTV brand clouds', b.feature, (f) => _brandFlow(f, b),
        timeout: const Duration(minutes: 7));
  }
}
