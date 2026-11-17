// ads-guard (owner 17 Nov): NO ad of any kind while a call rings / runs, on
// SOS, Emergency, Safe Journey, Family Care, kids watch, Care Call, Quran,
// blood donor or any safety screen, never right after a call, and never any
// ad request (not even a test ad) for Premium / Plus / Business.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_block_context.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/ads_bridge.dart';
import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/ads/admob_sdk.dart';
import 'package:assisto/ads/app_open_gate.dart';
import 'package:assisto/ads/consent.dart';
import 'package:assisto/api.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/state.dart';

/// EVERY safety / call screen -> its file. Each one must hold the context
/// (`with AdBlockedState<Screen>`). A new safety screen goes on this list.
const safetyScreens = <String, String>{
  'EmergencyScreen': 'lib/screens/emergency_screen.dart',
  'EmergencyHubScreen': 'lib/screens/emergency_hub_screen.dart',
  'VoiceSosScreen': 'lib/screens/voice_sos_screen.dart',
  'SafetyScreen': 'lib/screens/safety_screen.dart',
  'SosAlarmScreen': 'lib/family_sos/sos_alarm_screen.dart',
  'SosSenderScreen': 'lib/family_sos/sos_sender_screen.dart',
  'SosTriggersScreen': 'lib/screens/sos_triggers_screen.dart',
  'SosLiveScreen': 'lib/screens/watchman/auto_guard_screen.dart',
  'FallDetectScreen': 'lib/screens/fall_detect_screen.dart',
  'SafeJourneyHubScreen': 'lib/screens/safe_journey/sj_hub_screen.dart',
  'JourneyLiveScreen': 'lib/screens/journey_live_screen.dart',
  'JourneyStartScreen': 'lib/screens/journey_start_screen.dart',
  'JourneySosScreen': 'lib/screens/journey_sos_screen.dart',
  'JourneyWatchScreen': 'lib/screens/journey_watch_screen.dart',
  'GuardianJourneyScreen': 'lib/screens/guardian_journey_screen.dart',
  'JourneyFakeCallScreen': 'lib/screens/journey_fake_call_screen.dart',
  'DestAlarmScreen': 'lib/screens/train/dest_alarm_screen.dart',
  'FamilyScreen': 'lib/screens/family_screen.dart',
  'FamilyV3Screen': 'lib/family_v3/family_v3_screen.dart',
  'FamilyAlertsScreen': 'lib/screens/family_alerts_screen.dart',
  'ElderWatchScreen': 'lib/eldercare/elder_watch_screen.dart',
  'ElderlyHomeScreen': 'lib/screens/elderly_home_screen.dart',
  'KidsWatchScreen': 'lib/screens/kids_watch/kids_watch_screen.dart',
  'SchoolModeChildScreen': 'lib/screens/kids_watch/school_mode_child_screen.dart',
  'KidAudioScreen': 'lib/screens/kid_audio/kid_audio_screen.dart',
  'KidsPlacesScreen': 'lib/screens/safe_journey/kids_corner.dart',
  'KidSchoolScreen': 'lib/screens/kid_school_screen.dart',
  'SjChildSchoolScreen': 'lib/screens/safe_journey/sj_child_school_screen.dart',
  'MissingHubScreen': 'lib/screens/missing/missing_hub_screen.dart',
  'CareCallScreen': 'lib/carecall/carecall_screen.dart',
  'CareCallNewScreen': 'lib/carecall/carecall_new_screen.dart',
  'CareCallRingScreen': 'lib/carecall/carecall_ring_screen.dart',
  'IncomingCallScreen': 'lib/push/incoming_call_screen.dart',
  'CircleCallScreen': 'lib/screens/circle_call_screen.dart',
  'CctvAlarmCallScreen': 'lib/screens/watchman/cctv_alarm_call_screen.dart',
  'QuranScreen': 'lib/screens/quran_screen.dart',
  'QuranReaderScreen': 'lib/screens/quran_screen.dart',
  'QuranLearnScreen': 'lib/quran_learn/quran_learn_screen.dart',
  'QuranLessonScreen': 'lib/quran_learn/quran_learn_screen.dart',
  'QuranLearnAboutScreen': 'lib/quran_learn/quran_learn_screen.dart',
  'BloodHubScreen': 'lib/screens/blood/blood_hub_screen.dart',
  'BloodDonorSetupScreen': 'lib/screens/blood/blood_donor_setup_screen.dart',
  'BloodRequestDetailScreen': 'lib/screens/blood/blood_request_detail_screen.dart',
  'BloodRequestFormScreen': 'lib/screens/blood/blood_request_form_screen.dart',
  'BloodBanksScreen': 'lib/screens/blood/blood_banks_screen.dart',
  'BloodThreadScreen': 'lib/screens/blood/blood_thread_screen.dart',
  'BloodThreadsScreen': 'lib/screens/blood/blood_threads_screen.dart',
  'BloodVerifyScreen': 'lib/screens/blood/blood_verify_screen.dart',
  'BloodSavedScreen': 'lib/screens/blood/blood_saved_screen.dart',
  'LostStolenScreen': 'lib/screens/lost_stolen_screen.dart',
  'MyLostPhoneScreen': 'lib/screens/my_lost_phone_screen.dart',
};

Map<String, dynamic> _cfg({String plan = 'free'}) {
  final paid = plan != 'free';
  return {
    'configured': false,
    'real_ids': false,
    'ads_enabled': !paid,
    'app_id': '',
    'units': {
      'app_open': AdIds.testAppOpen,
      'rewarded': AdIds.testRewarded,
      'banner': AdIds.testBanner,
      'interstitial': AdIds.testInterstitial,
      'native': AdIds.testNative,
    },
    'plan': plan,
    'paid': paid,
    'placements': {
      'app_open': !paid,
      'native_home': !paid,
      'banner': !paid,
      'interstitial': !paid,
      'rewarded': false,
    },
    'app_open_enabled': !paid,
    'rewarded_enabled': false,
    'appopen_min_gap_sec': 10800,
    'appopen_daily_cap': 6,
    'appopen_min_bg_sec': 30,
    'interstitial_min_gap_sec': 180,
    'interstitial_daily_cap': 6,
    'banner_screens': paid ? <String>[] : <String>['dictionary'],
    'interstitial_moments': paid ? <String>[] : <String>['photo_after_save'],
    'hero_enabled': !paid,
    'appopen_start_day': 1,
    'sponsors_enabled': !paid,
  };
}

class _Api extends ApiClient {
  _Api(this.cfg) {
    token = 't';
  }
  Map<String, dynamic> cfg;
  final paths = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    if (path == '/ads/config') return cfg;
    if (path.startsWith('/ads/slot')) {
      return {'placement': 'app_open', 'show': true, 'source': 'admob', 'reason': 'ok'};
    }
    if (path.startsWith('/payments/orders/')) return {'ok': true, 'status': 'paid'};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true, '_status': 200};
}

class _Full implements AdsBridge, InterstitialBridge {
  int appOpens = 0;
  int inters = 0;
  @override
  bool get linked => true;
  @override
  Future<bool> init() async => true;
  @override
  Future<bool> showAppOpen(String unitId) async {
    appOpens++;
    return true;
  }

  @override
  Future<bool> showInterstitial(String unitId, {required String placement}) async {
    inters++;
    return true;
  }

  @override
  Future<RewardOutcome> showRewarded(String unitId) async => RewardOutcome.unavailable;
  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
          {required String userId, required String customData}) async =>
      RewardOutcome.unavailable;
}

AppState _app(ApiClient api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Test', phone: '01999000000', email: '',
      autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

class _SafetyProbe extends StatefulWidget {
  const _SafetyProbe();
  @override
  State<_SafetyProbe> createState() => _SafetyProbeState();
}

class _SafetyProbeState extends State<_SafetyProbe>
    with AdBlockedState<_SafetyProbe> {
  @override
  Widget build(BuildContext context) => const Text('sos');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'ads_first_use_day': '2000-01-01'});
    AppEntry.reset();
    AdsService.instance.resetForTest();
    AdConsent.instance.resetForTest();
    AdBlockContext.resetForTest();
  });

  group('the context itself', () {
    test('screen hold, call, cooldown, plan', () {
      var now = DateTime(2026, 11, 17, 12);
      AdBlockContext.clock = () => now;
      expect(AdBlockContext.reason(), '');
      AdBlockContext.enter('SosScreen');
      expect(AdBlockContext.reason(), 'screen:SosScreen');
      expect(AdBlockContext.blockedNow, isTrue);
      expect(AdBlockContext.sdkAllowed, isFalse);
      AdBlockContext.leave('SosScreen');
      // right after: app-open / interstitial still blocked, a banner is not
      expect(AdBlockContext.reason(), 'cooldown');
      expect(AdBlockContext.blocked, isTrue);
      expect(AdBlockContext.blockedNow, isFalse);
      now = now.add(AdBlockContext.cooldown);
      expect(AdBlockContext.reason(), '');
      AdBlockContext.noteCall(true); // ringing / in a call
      expect(AdBlockContext.reason(), 'in_call');
      AdBlockContext.noteCall(false); // hung up
      expect(AdBlockContext.reason(), 'cooldown');
      now = now.add(const Duration(minutes: 3));
      AdBlockContext.callProbe = () => true; // call minimised to the bar
      expect(AdBlockContext.reason(), 'in_call');
      AdBlockContext.callProbe = () => throw StateError('x');
      expect(AdBlockContext.reason(), 'in_call'); // unsure -> no ad
      AdBlockContext.callProbe = () => false;
      AdBlockContext.planAllowsAds = false;
      expect(AdBlockContext.reason(), 'plan');
      expect(AdBlockContext.sdkAllowed, isFalse);
      AdBlockContext.planAllowsAds = null; // config not loaded yet
      expect(AdBlockContext.sdkAllowed, isFalse);
      AdBlockContext.planAllowsAds = true;
      expect(AdBlockContext.sdkAllowed, isTrue);
    });

    test('nested holds: blocked until the LAST one leaves', () {
      AdBlockContext.enter('A');
      AdBlockContext.enter('A');
      AdBlockContext.enter('B');
      AdBlockContext.leave('A');
      AdBlockContext.leave('B');
      expect(AdBlockContext.blockedNow, isTrue);
      AdBlockContext.leave('A');
      expect(AdBlockContext.holders, isEmpty);
    });
  });

  group('static: every safety / call screen holds the context', () {
    for (final e in safetyScreens.entries) {
      test(e.key, () {
        final src = File(e.value).readAsStringSync();
        final re = RegExp('extends State<${e.key}>\\s*with[^{]*AdBlockedState<${e.key}>');
        expect(re.hasMatch(src), isTrue,
            reason: '${e.value}: ${e.key} must use AdBlockedState');
      });
    }

    test('every ad load goes through the SDK gate that checks the context', () {
      final sdk = File('lib/ads/admob_sdk.dart').readAsStringSync();
      expect('AdBlockContext.sdkAllowed'.allMatches(sdk).length,
          greaterThanOrEqualTo(3)); // ensureReady (x2) + request
    });
  });

  group('SDK: no init, no request for a paid / unknown plan or blocked context',
      () {
    test('request() refuses', () async {
      AdmobSdk.resetForTest();
      for (final plan in <bool?>[false, null]) {
        AdBlockContext.planAllowsAds = plan;
        expect(await AdmobSdk.ensureReady(), isFalse);
        expect(() => AdmobSdk.request(), throwsStateError);
      }
      AdBlockContext.planAllowsAds = true;
      AdBlockContext.enter('IncomingCallScreen');
      expect(await AdmobSdk.ensureReady(), isFalse);
      expect(() => AdmobSdk.request(), throwsStateError);
      AdBlockContext.leave('IncomingCallScreen');
    });
  });

  group('service: full-screen ads', () {
    Future<_Full> attach(_Api api) async {
      final f = _Full();
      AdsService.instance.bridge = f;
      AdsService.instance.interstitials = f;
      AdsService.instance.debugNativeSuppressed = () async => false;
      AdsService.instance.debugOnline = () async => true;
      AdsService.instance.attachForTest(_app(api));
      AdBlockContext.callProbe = () => false; // test: no CallRuntime
      await AdsService.instance.refreshConfig(force: true);
      return f;
    }

    Future<void> tryAll(_Full f) async {
      await AdsService.instance
          .maybeShowAppOpen(resumed: true, backgroundFor: const Duration(minutes: 5));
      await AdsService.instance.maybeInterstitial('photo_after_save');
    }

    testWidgets('Free + nothing blocking: ads may show (control)', (tester) async {
      final f = await attach(_Api(_cfg()));
      expect(AdBlockContext.planAllowsAds, isTrue);
      await AdsService.instance.maybeInterstitial('photo_after_save');
      expect(f.inters, 1);
    });

    testWidgets('a call ringing / going on: nothing', (tester) async {
      final f = await attach(_Api(_cfg()));
      AdBlockContext.noteCall(true);
      await tryAll(f);
      expect(f.appOpens + f.inters, 0);
      expect(await AdsService.instance.rewardedAvailable(_app(_Api(_cfg()))), isFalse);
    });

    testWidgets('right after a call (return to the app): nothing', (tester) async {
      final f = await attach(_Api(_cfg()));
      AdBlockContext.noteCall(true);
      AdBlockContext.noteCall(false);
      await tryAll(f);
      expect(f.appOpens + f.inters, 0);
    });

    testWidgets('a safety screen is open: nothing', (tester) async {
      final f = await attach(_Api(_cfg()));
      AdBlockContext.enter('SosAlarmScreen');
      await tryAll(f);
      expect(f.appOpens + f.inters, 0);
      AdBlockContext.leave('SosAlarmScreen');
    });

    testWidgets('opened by an SOS / alarm / notification intent: no app-open',
        (tester) async {
      final f = await attach(_Api(_cfg()));
      for (final kind in ['sos', 'alarm', 'notification', 'call', 'safety_alert']) {
        AppEntry.mark(kind);
        await AdsService.instance
            .maybeShowAppOpen(resumed: true, backgroundFor: const Duration(minutes: 5));
        AppEntry.reset();
      }
      expect(f.appOpens, 0);
    });

    for (final plan in ['premium', 'plus', 'business']) {
      testWidgets('$plan: no ad, the SDK is never allowed', (tester) async {
        final api = _Api(_cfg(plan: plan));
        final f = await attach(api);
        expect(AdBlockContext.planAllowsAds, isFalse);
        expect(AdBlockContext.sdkAllowed, isFalse);
        expect(await AdmobSdk.ensureReady(), isFalse);
        await tryAll(f);
        expect(f.appOpens + f.inters, 0);
        expect(api.paths.where((p) => p.startsWith('/ads/slot')), isEmpty);
      });
    }

    testWidgets('upgrade mid-session: ads stop at once, stay stopped',
        (tester) async {
      final api = _Api(_cfg());
      final f = await attach(api);
      expect(AdBlockContext.sdkAllowed, isTrue);
      api.cfg = _cfg(plan: 'plus');
      // the Play purchase is verified by our server
      final r = await ApiPaymentsBackend(api)
          .playVerify(kind: 'subs', productId: 'plus', purchaseToken: 'tok');
      expect(r.ok, isTrue);
      expect(AdBlockContext.sdkAllowed, isFalse); // immediately
      expect(AdBlockContext.blockedNow, isTrue); // slots hide at once
      await tester.pump();
      await AdsService.instance.refreshConfig();
      expect(AdsService.instance.config.paid, isTrue);
      expect(AdBlockContext.planAllowsAds, isFalse);
      await tryAll(f);
      expect(f.appOpens + f.inters, 0);
    });
  });

  group('widgets', () {
    testWidgets('an ad slot hides while a safety screen is open', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(
            body: AdBlockGate(child: SizedBox(key: ValueKey('ad'), height: 50))),
      ));
      expect(find.byKey(const ValueKey('ad')), findsOneWidget);
      nav.currentState!.push(MaterialPageRoute(builder: (_) => const _SafetyProbe()));
      await tester.pumpAndSettle();
      expect(AdBlockContext.holders, contains('_SafetyProbe'));
      expect(find.byKey(const ValueKey('ad'), skipOffstage: false), findsNothing);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(AdBlockContext.holders, isEmpty);
      // banners come back (only full-screen ads wait for the cooldown)
      expect(find.byKey(const ValueKey('ad')), findsOneWidget);
      expect(AdBlockContext.blocked, isTrue);
    });

    testWidgets('an ad slot hides during a call and on a plan change',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: AdBlockGate(child: SizedBox(key: ValueKey('ad'), height: 50)))));
      AdBlockContext.noteCall(true);
      await tester.pump();
      expect(find.byKey(const ValueKey('ad')), findsNothing);
      AdBlockContext.noteCall(false);
      await tester.pump();
      expect(find.byKey(const ValueKey('ad')), findsOneWidget);
      AdBlockContext.planMaybeChanged();
      await tester.pump();
      expect(find.byKey(const ValueKey('ad')), findsNothing);
    });
  });
}
