// homefeed (board row 38): the Today facts on the emulator against the CI
// backend's RECORDED-provider sample (seed_reality -> core/world_sample.py:
// weather last good 5 h ago with the source failing, fresh currency, an
// official gold price 20 days old). Own reality group: REALITY_ONLY=homefeed.
//
// 40_homefeed_today
//   online  : Today opens from its route; prayer times carry their date; the
//             weather card keeps the REAL last value (never blank / 0) and
//             says "the source isn't responding — last updated 5 h ago";
//             the old gold price says "may have changed"
//   OFF     : real airplane mode (host-side adb, tools/reality/run_flows.sh);
//             the app is closed and opened again with NO network -> Home ->
//             Today paints the saved copy in < 1 s, dated "copy saved X ago"
//   ON      : airplane mode off -> pull to refresh -> the offline banner is
//             gone and the server copy is back (refresh updates the screen)
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/config.dart';
import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/screens/world/world_today_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

Future<bool> _reachable() async {
  final u = Uri.parse(AppConfig.apiBase);
  try {
    final s = await Socket.connect(u.host, u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80),
        timeout: const Duration(seconds: 2));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Ask the CI host to switch airplane mode (adb) and wait for its ack (same
/// protocol as offline_first_flow.dart).
Future<void> _airplane(RFlow f, bool on) async {
  final file = 'net_${on ? 'off' : 'on'}_hf_$_tag';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_NET ${on ? 'off' : 'on'} $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) break;
  }
  await f.eventually(on ? 'the backend is UNREACHABLE (airplane mode on)' : 'the backend is reachable again',
      () async => (await _reachable()) != on,
      seconds: on ? 30 : 90);
}

/// Real milliseconds until [finder] shows (pumping every 16 ms).
Future<int> _msUntil(RFlow f, Finder finder, {int maxMs = 8000}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < maxMs) {
    await f.tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) return sw.elapsedMilliseconds;
  }
  throw TestFailure('not shown within $maxMs ms: ${finder.describeMatch(Plurality.one)}');
}

const _prayer = ValueKey('uw_card_prayer');
const _weather = ValueKey('uw_card_weather');

void registerHomefeedFlows() {
  realityFlow('40_homefeed_today', 'Daily life',
      'Today facts: dated, outage honest, offline copy < 1 s, refresh', (f) async {
    await f.home();
    await f.step('online: dated prayer times; outage weather keeps its real value + "5 h ago"', () async {
      await f.openRoute('daily_today', settleSeconds: 3);
      await f.waitFor(find.byType(WorldTodayScreen), what: 'Today screen');
      await f.waitFor(find.byKey(_prayer), seconds: 25, what: 'prayer card');
      expect(find.byKey(const ValueKey('uw_prayer_date')), findsOneWidget);
      expect(find.byKey(const ValueKey('uw_offline_copy')), findsNothing);
      await f.shot('homefeed_online_top');
      await f.scrollToBuilt(find.byKey(const ValueKey('uw_stale_weather')), what: 'weather outage line');
      final temp = find.descendant(of: find.byKey(_weather), matching: find.textContaining('°'));
      expect(temp, findsWidgets);
      final shown = f.tester.widgetList<Text>(temp).map((t) => t.data ?? '').toList();
      f.note('weather shows ${shown.join(' | ')}');
      expect(shown.any((s) => s == '0°' || s == '০°' || s == '°'), isFalse,
          reason: 'never a blank or 0 temperature');
      final stale = f.tester.widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('uw_stale_weather')), matching: find.byType(Text)));
      f.note('outage line: ${stale.data}');
      expect(stale.data, contains(f.t.uwAgoHours(f.t.localeName == 'bn' ? '৫' : '5')));
      await f.shot('homefeed_outage_weather');
      await f.scrollToBuilt(find.byKey(const ValueKey('uw_stale_gold')), what: 'old gold price warning');
      await f.shot('homefeed_gold_stale');
    });

    await f.step('airplane mode ON (real network off)', () async {
      await _airplane(f, true);
    });

    await f.step('reopen the app offline -> Home -> Today paints the saved copy < 1 s, dated', () async {
      appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      await f.pumpFor(const Duration(seconds: 1));
      final t0 = DateTime.now();
      await f.h.boot(f.tester, settleSeconds: 0);
      await f.home();
      f.note('offline cold open -> Home: ${DateTime.now().difference(t0).inMilliseconds} ms');
      await f.pumpFor(const Duration(seconds: 2));
      final nav = appNavigatorKey.currentState!;
      unawaited(nav.push(MaterialPageRoute(builder: (_) => const WorldTodayScreen())));
      final ms = await _msUntil(f, find.byKey(_prayer));
      f.note('offline: Today first card painted in $ms ms (saved copy)');
      expect(ms, lessThan(1000), reason: 'saved facts must paint in under 1 s offline');
      await f.waitFor(find.byKey(const ValueKey('uw_offline_copy')), seconds: 20, what: 'offline banner');
      final banner = f.tester.widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('uw_offline_copy')), matching: find.byType(Text)));
      f.note('offline banner: ${banner.map((t) => t.data).join(' ')}');
      expect(find.byKey(_weather), findsOneWidget); // copy kept, not blank
      await f.shot('homefeed_offline_copy');
    });

    await f.step('airplane mode OFF -> pull to refresh -> server copy back, banner gone', () async {
      await _airplane(f, false);
      final list = find.descendant(of: find.byType(WorldTodayScreen), matching: find.byType(Scrollable)).first;
      for (var i = 0; i < 4 && find.byKey(const ValueKey('uw_offline_copy')).evaluate().isNotEmpty; i++) {
        await f.tester.fling(list, const Offset(0, 500), 1500);
        await f.pumpFor(const Duration(seconds: 4));
      }
      expect(find.byKey(const ValueKey('uw_offline_copy')), findsNothing);
      expect(find.byKey(const ValueKey('uw_saved_copy')), findsNothing);
      expect(find.byKey(_prayer), findsOneWidget);
      await f.shot('homefeed_refreshed');
    });
  }, timeout: const Duration(minutes: 6));
}
