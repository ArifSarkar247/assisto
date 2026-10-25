// h1-home: home ad hero rules + widget (Free only, "Ad" label, collapses on
// focus, no fill -> logo block, one AdMob ad on home), ad sound rules, the
// home welcome without suggestion questions, and image in chat (on-device
// honest state, Profit-Guard funding: pool / SSV-verified ads / credits,
// face-ID refusal, no endless spinner).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/hero_ad.dart';
import 'package:assisto/chat_vision/chat_photo.dart';
import 'package:assisto/chat_vision/cv_backend.dart';
import 'package:assisto/chat_vision/cv_controller.dart';
import 'package:assisto/chat_vision/on_device_vision.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/photo_studio/ps_ads.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/home_hero.dart';

import 'fake_api.dart';
import 'h1_home_fakes.dart';

Widget _app(Widget child, {AppState? state}) {
  final s = state ?? AppState();
  if (state == null) {
    s.api = FakeApi(lang: 'en');
    s.user = AppUser(
        id: 1, name: 'Arif', phone: '01700000000', email: '',
        autonomyLevel: 2, language: 'en');
    s.locale = const Locale('en');
    s.loading = false;
  }
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: Scaffold(body: child),
    ),
  );
}

AppLocalizations _t(WidgetTester tester, Type of) =>
    AppLocalizations.of(tester.element(find.byType(of).first));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  // let the hero's AnimatedSwitcher finish its cross-fade
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

const _logo = Text('LOGO BLOCK', key: ValueKey('logo'));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HomeHero.debugReset();
    HomeAdGuard.heroShowing.value = false;
  });

  // ------------------------------------------------------------- pure rules
  group('hero config + rules', () {
    test('parse: paid never, muted by default, refresh >= 60', () {
      final free = HeroAdConfig.fromJson(heroConfig());
      expect(free.enabled, isTrue);
      expect(free.startMuted, isTrue);
      final paid = HeroAdConfig.fromJson({...heroConfig(), 'hero_enabled': true, 'plan': 'business'});
      expect(paid.enabled, isFalse);
      expect(HeroAdConfig.fromJson({...heroConfig(), 'hero_refresh_sec': 5}).refreshSec, 60);
      expect(HeroAdConfig.fromJson({...heroConfig()}..remove('hero_start_muted')).startMuted,
          isTrue);
      expect(HeroAdConfig.fromJson(heroConfig(muted: false)).startMuted, isFalse);
      expect(HeroAdConfig.fromJson(null).enabled, isFalse);
    });

    test('unit: real only when configured + same app id; else the Google test unit', () {
      final c = HeroAdConfig.fromJson({
        ...heroConfig(),
        'configured': true,
        'app_id': 'ca-app-pub-1~2',
        'units': {'native': 'ca-app-pub-1/3'}
      });
      expect(c.unit(builtAppId: 'ca-app-pub-1~2', testMode: false), 'ca-app-pub-1/3');
      expect(c.unit(builtAppId: 'other', testMode: false), HeroAdIds.testNative);
      expect(c.unit(builtAppId: 'other', testMode: true), HeroAdIds.testNative);
    });

    HeroDecision d({
      HeroAdConfig? config,
      String screen = 'home',
      bool collapsed = false,
      bool chat = false,
      bool linked = true,
      double h = 300,
    }) =>
        HeroAdRules.decide(
            config: config ?? HeroAdConfig.fromJson(heroConfig()),
            screen: screen,
            loggedIn: true,
            collapsed: collapsed,
            chatStarted: chat,
            linked: linked,
            slotHeight: h);

    test('decide: every closed state', () {
      expect(d().allowed, isTrue);
      expect(d(config: HeroAdConfig.fromJson(heroConfig(plan: 'premium'))).reason, 'paid_plan');
      expect(d(config: HeroAdConfig.fromJson(heroConfig(enabled: false))).reason, 'disabled');
      for (final s in ['voice_sos', 'safety', 'journey', 'unknown', 'circle_call']) {
        expect(d(screen: s).reason, 'blocked_screen', reason: s);
      }
      expect(d(collapsed: true).reason, 'collapsed');
      expect(d(chat: true).reason, 'chat_started');
      expect(d(linked: false).reason, 'not_linked');
      expect(d(h: 120).reason, 'no_room');
    });

    test('refresh never faster than AdMob', () {
      expect(HeroAdRules.refreshEvery(const HeroAdConfig(refreshSec: 10)).inSeconds, 60);
      expect(HeroAdRules.refreshEvery(const HeroAdConfig(refreshSec: 120)).inSeconds, 120);
    });

    test('sound: full-screen ads with sound, hero video muted by flag', () {
      expect(AdSound.startMuted(AdFormat.rewarded), isFalse);
      expect(AdSound.startMuted(AdFormat.interstitial), isFalse);
      expect(AdSound.startMuted(AdFormat.appOpen), isFalse);
      expect(AdSound.startMuted(AdFormat.heroNative), isTrue);
      expect(AdSound.startMuted(AdFormat.heroNative, heroStartMuted: false), isFalse);
      expect(AdSound.appMuted, isFalse);
    });
  });

  // ------------------------------------------------------------- hero widget
  group('HomeHero widget', () {
    Widget hero(FakeHeroBridge b, Map<String, dynamic> cfg,
            {bool collapsed = false, double h = 400}) =>
        ListView(children: [
          HomeHero(
              fallback: _logo,
              collapsed: collapsed,
              availableHeight: h,
              bridge: b,
              loadConfig: () async => cfg,
              isHomeVisible: () => true),
        ]);

    testWidgets('Free + flag ON + fill -> native ad with "Ad" label, muted, guard set',
        (tester) async {
      final b = FakeHeroBridge();
      await tester.pumpWidget(_app(hero(b, heroConfig())));
      await _settle(tester);
      expect(find.byKey(const ValueKey('fake-native-ad')), findsOneWidget);
      expect(find.text(_t(tester, HomeHero).h1AdLabel), findsOneWidget);
      expect(find.text(_t(tester, HomeHero).h1HeroMutedHint), findsOneWidget);
      expect(find.byKey(const ValueKey('logo')), findsNothing);
      expect(b.lastStartMuted, isTrue);
      expect(HomeAdGuard.heroShowing.value, isTrue);
      // the ad box never exceeds the room it has
      final box = tester.getSize(find.byKey(const ValueKey('fake-native-ad')));
      expect(box.height, lessThanOrEqualTo(340));
    });

    testWidgets('collapses on input focus -> logo block, ad disposed, guard cleared',
        (tester) async {
      final b = FakeHeroBridge();
      await tester.pumpWidget(_app(hero(b, heroConfig())));
      await _settle(tester);
      await tester.pumpWidget(_app(hero(b, heroConfig(), collapsed: true)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('logo')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-native-ad')), findsNothing);
      expect(b.handles.single.disposed, isTrue);
      expect(HomeAdGuard.heroShowing.value, isFalse);
    });

    testWidgets('Premium/Business never load an ad', (tester) async {
      for (final plan in ['premium', 'business']) {
        final b = FakeHeroBridge();
        await tester.pumpWidget(_app(hero(b, heroConfig(plan: plan))));
        await _settle(tester);
        expect(b.loads, 0, reason: plan);
        expect(find.byKey(const ValueKey('logo')), findsOneWidget);
      }
    });

    testWidgets('no fill / not linked / flag off / no room / offline -> logo block',
        (tester) async {
      final cases = <(FakeHeroBridge, Map<String, dynamic>, double)>[
        (FakeHeroBridge(fill: false), heroConfig(), 400),
        (FakeHeroBridge(linkedValue: false), heroConfig(), 400),
        (FakeHeroBridge(), heroConfig(enabled: false), 400),
        (FakeHeroBridge(), heroConfig(), 150),
      ];
      for (final (b, cfg, h) in cases) {
        await tester.pumpWidget(_app(hero(b, cfg, h: h)));
        await _settle(tester);
        expect(find.byKey(const ValueKey('logo')), findsOneWidget);
        expect(find.byKey(const ValueKey('fake-native-ad')), findsNothing);
        expect(HomeAdGuard.heroShowing.value, isFalse);
      }
      // offline: config throws
      await tester.pumpWidget(_app(ListView(children: [
        HomeHero(
            fallback: _logo,
            bridge: FakeHeroBridge(),
            loadConfig: () async => throw Exception('offline'),
            isHomeVisible: () => true),
      ])));
      await _settle(tester);
      expect(find.byKey(const ValueKey('logo')), findsOneWidget);
    });

    testWidgets('never when home is not the visible route (a safety screen on top)',
        (tester) async {
      final b = FakeHeroBridge();
      await tester.pumpWidget(_app(ListView(children: [
        HomeHero(
            fallback: _logo,
            availableHeight: 400,
            bridge: b,
            loadConfig: () async => heroConfig(),
            isHomeVisible: () => false),
      ])));
      await _settle(tester);
      expect(b.loads, 0);
      expect(find.byKey(const ValueKey('logo')), findsOneWidget);
    });

    testWidgets('owner flag OFF for muted -> video starts with sound', (tester) async {
      final b = FakeHeroBridge();
      await tester.pumpWidget(_app(hero(b, heroConfig(muted: false))));
      await _settle(tester);
      expect(b.lastStartMuted, isFalse);
      expect(find.text(_t(tester, HomeHero).h1HeroMutedHint), findsNothing);
    });
  });

  // ------------------------------------------------------------- home welcome
  testWidgets('home thread welcome: logo block, no suggestion questions, attach button',
      (tester) async {
    await tester.pumpWidget(_app(AgentThreadScreen(
        debugSeed: const [], heroBuilder: (_, block, collapsed, h) => block)));
    await _settle(tester);
    final t = _t(tester, AgentThreadScreen);
    expect(find.text(t.welcomeHeadline), findsOneWidget);
    expect(find.text(t.suggestionToday), findsNothing);
    expect(find.text(t.suggestionSpendMonth), findsNothing);
    expect(find.byTooltip(t.h1AttachPhoto), findsOneWidget);
  });

  // ------------------------------------------------------------- image in chat
  group('on-device answer', () {
    test('kind detection', () {
      expect(OnDeviceAnswer.from(kMedicineReading).kind, PhotoKind.medicine);
      expect(
          OnDeviceAnswer.from(const OnDeviceReading(
                  status: OnDeviceStatus.ok, text: 'DESCO Total amount due BDT 850'))
              .kind,
          PhotoKind.bill);
      expect(
          OnDeviceAnswer.from(const OnDeviceReading(
                  status: OnDeviceStatus.ok, labels: ['Plant', 'Leaf']))
              .kind,
          PhotoKind.plant);
      expect(const UnavailableOnDeviceVision().available, isFalse);
    });
  });

  group('CvController', () {
    CvController ctl(FakeCvBackend b,
            {PhotoAdBridge? ads, OnDeviceReading r = OnDeviceReading.unavailable}) =>
        CvController(
            backend: b,
            bytes: kTinyPng,
            question: 'What medicine is this?',
            onDevice: FakeOnDevice(r),
            ads: ads ?? FakePhotoAds(onShown: (_) => b.ssv()),
            pollEvery: Duration.zero,
            pollTries: 3);

    test('on-device unavailable is honest; quote loaded', () async {
      final c = ctl(FakeCvBackend());
      await c.start();
      expect(c.phase, CvPhase.ready);
      expect(c.reading.status, OnDeviceStatus.unavailable);
      expect(c.quote.option('ads')!.ads, 2);
      expect(c.quote.option('credits')!.credits, 3);
    });

    test('free: 2 SSV-verified ads -> answer; image sent once', () async {
      final b = FakeCvBackend();
      final c = ctl(b, r: kMedicineReading);
      await c.start();
      expect(c.local!.kind, PhotoKind.medicine);
      await c.requestDetailed('ads');
      expect(c.phase, CvPhase.done);
      expect(b.verified, 2);
      expect(b.answers, 1);
      expect(c.answer, contains('consult a doctor'));
      expect(b.lastImage, isNotEmpty);
    });

    test('ad not loaded -> adFailed, never answered; credits path works', () async {
      final b = FakeCvBackend();
      final ads = FakePhotoAds(outcome: RewardOutcome.unavailable);
      final c = ctl(b, ads: ads);
      await c.start();
      await c.requestDetailed('ads');
      expect(c.phase, CvPhase.adFailed);
      expect(b.answers, 0);
      await c.requestDetailed('credits');
      expect(c.phase, CvPhase.done);
      expect(b.funding, 'credits');
    });

    test('ad shown but SSV never arrives -> honest adFailed (no endless wait)', () async {
      final b = FakeCvBackend();
      final c = ctl(b, ads: FakePhotoAds()); // earned, but no ssv() call
      await c.start();
      await c.requestDetailed('ads');
      expect(c.phase, CvPhase.adFailed);
      expect(b.answers, 0);
    });

    test('premium: pool, no ads', () async {
      final b = FakeCvBackend(plan: 'premium');
      final ads = FakePhotoAds();
      final c = ctl(b, ads: ads);
      await c.start();
      expect(c.quote.option('ads'), isNull);
      await c.requestDetailed('pool');
      expect(c.phase, CvPhase.done);
      expect(ads.shown, 0);
    });

    test('face identification refused', () async {
      final b = FakeCvBackend(plan: 'premium', refuse: true);
      final c = ctl(b);
      await c.start();
      await c.requestDetailed('pool');
      expect(c.phase, CvPhase.refused);
      expect(c.message, isNotEmpty);
      expect(b.answers, 0);
    });

    test('offline config -> honest retry state', () async {
      final c = ctl(FakeCvBackend(offline: true));
      await c.start();
      expect(c.configFailed, isTrue);
      expect(c.phase, CvPhase.ready);
    });
  });

  group('ChatPhotoTurn widget', () {
    testWidgets('free: no on-device block when unavailable + ads/credits offer -> answer',
        (tester) async {
      final b = FakeCvBackend();
      final c = CvController(
          backend: b,
          bytes: kTinyPng,
          question: 'What is this?',
          onDevice: FakeOnDevice(OnDeviceReading.unavailable),
          ads: FakePhotoAds(onShown: (_) => b.ssv()),
          pollEvery: Duration.zero);
      await tester.pumpWidget(_app(ListView(children: [
        ChatPhotoTurn(request: ChatPhotoRequest(kTinyPng, 'What is this?'), controller: c),
      ])));
      await tester.runAsync(c.start);
      await _settle(tester);
      final t = _t(tester, ChatPhotoTurn);
      // NO SHOWPIECES: no "not in this version yet" block, no on-device title.
      expect(find.text(t.h1OnDeviceTitle), findsNothing);
      expect(find.text(t.h1DetailedAds('2')), findsOneWidget);
      expect(find.text(t.h1UseCredits('3')), findsOneWidget);
      await tester.tap(find.text(t.h1DetailedAds('2')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await _settle(tester);
      expect(c.phase, CvPhase.done);
      expect(find.text(t.h1PrivacyNote), findsOneWidget);
      expect(find.textContaining('NAPA 500 mg'), findsOneWidget);
    });

    testWidgets('needs key: server message, no buttons', (tester) async {
      final c = CvController(
          backend: FakeCvBackend(reason: 'provider_missing', message: 'Needs a vision key'),
          bytes: kTinyPng,
          question: '',
          onDevice: FakeOnDevice(OnDeviceReading.unavailable),
          ads: FakePhotoAds());
      await tester.pumpWidget(_app(ListView(children: [
        ChatPhotoTurn(request: ChatPhotoRequest(kTinyPng, ''), controller: c),
      ])));
      await tester.runAsync(c.start);
      await _settle(tester);
      expect(find.text('Needs a vision key'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('large font, 360 px: no overflow', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final b = FakeCvBackend();
      final c = CvController(
          backend: b,
          bytes: kTinyPng,
          question: 'What medicine is this? How should I take it?',
          onDevice: FakeOnDevice(kMedicineReading),
          ads: FakePhotoAds());
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.6)),
        child: _app(ListView(children: [
          ChatPhotoTurn(request: ChatPhotoRequest(kTinyPng, c.question), controller: c),
        ])),
      ));
      await tester.runAsync(c.start);
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  test('CvQuote parses defensively', () {
    final q = CvQuote.fromJson({
      'ok': true,
      'reason': 'ok',
      'options': [
        {'via': 'ads', 'ads': '2'},
        'junk',
        {'via': 'credits', 'credits': 3}
      ]
    });
    expect(q.option('ads')!.ads, 2);
    expect(q.option('credits')!.credits, 3);
    expect(CvQuote.fromJson(null).ok, isFalse);
  });
}
