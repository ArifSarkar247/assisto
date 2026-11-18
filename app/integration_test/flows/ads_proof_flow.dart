// ads-nine (board row 54): the ADS proof on a real emulator with Google's
// TEST ad units (the CI debug APK can never load a real unit:
// AdmobSdk.unitAllowed). Opt-in group "ads" (reality.yml only=ads).
//
// Two independent counters prove "zero ad requests":
//  * in the app: AdTelemetry.requestLog (every SDK load the app started);
//  * on the runner: a packet capture (tools/reality/ads_netcount.py) of
//    every DNS query / TLS hello to Google's ad hosts, split by the
//    `REALITY_ADS_PHASE <name> begin|end` lines this flow prints (the host
//    stamps them with its own clock, tools/reality/run_flows.sh).
//
// Order matters (ads hosts' DNS is cold until the first ad request):
//  1. Premium (seeded A, trial) on an allowed banner screen + Home -> 0;
//  2. Free (seeded E) on SOS hub, an incoming call, Quran, blood -> 0;
//  3. Free on an allowed screen -> one banner, load-to-paint time measured;
//  4. airplane mode, another allowed screen -> no ad and NO blank gap.
import 'dart:async';
import 'dart:io';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_telemetry.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/quran_learn/quran_learn_screen.dart';
import 'package:assisto/screens/blood/blood_hub_screen.dart';
import 'package:assisto/screens/dictionary_screen.dart';
import 'package:assisto/screens/emergency_hub_screen.dart';
import 'package:assisto/screens/saved_items_screen.dart';
import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _phoneFree = '01700000005'; // seed_reality "ads" (CI-only, Free)
final _tag = DateTime.now().millisecondsSinceEpoch.toString();

/// Host-stamped phase marker (run_flows.sh writes ads_phases.log).
void _phase(String name, String edge) {
  // ignore: avoid_print
  print('REALITY_ADS_PHASE $name $edge');
}

/// Requests the app started since [since].
List<AdRequestLog> _requestsSince(DateTime since) =>
    AdTelemetry.requestLog.where((r) => !r.at.isBefore(since)).toList();

Future<void> _net(RFlow f, bool off) async {
  final file = 'ads_net_${off ? 'off' : 'on'}_$_tag';
  final d = await f.tester.runAsync(() => f.h.outDir());
  // ignore: avoid_print
  print('REALITY_NET ${off ? 'off' : 'on'} $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    final ack = await f.tester.runAsync(() => File('${d!.path}/acks/$file').exists());
    if (ack == true) break;
  }
  await f.pumpFor(Duration(seconds: off ? 4 : 8));
}

/// [screen] on top for [seconds]; the window starts 3 s after it is shown
/// (anything started before belongs to the screen underneath).
Future<void> _zeroOn(RFlow f, String name, Widget screen,
    {int seconds = 14, bool replace = true}) async {
  final nav = appNavigatorKey.currentState;
  if (nav == null) throw TestFailure('no navigator');
  final route = MaterialPageRoute<void>(builder: (_) => screen);
  unawaited(replace ? nav.pushReplacement(route) : nav.push(route));
  await f.pumpFor(const Duration(seconds: 3));
  final since = DateTime.now();
  _phase(name, 'begin');
  await f.pumpFor(Duration(seconds: seconds));
  _phase(name, 'end');
  await f.shot(name);
  final got = _requestsSince(since);
  if (got.isNotEmpty) {
    throw TestFailure('$name made ${got.length} ad request(s): '
        '${got.map((r) => '${r.format}/${r.placement}').join(', ')}');
  }
  if (find.byKey(const ValueKey('ad-banner-slot')).hitTestable().evaluate().isNotEmpty) {
    throw TestFailure('$name shows a banner');
  }
  f.note('$name: 0 ad requests in ${seconds}s');
}

/// The visible slot's height (0 / nav inset = no gap) or -1 when none.
double _slotHeight(RFlow f) {
  final s = find.byType(AdBannerSlot).hitTestable();
  if (s.evaluate().isEmpty) return -1;
  return f.tester.getSize(s.last).height;
}

void registerAdsProofFlows() {
  realityFlow('60_ads_proof', 'Money',
      'Ads: Premium 0 requests; SOS/call/Quran/blood 0 requests (Free); Free banner with load-to-paint time; airplane = no blank gap',
      (f) async {
    await f.home();
    // ------------------------------------------------ 1. Premium = zero
    await f.step('Premium (A, trial): allowed banner screen + Home -> 0 requests',
        () async {
      final since = DateTime.now();
      _phase('premium', 'begin');
      await f.pushScreen(const DictionaryScreen(), settleSeconds: 22);
      await f.shot('premium_dictionary');
      await f.back();
      await f.pumpFor(const Duration(seconds: 10)); // Home (native slot)
      _phase('premium', 'end');
      final got = _requestsSince(since);
      if (got.isNotEmpty) {
        throw TestFailure('Premium made ${got.length} ad request(s): '
            '${got.map((r) => r.placement).join(', ')}');
      }
      if (_slotHeight(f) > 60) throw TestFailure('Premium: an ad slot takes space');
      f.note('premium: 0 ad requests in 32s (in-app log)');
    });
    // ------------------------------------------------ 2. Free, blocked screens
    await f.step('sign in as the Free account E', () async {
      await f.net(() => f.app.logout());
      await f.pumpFor(const Duration(seconds: 2));
      await f.net(() => f.app.login(identifier: _phoneFree, password: Seed.password));
      await f.pumpFor(const Duration(milliseconds: 300));
      // straight onto the SOS hub: Home is never on top in the no-ad windows
      final nav = appNavigatorKey.currentState!;
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const EmergencyHubScreen())));
      await f.pumpFor(const Duration(seconds: 2));
      if (f.app.user?.phone?.endsWith(_phoneFree.substring(1)) != true) {
        throw TestFailure('not signed in as the Free account (${f.app.user?.phone})');
      }
    });
    await f.step('Free: SOS hub -> 0 requests', () async {
      await _zeroOn(f, 'free_sos', const EmergencyHubScreen());
    });
    await f.step('Free: incoming call -> 0 requests', () async {
      await _zeroOn(
          f,
          'free_call',
          IncomingCallScreen(
              payload: PushPayload(const {
            'kind': 'call',
            'call_id': '990001',
            'chat_id': '990001',
            'caller_name': 'Reality Karim',
            'video': 'false',
          })));
    });
    await f.step('Free: Quran -> 0 requests', () async {
      await _zeroOn(f, 'free_quran', const QuranLearnScreen());
    });
    await f.step('Free: blood donors -> 0 requests', () async {
      await _zeroOn(f, 'free_blood', const BloodHubScreen());
      await f.backToHome();
    });
    // ------------------------------------------------ 3. Free, allowed screen
    await f.step('Free: allowed screen shows ONE test banner (load-to-paint time)',
        () async {
      final since = DateTime.now();
      AdBannerSlot.lastLoadToPaintMs = -1;
      _phase('free_banner', 'begin');
      await f.pushScreen(const DictionaryScreen(), settleSeconds: 2);
      await f.eventually('a banner is painted',
          () async => find.byKey(const ValueKey('ad-banner-view')).evaluate().isNotEmpty,
          seconds: 40);
      await f.pumpFor(const Duration(seconds: 3));
      _phase('free_banner', 'end');
      await f.shot('free_banner');
      final got = _requestsSince(since);
      final banners = got.where((r) => r.format == 'banner').length;
      if (banners < 1) throw TestFailure('banner painted but no request logged');
      final ms = AdBannerSlot.lastLoadToPaintMs;
      // ignore: avoid_print
      print('REALITY_METRIC ads_banner_load_to_paint_ms $ms');
      f.note('free: banner load-to-paint ${ms}ms, $banners banner request(s)');
      // tap the Ad label: the honest "Why this ad?" sheet
      await f.tap(find.byKey(const ValueKey('ad-why-open')), settleSeconds: 2);
      await f.waitFor(find.byKey(const ValueKey('ad-why-sheet')), what: 'Why this ad sheet');
      await f.shot('why_this_ad');
      await f.tap(find.byKey(const ValueKey('ad-why-close')), settleSeconds: 1);
      await f.back();
    });
    // ------------------------------------------------ 4. airplane mode
    await f.step('airplane mode: allowed screen -> no ad, no blank gap', () async {
      await _net(f, true);
      try {
        _phase('airplane', 'begin');
        await f.pushScreen(const SavedItemsScreen(), settleSeconds: 20);
        _phase('airplane', 'end');
        await f.shot('airplane_no_gap');
        if (find.byKey(const ValueKey('ad-banner-slot')).evaluate().isNotEmpty) {
          throw TestFailure('an ad frame shows while offline');
        }
        final h = _slotHeight(f);
        final inset = MediaQuery.paddingOf(
                f.tester.element(find.byType(AdBannerSlot).hitTestable().last))
            .bottom;
        if (h > inset + 1) throw TestFailure('blank ad gap offline: ${h}dp (inset $inset)');
        f.note('offline: slot ${h}dp = nav inset, no blank gap');
      } finally {
        await _net(f, false);
      }
      await f.backToHome();
    });
    // back to A for the flows after this one
    await f.net(() => f.app.logout());
    await f.pumpFor(const Duration(seconds: 2));
    await f.net(() => f.app.login(identifier: Seed.phoneA, password: Seed.password));
    await f.pumpFor(const Duration(seconds: 3));
  }, timeout: const Duration(minutes: 8));
}
