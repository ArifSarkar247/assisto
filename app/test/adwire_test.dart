// adwire — OWNER FINAL ADS ORDER (10 Nov 03:45, part D): the four default-ON
// placements that were registered but not wired, now wired through the
// placement registry (lib/ads/ad_control.dart), Free users only, Premium /
// Plus never:
//  1. ai_chat_unlock   — the AI chat "Watch N ads for 1 answer" sheet
//  2. discover_native  — the Discover AdMob slot reads the registry key
//  3. after_call_review — native card on the call-ended rating row; never
//     after SOS / emergency / Care Call, < 10 s, missed / declined / dropped
//  4. city_more_routes — "More routes (Google)" on City Service results:
//     one rewarded ad unlocks ONE Google transit request (Premium / Plus no
//     ad); over the Google budget the button is simply not there.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_control.dart';
import 'package:assisto/ads/ad_reward_gate.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/ad_spot_card.dart';
import 'package:assisto/ads/ads_bridge.dart' show RewardOutcome;
import 'package:assisto/ads/after_call_ad.dart';
import 'package:assisto/ads/hero_ad.dart';
import 'package:assisto/ads/sponsor_api.dart';
import 'package:assisto/api.dart';
import 'package:assisto/calls/call_controller.dart' show CallEndReason;
import 'package:assisto/calls/call_rating.dart';
import 'package:assisto/city/city_offline.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/credits_out_sheet.dart';
import 'package:assisto/screens/city/city_service_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/home_suggestions.dart';
import 'package:assisto/widgets/rewarded_ad_sheet.dart';

import 'fake_api.dart';

Map<String, dynamic> _row(bool on, String type) => {'on': on, 'type': type};

AdConfig _cfg({bool paid = false, String plan = 'free', Map<String, Map<String, dynamic>> rows = const {}}) =>
    AdConfig.fromJson({
      'plan': plan,
      'paid': paid,
      'ads_enabled': !paid,
      'placements': {'banner': true, 'interstitial': true},
      'rewarded_enabled': true,
      'control': {
        'placements': {
          for (final s in AdControl.spots) s.key: _row(s.defaultOn, s.defaultTypeId),
          ...rows,
        },
      },
    });

AdDecision _rewarded(String screen, AdConfig cfg) => AdRules.decide(
    kind: AdKind.rewarded,
    screen: screen,
    config: cfg,
    now: DateTime(2026, 11, 10, 12),
    loggedIn: true,
    userOptedIn: true);

Widget _app(Widget home, {AppState? state, String lang = 'en'}) {
  final s = state ??
      (AppState()
        ..api = FakeApi()
        ..user = AppUser(id: 1, name: 'Me', phone: '0', email: '', autonomyLevel: 2, language: lang)
        ..loading = false);
  return ChangeNotifierProvider<AppState>.value(
      value: s,
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ));
}

String _code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ------------------------------------------------------------ 1. AI chat
  group('1. ai_chat_unlock', () {
    test('AI answer screens use ai_chat_unlock; others keep credits; old server keeps credits', () {
      for (final s in ['ai_chat', 'home', 'chat_photo', 'world']) {
        expect(CreditsOut.adPlacement(s, registry: true), 'ai_chat_unlock', reason: s);
        expect(CreditsOut.adPlacement(s, registry: false), 'credits', reason: s);
      }
      for (final s in ['jobs', 'credits', 'photo_studio']) {
        expect(CreditsOut.adPlacement(s, registry: true), 'credits', reason: s);
      }
    });

    test('Free + switch on -> rewarded allowed; switch off, Premium, Plus -> never', () {
      expect(_rewarded('ai_chat_unlock', _cfg()).allowed, isTrue);
      expect(_rewarded('ai_chat_unlock', _cfg(rows: {'ai_chat_unlock': _row(false, 'rewarded')})).allowed,
          isFalse);
      expect(_rewarded('ai_chat_unlock', _cfg(paid: true, plan: 'premium')).allowed, isFalse);
      expect(_rewarded('ai_chat_unlock', _cfg(paid: true, plan: 'plus')).allowed, isFalse);
      // a rewarded ad is always the user's own tap
      expect(
          AdRules.decide(
                  kind: AdKind.rewarded,
                  screen: 'ai_chat_unlock',
                  config: _cfg(),
                  now: DateTime(2026, 11, 10),
                  loggedIn: true)
              .allowed,
          isFalse);
    });

    test('the credits-finished sheet plays its ad under the registry placement', () {
      final src = _code('lib/payments/credits_out_sheet.dart');
      expect('CreditsOut.adPlacementNow(widget.screen)'.allMatches(src).length, 2,
          reason: 'availability check AND the sheet both use the placement');
      final sheet = _code('lib/widgets/rewarded_ad_sheet.dart');
      expect(sheet.contains('screen: widget.placement'), isTrue);
    });

    testWidgets('the sheet asks the server for an ai_chat_unlock ticket (owner switch re-checked)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _TicketApi();
      RewardedAdSheet.debugBackend = ApiSponsorBackend(api);
      addTearDown(() => RewardedAdSheet.debugBackend = null);
      final state = AppState()
        ..api = api
        ..user = AppUser(id: 1, name: 'Me', phone: '0', email: '', autonomyLevel: 2, language: 'en')
        ..loading = false;
      await tester.pumpWidget(_app(
          const Scaffold(body: SingleChildScrollView(child: RewardedAdSheet(placement: 'ai_chat_unlock'))),
          state: state));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(tester.element(find.byType(RewardedAdSheet)));
      await tester.tap(find.text(t.adWatchNow));
      await tester.pumpAndSettle();
      expect(api.posts.single.$1, '/credits/rewarded/ticket');
      expect(api.posts.single.$2, {'placement': 'ai_chat_unlock'});
      // switched off on the server -> the honest note, no ad
      expect(find.text('No ads here right now.'), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ 2. Discover
  group('2. discover_native', () {
    test('reads the registry key with the registry rules', () {
      // an old server (no control at all) = the registry default (ON, native)
      expect(discoverAdSwitchOn(null), isTrue);
      expect(discoverAdSwitchOn({'units': {}}), isTrue);
      // control without the key = OFF (default deny), never the old fallback
      expect(discoverAdSwitchOn({'control': {'placements': {}}}), isFalse);
      expect(discoverAdSwitchOn({'control': {}}), isFalse);
      expect(
          discoverAdSwitchOn({
            'control': {'placements': {'discover_native': _row(true, 'native')}}
          }),
          isTrue);
      expect(
          discoverAdSwitchOn({
            'control': {'placements': {'discover_native': _row(false, 'native')}}
          }),
          isFalse);
      // a type this slot cannot draw = no ad
      expect(
          discoverAdSwitchOn({
            'control': {'placements': {'discover_native': _row(true, 'banner')}}
          }),
          isFalse);
      expect(AdControl.spot(HomeSuggestions.adPlacement)!.defaultOn, isTrue);
    });
  });

  // ------------------------------------------------------------ 3. after call
  group('3. after_call_review', () {
    test('never after SOS / emergency / Care Call, < 10 s, missed or failed calls', () {
      const ok = Duration(seconds: 42);
      expect(afterCallAdAllowed(origin: 'circle', talkTime: ok, endReason: CallEndReason.hangup), isTrue);
      for (final o in ['sos', 'emergency', 'care_call', 'kid_audio', 'SOS']) {
        expect(afterCallAdAllowed(origin: o, talkTime: ok, endReason: CallEndReason.hangup), isFalse,
            reason: o);
      }
      expect(
          afterCallAdAllowed(
              origin: 'circle', talkTime: const Duration(seconds: 9), endReason: CallEndReason.hangup),
          isFalse);
      expect(afterCallAdAllowed(origin: 'circle', talkTime: null, endReason: CallEndReason.hangup), isFalse);
      for (final r in [
        CallEndReason.noAnswer,
        CallEndReason.declined,
        CallEndReason.busy,
        CallEndReason.canceled,
        CallEndReason.failed,
        CallEndReason.lost,
        CallEndReason.offline,
        CallEndReason.none,
      ]) {
        expect(afterCallAdAllowed(origin: 'circle', talkTime: ok, endReason: r), isFalse, reason: '$r');
      }
    });

    test('Care Call and a child emergency listen-in pass their origin; the call screen gates the card', () {
      expect(_code('lib/carecall/carecall_screen.dart').contains("origin: 'care_call'"), isTrue);
      expect(_code('lib/calls/kid_audio_child.dart').contains("origin: 'kid_audio'"), isTrue);
      final call = _code('lib/screens/circle_call_screen.dart');
      expect('AfterCallReviewAd('.allMatches(call).length, 1);
      expect(call.contains('afterCallAdAllowed('), isTrue);
      // the card sits only in the ENDED actions (after the rating row)
      final ended = call.indexOf('Widget _endedActions(');
      expect(ended, greaterThan(0));
      expect(call.indexOf('AfterCallReviewAd('), greaterThan(ended));
      // the screen waits for the ad (loaded or failed) before closing
      expect(call.contains('_closeAfterRating()'), isTrue);
    });

    Future<List<bool>> pumpCard(WidgetTester tester, AdConfig cfg, _Bridge bridge) async {
      final got = <bool>[];
      AdSpotCard.debugBridge = bridge;
      AdSpotCard.debugLoadConfig = () async => cfg;
      addTearDown(() {
        AdSpotCard.debugBridge = null;
        AdSpotCard.debugLoadConfig = null;
      });
      await tester.pumpWidget(_app(Scaffold(body: AfterCallReviewAd(onResult: got.add))));
      await tester.pumpAndSettle();
      return got;
    }

    testWidgets('Free + switch on -> the native card shows and reports true', (tester) async {
      final b = _Bridge();
      final got = await pumpCard(tester, _cfg(), b);
      expect(got, [true]);
      expect(b.loads, 1);
      expect(find.byKey(const ValueKey('ad-spot-after_call_review')), findsOneWidget);
    });

    testWidgets('Premium / Plus / switched off -> no load, reports false (screen closes)', (tester) async {
      for (final cfg in [
        _cfg(paid: true, plan: 'premium'),
        _cfg(paid: true, plan: 'plus'),
        _cfg(rows: {'after_call_review': _row(false, 'native')}),
      ]) {
        final b = _Bridge();
        final got = await pumpCard(tester, cfg, b);
        expect(got, [false]);
        expect(b.loads, 0);
        expect(find.byKey(const ValueKey('ad-spot-after_call_review')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('no fill -> reports false, takes no space', (tester) async {
      final b = _Bridge(fill: false);
      final got = await pumpCard(tester, _cfg(), b);
      expect(got, [false]);
      expect(find.byKey(const ValueKey('ad-spot-after_call_review')), findsNothing);
    });
  });

  // ------------------------------------------------------------ 4. City
  group('4. city_more_routes', () {
    test('Free + switch on -> rewarded; Premium / Plus / off -> no ad', () {
      expect(_rewarded('city_more_routes', _cfg()).allowed, isTrue);
      expect(_rewarded('city_more_routes', _cfg(paid: true, plan: 'premium')).allowed, isFalse);
      expect(_rewarded('city_more_routes', _cfg(paid: true, plan: 'plus')).allowed, isFalse);
      expect(_rewarded('city_more_routes', _cfg(rows: {'city_more_routes': _row(false, 'rewarded')})).allowed,
          isFalse);
    });

    const here = (lat: 23.8075, lon: 90.3670); // sample point
    const to = (name: 'Motijheel', address: '', lat: 23.7284, lng: 90.4205);

    Future<(_TransitApi, AppLocalizations)> pumpCity(WidgetTester tester, {bool budget = true}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      final api = _TransitApi(budget: budget);
      final s = AppState()
        ..api = api
        ..user = AppUser(id: 1, name: 'Me', phone: '0', email: '', autonomyLevel: 2, language: 'en')
        ..locale = const Locale('en')
        ..loading = false;
      final screen = CityServiceScreen(
          debugHere: here,
          debugTo: to,
          debugSimple: false,
          store: CityStore(files: MemoryCityFiles()),
          debugNow: DateTime(2026, 11, 9, 14, 30));
      await tester.pumpWidget(_app(screen, state: s));
      await tester.pumpAndSettle();
      return (api, AppLocalizations.of(tester.element(find.byType(CityServiceScreen))));
    }

    Finder list() =>
        find.descendant(of: find.byKey(const ValueKey('city_list')), matching: find.byType(Scrollable)).first;

    tearDown(() {
      AdRewardGate.debugAvailable = null;
      AdRewardGate.debugShow = null;
    });

    testWidgets('Free: one rewarded ad, then ONE Google request; the routes show', (tester) async {
      final shown = <String>[];
      AdRewardGate.debugAvailable = (_) async => true;
      AdRewardGate.debugShow = (p) async {
        shown.add(p);
        return RewardOutcome.earned;
      };
      final (api, t) = await pumpCity(tester);
      final btn = find.byKey(const ValueKey('city_more_routes'));
      await tester.scrollUntilVisible(btn, 300, scrollable: list());
      expect(find.text(t.adwireMoreRoutesGoogle), findsOneWidget);
      expect(api.transitCalls, 0, reason: 'nothing is asked before the tap');
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ad-gate-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ad-gate-watch')));
      await tester.pumpAndSettle();
      expect(shown, ['city_more_routes']);
      expect(api.transitCalls, 1);
      expect(find.byKey(const ValueKey('city_cmp_google_0'), skipOffstage: false), findsOneWidget);
      expect(find.byKey(const ValueKey('city_more_routes')), findsNothing);
    });

    testWidgets('closing the ad sheet asks Google nothing', (tester) async {
      AdRewardGate.debugAvailable = (_) async => true;
      AdRewardGate.debugShow = (_) async => RewardOutcome.earned;
      final (api, _) = await pumpCity(tester);
      final btn = find.byKey(const ValueKey('city_more_routes'));
      await tester.scrollUntilVisible(btn, 300, scrollable: list());
      await tester.tap(btn);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ad-gate-cancel')));
      await tester.pumpAndSettle();
      expect(api.transitCalls, 0);
    });

    testWidgets('Premium / Plus (no rewarded ad offered): the routes come with no ad', (tester) async {
      var showed = 0;
      AdRewardGate.debugAvailable = (_) async => false; // paid plan -> rewardedAvailable false
      AdRewardGate.debugShow = (_) async {
        showed++;
        return RewardOutcome.earned;
      };
      final (api, _) = await pumpCity(tester);
      final btn = find.byKey(const ValueKey('city_more_routes'));
      await tester.scrollUntilVisible(btn, 300, scrollable: list());
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ad-gate-sheet')), findsNothing);
      expect(showed, 0);
      expect(api.transitCalls, 1);
    });

    testWidgets('Google budget over -> no button, no ad, no limit message', (tester) async {
      AdRewardGate.debugAvailable = (_) async => true;
      final (api, t) = await pumpCity(tester, budget: false);
      await tester.drag(list(), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('city_more_routes'), skipOffstage: false), findsNothing);
      expect(find.text(t.adwireMoreRoutesGoogle, skipOffstage: false), findsNothing);
      expect(api.transitCalls, 0);
      expect(api.peeks, greaterThan(0));
    });
  });
}

class _TicketApi extends ApiClient {
  _TicketApi() {
    token = 't';
  }
  final posts = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/ads/wallet') {
      return {
        'balance_credits': 0,
        'ads_per_answer': 3,
        'caps': {
          'rewarded': {'cap': 5, 'used': 0, 'remaining': 5}
        },
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    return {'ok': false, 'reason': 'placement_off', 'msg': 'No ads here right now.'};
  }
}

class _TransitApi extends FakeApi {
  _TransitApi({required this.budget}) : super(lang: 'en');
  final bool budget;
  int transitCalls = 0;
  int peeks = 0;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/maps/transit?peek=')) {
      peeks++;
      return {'state': budget ? 'ready' : 'none'};
    }
    if (path.startsWith('/maps/transit')) transitCalls++;
    return super.getJson(path);
  }
}

class _Handle implements HeroAdHandle {
  @override
  bool get hasVideo => false;
  @override
  Widget view() => const SizedBox(height: 80, child: Text('sample ad'));
  @override
  void dispose() {}
}

class _Bridge implements HeroAdBridge {
  _Bridge({this.fill = true});
  final bool fill;
  int loads = 0;
  @override
  bool get linked => true;
  @override
  Future<HeroAdHandle?> load(String unitId,
      {required bool startMuted, HeroAdLook? look, HeroAdSize size = HeroAdSize.compact}) async {
    loads++;
    return fill ? _Handle() : null;
  }
}
