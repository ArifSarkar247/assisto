// adcontrol — OWNER FINAL ORDER ADS (10 Nov 03:45), parts A–D on the device:
// the ONE placement registry (lib/ads/ad_control.dart) decides every AdMob
// ad. Proves: every placement used in lib/ is registered (and none of them is
// a safety placement); the owner's OFF list is default-OFF + safety and the
// ON list default-ON with the right type; Premium AND Plus never get AdMob;
// no config = no ad; a safety placement shows an ad ONLY when the server
// explicitly says on; the owner's type choice is honoured; list native every
// 15–20 rows; the train 15-minute window; the rewarded gate never blocks.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_control.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_reward_gate.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/ads_bridge.dart' show RewardOutcome;
import 'package:assisto/l10n/app_localizations.dart';

Map<String, dynamic> _row(bool on, String type) => {'on': on, 'type': type};

AdConfig _cfg({
  String plan = 'free',
  bool paid = false,
  Map<String, dynamic>? control,
  bool sendControl = true,
}) =>
    AdConfig.fromJson({
      'plan': plan,
      'paid': paid,
      'ads_enabled': !paid,
      'placements': {'banner': true, 'interstitial': true},
      'rewarded_enabled': true,
      'interstitial_daily_cap': 6,
      'interstitial_min_gap_sec': 180,
      if (sendControl)
        'control': control ??
            {
              'placements': {
                for (final s in AdControl.spots) s.key: _row(s.defaultOn, s.defaultTypeId)
              },
              'caps': {'list_native_every': 15, 'train_free_minutes': 15},
            },
    });

// part C, word for word (mirrors backend OWNER_OFF_LIST)
const _offList = [
  'sos', 'safe_journey_active', 'family_care', 'blood_donor', 'care_call',
  'quran', 'child_accounts', 'chats_calls', 'reminder_alarm', 'lost_mode',
  'payment', 'first_launch_login', 'timed_test', 'certificates', 'finance_forms',
];

// part D (mirrors backend OWNER_ON_LIST)
const _onList = {
  'home': 'native', 'discover_native': 'native', 'app_open': 'app_open',
  'circle_list': 'banner', 'after_call_review': 'native', 'all_services': 'native',
  'ai_chat_unlock': 'rewarded', 'photo_studio': 'rewarded',
  'photo_after_save': 'interstitial', 'lp_home': 'banner',
  'lesson_after_finish': 'interstitial', 'lp_unlock': 'rewarded',
  'exam_after_submit': 'interstitial', 'mess_home': 'banner', 'mess_list': 'native',
  'finance_home': 'native', 'finance_list': 'native', 'finance_reports': 'native',
  'finance_after_export': 'interstitial', 'finance_month_report': 'interstitial',
  'mess_month_report': 'interstitial', 'notes_home': 'banner', 'notes_list': 'native',
  'reminders_list': 'banner', 'city_search': 'banner', 'city_results': 'native',
  'city_more_routes': 'rewarded', 'train_search': 'banner',
  'train_live_unlock': 'rewarded', 'security_unlock': 'rewarded',
  'security_scan': 'rewarded', 'offers_list': 'native',
};

String _code(File f) => f
    .readAsStringSync()
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('registry', () {
    test('keys unique, well-formed, default type allowed', () {
      final keys = <String>{};
      for (final s in AdControl.spots) {
        expect(keys.add(s.key), isTrue, reason: 'duplicate ${s.key}');
        expect(RegExp(r'^[a-z][a-z0-9_]{1,39}$').hasMatch(s.key), isTrue, reason: s.key);
        expect(s.allowed, isNotEmpty, reason: s.key);
        expect(s.allowed.contains(s.defaultType), isTrue, reason: s.key);
      }
    });

    test('part C: the OFF list is default OFF and marked safety', () {
      for (final k in _offList) {
        final s = AdControl.spot(k);
        expect(s, isNotNull, reason: k);
        expect(s!.defaultOn, isFalse, reason: k);
        expect(s.safety, isTrue, reason: k);
      }
      for (final s in AdControl.spots.where((s) => s.safety)) {
        expect(s.defaultOn, isFalse, reason: '${s.key}: a safety spot is never ON by default');
      }
    });

    test('part D: the ON list is default ON with the owner type', () {
      _onList.forEach((k, type) {
        final s = AdControl.spot(k);
        expect(s, isNotNull, reason: k);
        expect(s!.defaultOn, isTrue, reason: k);
        expect(s.defaultTypeId, type, reason: k);
        expect(s.safety, isFalse, reason: k);
      });
    });

    test('every interstitial moment is registered as an interstitial spot', () {
      for (final p in AdExitPlacement.values) {
        final s = AdControl.spot(p.id);
        expect(s, isNotNull, reason: p.id);
        expect(s!.allowed, contains(AdKind.interstitial), reason: p.id);
      }
    });
  });

  group('every placement in lib/ is in the registry', () {
    final used = <String, String>{}; // key -> file
    setUpAll(() {
      final pats = [
        RegExp(r"AdBannerSlot\(\s*(?:key:[^,]+,\s*)?screen:\s*'([a-z0-9_]+)'"),
        RegExp(r"AdSpotCard\(\s*(?:key:[^,]+,\s*)?placement:\s*'([a-z0-9_]+)'"),
        RegExp(r"AdSpotCard\.afterRow\(\s*[^,]+,\s*[^,]+,\s*'([a-z0-9_]+)'"),
        RegExp(r"AdRewardGate\.run\([^;]*?placement:\s*'([a-z0-9_]+)'", dotAll: true),
      ];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.contains('/l10n/')) continue;
        final src = _code(f);
        for (final re in pats) {
          for (final m in re.allMatches(src)) {
            used[m.group(1)!] = f.path;
          }
        }
      }
    });

    test('found the wiring', () {
      for (final k in ['notes_home', 'reminders_list', 'mess_home', 'city_search',
          'finance_home', 'finance_list', 'finance_reports', 'mess_list', 'offers_list',
          'city_results', 'notes_list', 'train_live_unlock', 'security_scan',
          'security_unlock', 'all_services', 'circle_list']) {
        expect(used.containsKey(k), isTrue, reason: '$k is not wired');
      }
    });

    test('registered, never a safety spot, and the type fits', () {
      used.forEach((k, f) {
        final s = AdControl.spot(k);
        expect(s, isNotNull, reason: '$k ($f) is not in the registry');
        expect(s!.safety, isFalse, reason: '$k ($f) is an emergency / safety placement');
      });
    });
  });

  group('decisions', () {
    test('part A: Premium AND Plus never get AdMob, whatever the server says', () {
      final allOn = {
        'placements': {for (final s in AdControl.spots) s.key: _row(true, s.defaultTypeId)}
      };
      for (final plan in ['premium', 'plus', 'business', 'premium_pro']) {
        final c = _cfg(plan: plan, control: allOn);
        for (final s in AdControl.spots) {
          expect(AdControl.kindFor(s.key, c, loggedIn: true), isNull, reason: '$plan ${s.key}');
        }
        expect(AdPlacements.inline('notes_home', c, loggedIn: true), isNull);
      }
      // paid flag alone (plan unknown) also means no ads
      expect(AdControl.kindFor('notes_home', _cfg(paid: true, control: allOn), loggedIn: true),
          isNull);
    });

    test('no config / logged out = no ad', () {
      for (final s in AdControl.spots) {
        expect(AdControl.kindFor(s.key, AdConfig.none, loggedIn: true), isNull, reason: s.key);
        expect(AdControl.kindFor(s.key, _cfg(), loggedIn: false), isNull, reason: s.key);
      }
    });

    test('defaults: ON spots on, OFF screens off', () {
      final c = _cfg();
      _onList.forEach((k, type) {
        expect(AdControl.kindFor(k, c, loggedIn: true), AdControl.kindOf(type), reason: k);
      });
      for (final k in _offList) {
        expect(AdControl.kindFor(k, c, loggedIn: true), isNull, reason: k);
        expect(AdPlacements.inline(k, c, loggedIn: true), isNull, reason: k);
      }
    });

    test('a safety spot shows an ad only when the server explicitly says on', () {
      // an old / partial server answer without the row -> off
      expect(AdControl.kindFor('sos', _cfg(control: {'placements': {}}), loggedIn: true),
          isNull);
      expect(AdControl.kindFor('sos', _cfg(sendControl: false), loggedIn: true), isNull);
      final on = _cfg(control: {
        'placements': {'sos': _row(true, 'banner')}
      });
      expect(AdControl.kindFor('sos', on, loggedIn: true), AdKind.banner);
    });

    test('the owner type choice is honoured; a type that does not fit -> none', () {
      final native = _cfg(control: {
        'placements': {'notes_home': _row(true, 'native')}
      });
      expect(AdPlacements.inline('notes_home', native, loggedIn: true), AdKind.native);
      expect(AdPlacements.banner('notes_home', native, loggedIn: true).allowed, isFalse);
      final wrong = _cfg(control: {
        'placements': {'notes_home': _row(true, 'interstitial')}
      });
      expect(AdControl.kindFor('notes_home', wrong, loggedIn: true), isNull);
      final off = _cfg(control: {
        'placements': {'notes_home': _row(false, 'banner')}
      });
      expect(AdPlacements.inline('notes_home', off, loggedIn: true), isNull);
      // unknown key: default deny
      expect(AdControl.kindFor('anything_else', _cfg(), loggedIn: true), isNull);
    });

    test('interstitials follow the switch; caps 3 min / server daily cap', () {
      final now = DateTime(2026, 11, 10, 12);
      AdDecision d(AdConfig c, {DateTime? last, int today = 0}) =>
          AdPlacements.interstitial('finance_after_export', c,
              loggedIn: true,
              now: now,
              firstUseDay: DateTime(2026, 11, 1),
              lastFullScreenAt: last,
              shownToday: today);
      expect(d(_cfg()).allowed, isTrue);
      expect(d(_cfg(), last: now.subtract(const Duration(seconds: 179))).reason, 'too_soon');
      expect(d(_cfg(), today: 6).reason, 'daily_cap');
      final off = _cfg(control: {
        'placements': {'finance_after_export': _row(false, 'interstitial')}
      });
      expect(d(off).allowed, isFalse);
    });

    test('rewarded spots go through the registry, not the old fence', () {
      AdDecision r(AdConfig c, String k) => AdRules.decide(
          kind: AdKind.rewarded,
          screen: k,
          config: c,
          now: DateTime(2026, 11, 10),
          loggedIn: true,
          userOptedIn: true);
      expect(r(_cfg(), 'train_live_unlock').allowed, isTrue);
      expect(r(_cfg(), 'security_scan').allowed, isTrue);
      expect(r(_cfg(plan: 'plus'), 'security_scan').allowed, isFalse);
      final off = _cfg(control: {
        'placements': {'security_scan': _row(false, 'rewarded')}
      });
      expect(r(off, 'security_scan').allowed, isFalse);
      // a safety screen stays fenced
      expect(r(_cfg(), 'sos').allowed, isFalse);
    });

    test('caps parse with floors', () {
      final c = _cfg(control: {
        'placements': {},
        'caps': {
          'interstitial_min_gap_sec': 5,
          'interstitial_daily_cap': 99,
          'list_native_every': 3,
          'train_free_minutes': 1
        }
      });
      expect(c.control.interstitialMinGapSec, 180);
      expect(c.control.interstitialDailyCap, 12);
      expect(c.control.listNativeEvery, 15);
      expect(c.control.trainFreeMinutes, 5);
    });
  });

  group('helpers', () {
    test('list native: one card every 15-20 rows, never after the last row', () {
      expect(AdControl.listNativeAfter(10, 15), isEmpty);
      expect(AdControl.listNativeAfter(15, 15), isEmpty);
      expect(AdControl.listNativeAfter(16, 15), [14]);
      expect(AdControl.listNativeAfter(40, 15), [14, 29]);
      expect(AdControl.listNativeAfter(41, 20), [19, 39]);
      expect(AdControl.listNativeAfter(40, 3), [14, 29]); // floor 15
    });

    test('train live: free for N minutes after one ad', () {
      final t0 = DateTime(2026, 11, 10, 9);
      expect(AdControl.trainWindowOpen(null, t0, 15), isFalse);
      expect(AdControl.trainWindowOpen(t0, t0.add(const Duration(minutes: 14)), 15), isTrue);
      expect(AdControl.trainWindowOpen(t0, t0.add(const Duration(minutes: 15)), 15), isFalse);
    });

    test('transition moments only for transition placements', () {
      AdExit.resetForTest();
      final got = <AdExitPlacement>[];
      AdExit.sink = got.add;
      expect(AdExit.transition(AdExitPlacement.photoAfterSave), isFalse);
      expect(AdExit.transition(AdExitPlacement.examAfterSubmit), isTrue);
      expect(got, [AdExitPlacement.examAfterSubmit]);
      AdExit.sink = null;
    });
  });

  test('part F: max 2 mediation SDKs, no startup ContentProvider, no new sensitive permission', () {
    final ci = File('../.github/workflows/android.yml').readAsStringSync();
    final adapters = RegExp(r'"com\.google\.ads\.mediation:(\w+):[0-9.]+"')
        .allMatches(ci)
        .map((m) => m.group(1))
        .toSet();
    expect(adapters, {'facebook', 'applovin'});
    for (final p in ['com.facebook.ads.AudienceNetworkContentProvider',
        'com.applovin.sdk.AppLovinInitProvider']) {
      expect(RegExp('provider android:name="${RegExp.escape(p)}"[^>]*tools:node="remove"')
          .hasMatch(ci), isTrue, reason: '$p must be removed');
    }
    expect(ci.contains('com.android.vending.CHECK_LICENSE" tools:node="remove"'), isTrue);
  });

  group('rewarded gate never blocks', () {
    Widget host(Widget Function(BuildContext) b) => MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Builder(builder: b)),
        );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AdRewardGate.debugTrainMinutes = () => 15;
    });
    tearDown(() {
      AdRewardGate.debugAvailable = null;
      AdRewardGate.debugShow = null;
      AdRewardGate.debugTrainMinutes = null;
    });

    testWidgets('no ad available (Premium / Plus / no fill) -> runs at once, no sheet',
        (t) async {
      AdRewardGate.debugAvailable = (_) async => false;
      var ran = 0;
      await t.pumpWidget(host((ctx) => TextButton(
          onPressed: () => AdRewardGate.run(ctx,
              placement: 'security_scan',
              grant: AdGateGrant.perUse,
              what: 'x',
              action: () => ran++),
          child: const Text('go'))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(ran, 1);
      expect(find.byKey(const ValueKey('ad-gate-sheet')), findsNothing);
    });

    testWidgets('once: watch -> runs, then free forever', (t) async {
      AdRewardGate.debugAvailable = (_) async => true;
      var shown = 0;
      AdRewardGate.debugShow = (_) async {
        shown++;
        return RewardOutcome.earned;
      };
      var ran = 0;
      await t.pumpWidget(host((ctx) => TextButton(
          onPressed: () => AdRewardGate.run(ctx,
              placement: 'security_unlock',
              grant: AdGateGrant.once,
              unlockId: 'scam',
              what: 'x',
              action: () => ran++),
          child: const Text('go'))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ad-gate-sheet')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ad-gate-watch')));
      await t.pumpAndSettle();
      expect((shown, ran), (1, 1));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ad-gate-sheet')), findsNothing);
      expect((shown, ran), (1, 2));
    });

    testWidgets('the ad fails to play -> the action still runs', (t) async {
      AdRewardGate.debugAvailable = (_) async => true;
      AdRewardGate.debugShow = (_) async => RewardOutcome.unavailable;
      var ran = 0;
      await t.pumpWidget(host((ctx) => TextButton(
          onPressed: () => AdRewardGate.run(ctx,
              placement: 'train_live_unlock',
              grant: AdGateGrant.window,
              what: 'x',
              action: () => ran++),
          child: const Text('go'))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ad-gate-watch')));
      await t.pumpAndSettle();
      expect(ran, 1);
    });

    testWidgets('"Not now" closes the sheet and does nothing', (t) async {
      AdRewardGate.debugAvailable = (_) async => true;
      var ran = 0;
      await t.pumpWidget(host((ctx) => TextButton(
          onPressed: () => AdRewardGate.run(ctx,
              placement: 'security_scan',
              grant: AdGateGrant.perUse,
              what: 'x',
              action: () => ran++),
          child: const Text('go'))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ad-gate-cancel')));
      await t.pumpAndSettle();
      expect(ran, 0);
      expect(find.byKey(const ValueKey('ad-gate-sheet')), findsNothing);
    });
  });
}
