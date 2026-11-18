// flag-cctv-e2e (W3) — CCTV ALERT -> ACTION, end to end on the emulator.
//
// Runs ONLY with REALITY_ONLY=start,cctv in .github/workflows/camflows.yml
// (settings_e2eproof + E2E_VENDOR_SIM=1: the fake vendor clouds of
// backend/ci_e2e/vendor_sim.py). Everything is the real app + real server
// except what would leave the runner: the DoLynk cloud (simulated, SIGNED
// pushes to our PUBLIC callback link, over real HTTP), its picture CDN + live
// HLS (served inside the runner) and FCM itself (the server's push goes to
// the CI outbox; this flow hands that exact message to the app's foreground
// push path — the same code an FCM onMessage runs).
//
//   1. a camera in the vendor cloud is linked + imported (the add-camera UI
//      is proven by camflows); family viewer B is added
//   2. the vendor pushes a SIGNED person alarm -> phone A shows the
//      notification WITH the photo; latency webhook -> shown is printed
//   3. the notification tap opens the alert card: photo, Live, 999
//   4. a 2nd alarm within 30 s is MERGED ("seen 2 times", no 2nd push); the
//      vendor re-sending the same message is ignored
//   5. Watch live plays the vendor HLS; data use per live minute is printed
//   6. Call 999 asks first, then ONLY opens the dialer (tel:999, never a call)
//   7. the evidence pack is built and handed to the share step (zip with
//      photo, manifest, SHA-256 sums)
//   8. family viewer B got the alert (push + the alert on B's account)
//   9. offline: the alert list shows an honest error and loads BY ITSELF
//      when the network is back
//  10. 2G: the alert photo shows its loading state and then loads
// Key steps are shot in English AND Bangla.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/notifications.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/push/push_service.dart';
import 'package:assisto/screens/watchman/cctv_escalate.dart' show police999Launch;
import 'package:assisto/screens/watchman/cctvx_actions.dart' show evidenceShareOverride;
import 'package:assisto/screens/watchman/alert_snapshot.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/screens/watchman/watchman_source.dart';

import '../support/harness.dart';

const _siteName = 'Camflows Shop';
final _tag = (DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0');
final _serial = 'CAE$_tag';

ApiClient _api(RFlow f) {
  final c = ApiClient.detached(f.app.api.token ?? '');
  c.lang = 'en';
  return c;
}

List<Map<String, dynamic>> _list(dynamic v) =>
    ((v ?? const []) as List).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

Finder _k(String k) => find.byKey(ValueKey(k));

Future<Map<String, dynamic>> _sim(RFlow f, ApiClient api, Map<String, dynamic> body) =>
    f.net(() => api.postJson('/ci-e2e/vendor-sim', body));

/// Server clock (the outbox's `now`) minus this phone's clock, in seconds.
Future<double> _clockOffset(RFlow f, ApiClient api) async {
  final a = DateTime.now().millisecondsSinceEpoch / 1000;
  final d = await f.net(() => api.getJson('/ci-e2e/outbox?kind=none'));
  final b = DateTime.now().millisecondsSinceEpoch / 1000;
  return (d['now'] as num).toDouble() - (a + b) / 2;
}

/// The server's push rows for [api]'s user since [since] (server clock).
Future<List<Map<String, dynamic>>> _pushes(RFlow f, ApiClient api, double since) async {
  final o = await f.net(() => api.getJson('/ci-e2e/outbox?kind=push&user=me&since=$since'));
  return _list(o['rows']).where((r) => r['push_kind'] == 'shop_alert').toList();
}

/// One outbox row -> the data map FCM would hand the app (push.py builds the
/// same: the alert data + kind / title / body / lang).
Map<String, dynamic> _fcmData(Map<String, dynamic> row) => {
      ...((row['data'] as Map?) ?? const {}).cast<String, dynamic>(),
      'kind': 'shop_alert',
      'title': '${row['title'] ?? ''}',
      'body': '${row['body'] ?? ''}',
      'lang': 'en',
      'channel': 'alerts',
      'sent_at': '${(row['ts'] as num).toInt()}',
    };

/// Ask the CI host (tools/reality/run_flows.sh) for something and wait for
/// its ack: REALITY_NET off|on, REALITY_NETSPEED <profile>, REALITY_SHADE.
Future<void> _host(RFlow f, String cmd, String arg) async {
  final file = '${cmd.toLowerCase()}_${arg}_$_tag';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_$cmd $arg $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) return;
  }
  f.note('host never acked $cmd $arg');
}

/// Does the test backend ANSWER an HTTP request right now? (Any HTTP status
/// counts.) A bare TCP connect is not enough: the emulator's NAT completes
/// the guest's handshake itself, so a blocked backend still "connected"
/// (runs 44219548996 / 44240689124).
Future<bool> _reachable() async {
  final hc = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await hc.getUrl(Uri.parse('${AppConfig.apiBase}/api/v1/features?fv=2'))
        .timeout(const Duration(seconds: 4));
    final res = await req.close().timeout(const Duration(seconds: 4));
    await res.drain<void>().timeout(const Duration(seconds: 4));
    return true;
  } catch (_) {
    return false;
  } finally {
    hc.close(force: true);
  }
}

/// [refresh]: pull the list down after the switch so the server's own words
/// (alert title, AI label) also come in Bangla, as a Bangla user sees them.
Future<void> _shotBoth(RFlow f, String name, {bool refresh = false}) async {
  Future<void> pull() async {
    if (!refresh) return;
    final sc = find.byType(Scrollable);
    if (sc.evaluate().isEmpty) return;
    await f.tester.fling(sc.first, const Offset(0, 400), 1200);
    await f.pumpFor(const Duration(seconds: 3));
  }

  await f.shot('$name-en');
  await f.app.setLocale(const Locale('bn'), syncServer: false);
  await f.pumpFor(const Duration(milliseconds: 1500));
  await pull();
  await f.shot('$name-bn');
  await f.app.setLocale(const Locale('en'), syncServer: false);
  await f.pumpFor(const Duration(milliseconds: 1200));
  await pull();
}

void _metric(RFlow f, String line) {
  // ignore: avoid_print
  print('CCTV_E2E_METRIC $line');
  f.note(line);
}

class _Shown {
  final PushPayload p;
  final bool picture;
  final DateTime at;
  _Shown(this.p, this.picture, this.at);
}

Future<void> _flow(RFlow f) async {
  await f.home();
  final api = _api(f);
  final apiB = await f.h.backend(userB: true);
  late int site;
  late int cam;
  late int ch;
  late int eventId;
  late Map<String, dynamic> push1;
  late double webhookAt;
  late String msgId;
  final shown = <_Shown>[];
  PushNotifier.debugOnShown = (p, pic) => shown.add(_Shown(p, pic, DateTime.now()));
  Uri? dialed;
  final prevDial = police999Launch;
  police999Launch = (uri) async {
    dialed = uri; // the dialer would open here — NEVER a call
    return true;
  };
  String? packPath;
  String? packText;
  evidenceShareOverride = (path, text) async {
    packPath = path;
    packText = text;
  };

  try {
    await f.step('a DoLynk camera in the vendor cloud, linked + imported; viewer B added', () async {
      final s = await f.net(() => api.shopSites());
      final row = _list(s['sites']).where((x) => x['name'] == _siteName).toList();
      if (row.isEmpty) throw TestFailure('seed_camflows made no "$_siteName"');
      site = (row.first['id'] as num).toInt();
      await _sim(f, api, {
        'op': 'add_device', 'vendor': 'dolynk', 'serial': _serial, 'code': 'DH1234',
        'channels': 1, 'name': 'Gate NVR'
      });
      final l = await f.net(() => api.postJson('/cctv/connect/dolynk/link',
          {'site': site, 'serial': _serial, 'code': 'DH1234', 'consent': true}));
      final linkId = ((l['link'] as Map)['id'] as num).toInt();
      final d = await f.net(() => api.getJson('/cctv/connect/links/$linkId/devices'));
      ch = (_list(_list(d['devices']).first['channels']).first['no'] as num).toInt();
      final imp = await f.net(() => api.postJson('/cctv/connect/links/$linkId/import', {
            'items': [
              {'serial': _serial, 'channel': ch, 'name': 'Gate'}
            ]
          }));
      cam = (_list(imp['added']).first['id'] as num).toInt();
      f.note('camera $cam channel $ch');
      final v = await f.net(() => api.postJson('/shop/sites/$site/viewers',
          {'phone': Seed.phoneB, 'role': 'family', 'live_ok': true}));
      f.note('viewer B: ${v['role'] ?? v['viewer'] ?? 'added'}');
      // the app's notification plugin (lib/main.dart does this at start)
      if (!Notifications.ready) await f.net(() => Notifications.init());
      await f.net(() => PushNotifier.createChannels('en'));
    });

    await f.step('the vendor PUSHES a signed person alarm -> phone A shows it with the photo', () async {
      final off = await _clockOffset(f, api);
      final r = await _sim(f, api, {
        'op': 'push_alarm', 'vendor': 'dolynk', 'serial': _serial, 'channel': ch,
        'kind': 'human', 'deliver': 'callback'
      });
      final cb = (r['callback'] as Map?) ?? const {};
      f.note('callback ${cb['status']} ${cb['body']}');
      if (cb['status'] != 200 || !'${cb['body']}'.contains('raised')) {
        throw TestFailure('the signed push was not raised: $cb');
      }
      webhookAt = (r['webhook_at'] as num).toDouble();
      msgId = '${r['msg_id']}';
      // FCM stands in: the moment the server's push exists, it is delivered
      List<Map<String, dynamic>> rows = const [];
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (rows.isEmpty && DateTime.now().isBefore(end)) {
        rows = await _pushes(f, api, webhookAt - 1);
        if (rows.isEmpty) await f.tester.pump(const Duration(milliseconds: 150));
      }
      if (rows.isEmpty) throw TestFailure('no push to the owner within 20 s');
      push1 = _fcmData(rows.first);
      eventId = int.parse('${push1['event_id']}');
      // cctv-preview: the push carries the small photo for the notification
      if (!'${push1['snapshot_thumb_url'] ?? ''}'.contains('w=320')) {
        throw TestFailure('the push has no small photo link: ${push1.keys}');
      }
      final n0 = shown.length;
      PushService.instance.debugDeliverForeground(push1);
      await f.eventually('the notification is drawn', () async => shown.length > n0, seconds: 20);
      final s = shown.last;
      final shownServer = s.at.millisecondsSinceEpoch / 1000 + off;
      final total = ((shownServer - webhookAt) * 1000).round();
      final server = (((rows.first['ts'] as num).toDouble() - webhookAt) * 1000).round();
      _metric(f, 'push_latency_ms=$total (webhook->push queued $server ms, '
          'push->notification shown ${total - server} ms; FCM transit not included) picture=${s.picture}');
      if (!s.picture) throw TestFailure('the notification has no alert photo');
      if (s.p.notificationId != PushPayload.fromData(push1).notificationId) {
        throw TestFailure('notification id is not per alert');
      }
      await _host(f, 'SHADE', 'open');
      await f.pumpFor(const Duration(seconds: 2));
      await f.shot('notification-shade');
      await _host(f, 'SHADE', 'close');
    });

    await f.step('tap the notification -> the alert card: photo, Live, Call 999', () async {
      PushService.instance.debugTap(push1);
      // a real tap removes the notification (autoCancel); do the same
      await f.net(() => FlutterLocalNotificationsPlugin()
          .cancel(PushPayload.fromData(push1).notificationId));
      await f.pumpFor(const Duration(seconds: 2));
      await f.waitFor(find.byType(WatchmanAlertsScreen), seconds: 10, what: 'the alerts screen');
      await f.waitFor(_k('wm-snap-ok'), seconds: 25, what: 'the alert photo on the card');
      await f.waitFor(_k('wm-alert-live-$eventId'), seconds: 5, what: 'Live on the card');
      await f.waitFor(_k('wm-alert-999-$eventId'), seconds: 5, what: 'Call 999 on the card');
      await _shotBoth(f, 'alert-card', refresh: true);
    });

    await f.step('a 2nd alarm within 30 s is MERGED (no 2nd push); a vendor re-push is ignored', () async {
      final t1 = (await f.net(() => api.getJson('/ci-e2e/outbox?kind=none')))['now'] as num;
      final r = await _sim(f, api, {
        'op': 'push_alarm', 'vendor': 'dolynk', 'serial': _serial, 'channel': ch,
        'kind': 'human', 'deliver': 'callback'
      });
      final body = '${(r['callback'] as Map?)?['body']}';
      if (!body.contains('grouped')) throw TestFailure('2nd alarm not merged: $body');
      final rp = await _sim(f, api, {'op': 'repush', 'vendor': 'dolynk', 'serial': _serial, 'msg_id': msgId});
      final rb = '${(rp['callback'] as Map?)?['body']}';
      if (!rb.contains('duplicate')) throw TestFailure('vendor re-push not ignored: $rb');
      await f.pumpFor(const Duration(seconds: 3));
      final extra = await _pushes(f, api, t1.toDouble());
      if (extra.isNotEmpty) throw TestFailure('${extra.length} extra push(es) for a merged alarm');
      // the card refreshes (pull to refresh) and says "seen 2 times"
      await f.tester.fling(find.byType(Scrollable).first, const Offset(0, 400), 1200);
      await f.pumpFor(const Duration(seconds: 3));
      await f.waitFor(find.textContaining(f.t.wmSeenTimes('2')), seconds: 15, what: '"seen 2 times"');
      await f.shot('merged');
    });

    await f.step('Watch live plays the vendor HLS; data use per live minute', () async {
      await f.tap(_k('wm-alert-live-$eventId'), settleSeconds: 3);
      await f.eventually('the live picture starts', () async => _k('vendorLiveStop').evaluate().isNotEmpty,
          seconds: 40);
      // steady state: skip the player's first buffer fill, then 40 s
      await f.pumpFor(const Duration(seconds: 20));
      final b1 = ((await _sim(f, api, {'op': 'state', 'vendor': 'dolynk', 'serial': _serial}))['hls_bytes'] as num)
          .toInt();
      await f.pumpFor(const Duration(seconds: 40));
      final st = await _sim(f, api, {'op': 'state', 'vendor': 'dolynk', 'serial': _serial});
      final b2 = (st['hls_bytes'] as num).toInt();
      if (b2 <= b1) throw TestFailure('no live data flowed in 40 s ($b1 -> $b2 bytes)');
      final perMin = (b2 - b1) * 60 / 40 / (1024 * 1024);
      _metric(f, 'live_data_mb_per_min=${perMin.toStringAsFixed(2)} '
          '(${b2 - b1} bytes in 40 s of the CI 640x360 test stream; a real camera\'s SD stream differs)');
      await _shotBoth(f, 'live');
      await f.tap(_k('vendorLiveStop'), settleSeconds: 2);
      await f.back();
    });

    await f.step('Call 999: asks first, then ONLY opens the dialer (never a call)', () async {
      await f.waitFor(_k('wm-alert-999-$eventId'), seconds: 10, what: 'the card again');
      await f.tap(_k('wm-alert-999-$eventId'), settleSeconds: 1.5);
      await f.waitFor(_k('wm-alert-999-yes'), seconds: 5, what: 'the 999 question');
      await _shotBoth(f, '999-ask');
      final mark = f.httpMark;
      await f.tap(_k('wm-alert-999-yes'), settleSeconds: 2);
      if (dialed == null || dialed!.scheme != 'tel' || dialed!.path != '999') {
        throw TestFailure('the dialer was not asked for tel:999 (got $dialed)');
      }
      if (f.h.recorder.hits.skip(mark).any((h) => h.path.contains('call'))) {
        throw TestFailure('a call request left the app');
      }
      f.note('999: dialer intent $dialed only');
    });

    await f.step('the evidence pack is built and shareable', () async {
      // a 999 police card sheet may be open over the card
      if (find.byType(BottomSheet).evaluate().isNotEmpty) await f.back();
      await f.tap(_k('wm-alert-more-$eventId'), settleSeconds: 3);
      final tile = find.text(f.t.cxEvidence);
      await f.scrollTo(tile);
      await f.tap(tile.first, settleSeconds: 1.5);
      await f.shot('evidence-ask');
      await f.tap(find.text(f.t.cxEvidenceMake).last, settleSeconds: 2);
      await f.eventually('the pack reaches the share step', () async => packPath != null, seconds: 60);
      final bytes = await f.tester.runAsync(() => File(packPath!).readAsBytes());
      final names = latin1.decode(bytes!, allowInvalid: true);
      for (final want in ['photo.jpg', 'manifest.json', 'SHA256SUMS.txt']) {
        if (!names.contains(want)) throw TestFailure('$want missing from the pack');
      }
      _metric(f, 'evidence_pack_bytes=${bytes.length} share_text_has_hash=${packText!.contains(RegExp('[0-9a-f]{16}'))}');
      await _shotBoth(f, 'evidence-ready');
      if (find.byType(BottomSheet).evaluate().isNotEmpty) await f.back();
    });

    await f.step('family viewer B gets the alert (push + on B\'s account)', () async {
      final rows = await _pushes(f, apiB, webhookAt - 1);
      final mine = rows.where((r) => '${(r['data'] as Map?)?['event_id']}' == '$eventId').toList();
      if (mine.length != 1) throw TestFailure('B got ${mine.length} pushes for the alert');
      if ('${(mine.first['data'] as Map)['viewer']}'.toLowerCase() != 'true') {
        throw TestFailure('B\'s push does not open read-only');
      }
      final ev = await f.net(() => apiB.getJson('/shop/events?site=$site'));
      if (!_list(ev['events']).any((e) => e['id'] == eventId)) {
        throw TestFailure('the alert is not on B\'s account');
      }
      final lat = (((mine.first['ts'] as num).toDouble() - webhookAt) * 1000).round();
      _metric(f, 'viewer_b_push_queued_ms=$lat (B\'s own phone is not this emulator)');
    });

    await f.step('offline: the alert list says so and loads BY ITSELF when back online', () async {
      await f.back(); // leave the alerts screen
      await _host(f, 'NET', 'off');
      await _host(f, 'NETSPEED', 'block'); // the backend unreachable for real (TCP reset)
      // eventually() already runs the probe in real async — a nested
      // f.net (runAsync) inside it never returned true (runs 44181292975 ..
      // 44244324245), although the app itself got 'Network is unreachable'
      await f.eventually('the backend is unreachable', () async => !(await _reachable()), seconds: 30);
      await f.pushScreen(WatchmanAlertsScreen(source: ApiWatchmanSource(f.app.api), siteId: site, owner: true));
      await f.waitFor(_k('wm-alerts-autoretry'), seconds: 40, what: 'the offline state');
      await _shotBoth(f, 'offline');
      await _host(f, 'NETSPEED', 'unblock');
      await _host(f, 'NET', 'on');
      final t0 = DateTime.now();
      await f.waitFor(_k('wm-alert-999-$eventId'), seconds: 90, what: 'the alert, with no tap');
      _metric(f, 'offline_recovered_s=${DateTime.now().difference(t0).inSeconds} (no tap)');
      await f.shot('back-online');
      await f.back();
    });

    await f.step('2G: notification + card show the small photo in < 5 s, the full one follows', () async {
      // cctv-preview: real 2G on the runner (64 kbit/s, 300 ms; tc netem on
      // everything the backend sends) — see tools/reality/run_flows.sh
      await _host(f, 'NETSPEED', 'gprs');
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      // the notification on 2G: drawn WITH the small photo
      final n0 = shown.length;
      final tn = DateTime.now();
      PushService.instance.debugDeliverForeground(push1);
      await f.eventually('the notification is drawn on 2G', () async => shown.length > n0, seconds: 30);
      final nMs = shown.last.at.difference(tn).inMilliseconds;
      _metric(f, 'notification_2g_ms=$nMs picture=${shown.last.picture} (push -> drawn, small photo fetched on 2G)');
      if (!shown.last.picture) throw TestFailure('no photo in the notification on 2G');
      await f.net(() => FlutterLocalNotificationsPlugin().cancel(PushPayload.fromData(push1).notificationId));
      // the card on 2G
      final phases = <String, int>{};
      final sw = Stopwatch()..start();
      AlertSnapshot.debugOnPhase = (p) => phases.putIfAbsent(p, () => sw.elapsedMilliseconds);
      try {
        await f.pushScreen(WatchmanAlertsScreen(source: ApiWatchmanSource(f.app.api), siteId: site, owner: true),
            settleSeconds: 0.3);
        await f.shot('2g-loading'); // what a 2G user sees first
        await f.eventually('the small photo on 2G',
            () async => phases.containsKey('preview') || phases.containsKey('full'), seconds: 30);
        await f.shot('2g-preview');
        await f.eventually('the full photo on 2G', () async => phases.containsKey('full'), seconds: 120);
        await f.shot('2g-full');
      } finally {
        AlertSnapshot.debugOnPhase = null;
      }
      final pv = phases['preview'] ?? phases['full']!;
      _metric(f, 'snapshot_2g_preview_ms=$pv snapshot_2g_full_ms=${phases['full']} '
          '(screen open -> photo drawn; 64 kbit/s + 300 ms)');
      if (pv > 5000) throw TestFailure('the small photo took $pv ms on 2G (target < 5000)');
      await _host(f, 'NETSPEED', 'full');
      await f.back();
    });
  } finally {
    PushNotifier.debugOnShown = null;
    police999Launch = prevDial;
    evidenceShareOverride = null;
  }
}

void registerCctvAlertFlows() {
  realityFlow(
      'cae1_cctv_alert_action',
      'CCTV alert -> action',
      'Signed DoLynk person alarm -> push with photo on phone A (latency printed) -> card: photo, '
          'Live (vendor HLS, MB per live minute), Call 999 (dialer only), evidence pack -> 2nd alarm '
          'merged, vendor re-push ignored -> family viewer B alerted -> offline auto-retry -> photo on 2G',
      _flow,
      timeout: const Duration(minutes: 15));
}
