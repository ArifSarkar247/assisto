// banners-everywhere (owner decision 26 Oct): one adaptive anchored banner
// at the bottom of every NORMAL Free-user feature screen, plus a small
// "Remove ads" link to Premium. The never-list (SOS, safety, journey,
// anti-theft, family alerts, calls, chat conversation, chat lock / vault,
// payment / plans / top-up, login / OTP / sign-up, onboarding, language,
// permission, ring-check) is enforced in code — these tests prove it, plus
// the caps (one banner per screen, refresh >= 60 s), Premium = nothing, and
// that the banner never overlaps a bottom button / input (bn + en, 200 %).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

Map<String, dynamic> _server({String plan = 'free', List<String>? banner, int? refresh}) {
  final paid = plan != 'free';
  return {
    'plan': plan,
    'paid': paid,
    'ads_enabled': !paid,
    'placements': {'banner': !paid},
    'banner_screens': paid ? <String>[] : (banner ?? AdPlacements.bannerScreens.toList()),
    if (refresh != null) 'banner_refresh_sec': refresh,
  };
}

AdConfig _cfg({String plan = 'free', List<String>? banner, int? refresh}) =>
    AdConfig.fromJson(_server(plan: plan, banner: banner, refresh: refresh));

class _Handle implements BannerAdHandle {
  @override
  double get height => 50;
  @override
  Widget view() => const ColoredBox(
      key: ValueKey('fake-banner'), color: Color(0xFF888888), child: SizedBox(height: 50));
  @override
  void dispose() {}
}

class _Bridge implements BannerBridge {
  int loads = 0;
  @override
  bool get linked => true;
  @override
  Future<BannerAdHandle?> load(String unitId,
      {required double width, required String placement}) async {
    loads++;
    return _Handle();
  }
}

AppState _app(String lang) {
  final s = AppState();
  s.api = FakeApi(mode: FakeMode.empty, lang: lang);
  s.user = AppUser(
      id: 1, name: lang == 'bn' ? 'রহিম' : 'Rahim', phone: '01700000000', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _wrap(Widget home, {String lang = 'en', double scale = 1.0}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _app(lang),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BannerPacer.resetForTest();
    AdBannerSlot.debugBridge = null;
    AdBannerSlot.debugLoadConfig = null;
    AdBannerSlot.debugPlansBuilder = null;
  });

  group('allowlist vs never-list', () {
    test('the owner-listed normal screens are on the allowlist', () {
      for (final s in [
        'money', 'budget', 'reminders', 'notes_todos', 'jobs',
        'prepaid_meter', 'contract', 'business', 'crm', 'all_services',
        'dictionary', 'health_tips', 'saved_items', 'photo_gallery',
        'circle_list', 'settings',
      ]) {
        expect(AdPlacements.bannerScreens, contains(s), reason: s);
        expect(AdPlacements.screenAllowed(AdSurface.banner, s), isTrue, reason: s);
      }
    });

    test('allowlist and never-list are disjoint; no allowed key hits the fence', () {
      expect(AdPlacements.bannerScreens.intersection(AdPlacements.neverScreens.toSet()),
          isEmpty);
      for (final s in AdPlacements.bannerScreens) {
        expect(AdRules.isBlockedScreen(s), isFalse, reason: s);
      }
      expect(AdPlacements.bannerScreens.contains('home'), isFalse);
      expect(AdPlacements.bannerScreens.intersection(AdPlacements.nativeScreens), isEmpty);
    });

    test('every never-list key is refused by the token fence itself', () {
      // i.e. even if someone added it to the allowlist it would stay ad-free
      for (final s in AdPlacements.neverScreens) {
        expect(AdRules.isBlockedScreen(s), isTrue, reason: s);
        for (final slot in AdSurface.values) {
          expect(AdPlacements.screenAllowed(slot, s), isFalse, reason: '$slot $s');
        }
      }
    });

    test('the never-list covers every owner-required category', () {
      for (final s in [
        'sos', 'safety', 'journey_live', 'safe_journey', 'journey_settings',
        'fall_detect', 'emergency', 'antitheft', 'lost_stolen', 'my_lost_phone',
        'family_alerts', 'incoming_call', 'in_call', 'call_log', 'circle_chat',
        'chat_conversation', 'chat_lock', 'vault', 'chat_vault', 'payment',
        'plans', 'checkout', 'topup', 'login', 'otp', 'signup', 'sign_up',
        'onboarding', 'language_picker', 'permission', 'ring_check',
        'account_security', 'password', 'delete_account',
      ]) {
        expect(AdPlacements.neverScreens, contains(s), reason: s);
      }
    });

    test('My Circle chat LIST allowed, a conversation never', () {
      final c = _cfg();
      expect(AdPlacements.banner('circle_list', c, loggedIn: true).allowed, isTrue);
      for (final s in ['circle_chat', 'chat_conversation', 'messenger_chat',
          'group_chat', 'circle_group_chat', 'circle_call', 'circle_calls']) {
        expect(AdPlacements.banner(s, c, loggedIn: true).allowed, isFalse, reason: s);
      }
    });

    test('even the server listing a never-screen cannot switch it on', () {
      final c = _cfg(banner: ['money', 'sos', 'plans', 'circle_chat', 'journey_live']);
      expect(AdPlacements.banner('money', c, loggedIn: true).allowed, isTrue);
      for (final s in ['sos', 'plans', 'circle_chat', 'journey_live']) {
        expect(AdPlacements.banner(s, c, loggedIn: true).allowed, isFalse, reason: s);
      }
      // ... and it can narrow: a listed page switched off server-side
      expect(AdPlacements.banner('budget', c, loggedIn: true).reason, 'server_off');
    });

    test('Premium / Business: no banner on any screen', () {
      for (final plan in ['premium', 'business']) {
        final c = _cfg(plan: plan);
        for (final s in AdPlacements.bannerScreens) {
          expect(AdPlacements.banner(s, c, loggedIn: true).allowed, isFalse,
              reason: '$plan $s');
        }
      }
    });
  });

  group('caps', () {
    test('refresh never faster than 60 s whatever the server sends', () {
      expect(AdRules.minBannerRefresh, const Duration(seconds: 60));
      expect(_cfg().bannerRefresh, const Duration(seconds: 60));
      expect(_cfg(refresh: 10).bannerRefresh, const Duration(seconds: 60));
      expect(_cfg(refresh: 0).bannerRefresh, const Duration(seconds: 60));
      expect(_cfg(refresh: 120).bannerRefresh, const Duration(seconds: 120));
      final t0 = DateTime(2026, 10, 26, 10);
      BannerPacer.markLoaded('money', t0);
      expect(BannerPacer.wait('money', t0.add(const Duration(seconds: 30)),
          const Duration(seconds: 5)), const Duration(seconds: 30));
      expect(BannerPacer.wait('money', t0.add(const Duration(seconds: 61)),
          const Duration(seconds: 60)), Duration.zero);
    });

    test('one banner per route: the second claim is refused', () {
      final route = Object();
      final a = Object(), b = Object();
      expect(BannerPacer.claim(route, a), isTrue);
      expect(BannerPacer.claim(route, b), isFalse);
      BannerPacer.release(route, a);
      expect(BannerPacer.claim(route, b), isTrue);
    });

    testWidgets('two slots on one screen -> only one banner', (tester) async {
      final br = _Bridge();
      await tester.pumpWidget(_wrap(Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          AdBannerSlot(screen: 'money', bridge: br, loadConfig: () async => _cfg()),
          AdBannerSlot(screen: 'budget', bridge: br, loadConfig: () async => _cfg()),
        ]),
      )));
      await _settle(tester);
      expect(br.loads, 1);
      expect(find.byKey(const ValueKey('ad-banner-slot')), findsOneWidget);
    });

    testWidgets('refreshes after 60 s, not before', (tester) async {
      final br = _Bridge();
      await tester.pumpWidget(_wrap(Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar:
            AdBannerSlot(screen: 'reminders', bridge: br, loadConfig: () async => _cfg(refresh: 5)),
      )));
      await _settle(tester);
      expect(br.loads, 1);
      await tester.pump(const Duration(seconds: 58));
      await tester.pump();
      expect(br.loads, 1);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(br.loads, 2);
    });

    testWidgets('Premium: nothing is loaded, slot takes no space', (tester) async {
      final br = _Bridge();
      await tester.pumpWidget(_wrap(Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: AdBannerSlot(
            screen: 'money', bridge: br, loadConfig: () async => _cfg(plan: 'premium')),
      )));
      await _settle(tester);
      expect(br.loads, 0);
      expect(tester.getSize(find.byType(AdBannerSlot)).height, 0);
    });

    testWidgets('disabled (another tab) -> hidden, no load', (tester) async {
      final br = _Bridge();
      await tester.pumpWidget(_wrap(Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: AdBannerSlot(
            screen: 'circle_list', enabled: false, bridge: br, loadConfig: () async => _cfg()),
      )));
      await _settle(tester);
      expect(br.loads, 0);
      expect(find.byKey(const ValueKey('ad-banner-slot')), findsNothing);
    });
  });

  group('Remove ads link', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('opens the Premium plans ($lang), own label, 48 dp', (tester) async {
        AdBannerSlot.debugPlansBuilder = (_) => const Scaffold(body: Text('PLANS-PAGE'));
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_wrap(
            Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: AdBannerSlot(
                  screen: 'dictionary', bridge: _Bridge(), loadConfig: () async => _cfg()),
            ),
            lang: lang));
        await _settle(tester);
        final link = find.byKey(const ValueKey('ad-banner-remove'));
        expect(link, findsOneWidget);
        expect(find.text(lang == 'bn' ? 'বিজ্ঞাপন সরান' : 'Remove ads'), findsOneWidget);
        final size = tester.getSize(link);
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(
            find.bySemanticsLabel(lang == 'bn'
                ? 'বিজ্ঞাপন সরান। প্রিমিয়াম প্ল্যান খুলবে'
                : 'Remove ads. Opens the Premium plans'),
            findsOneWidget);
        // the link is outside the ad view, with a clear gap
        final ad = tester.getRect(find.byKey(const ValueKey('ad-banner-view')));
        final l = tester.getRect(link);
        expect(ad.top - l.bottom, greaterThanOrEqualTo(8));
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(find.text('PLANS-PAGE'), findsOneWidget);
        handle.dispose();
      });
    }
  });

  group('never overlaps content, buttons or inputs (200 % font)', () {
    // representative layouts: a list with an extended FAB (reminders /
    // birthdays / jobs), a bottom input row (notes / dictionary search) and
    // a tabbed page whose own tab bar sits above the banner (My Circle).
    for (final lang in ['en', 'bn']) {
      testWidgets('FAB page ($lang)', (tester) async {
        await tester.pumpWidget(_wrap(
            Scaffold(
              appBar: AppBar(title: const Text('Reminders')),
              floatingActionButton: FloatingActionButton.extended(
                  key: const ValueKey('fab'),
                  onPressed: () {},
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add')),
              body: ListView(children: [
                for (var i = 0; i < 30; i++) ListTile(title: Text('Item $i')),
              ]),
              bottomNavigationBar: AdBannerSlot(
                  screen: 'reminders', bridge: _Bridge(), loadConfig: () async => _cfg()),
            ),
            lang: lang,
            scale: 2.0));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final slot = tester.getRect(find.byKey(const ValueKey('ad-banner-slot')));
        final fab = tester.getRect(find.byKey(const ValueKey('fab')));
        final body = tester.getRect(find.byType(ListView));
        expect(fab.bottom + 8, lessThanOrEqualTo(slot.top));
        expect(body.bottom, lessThanOrEqualTo(slot.top));
      });

      testWidgets('bottom input page ($lang)', (tester) async {
        await tester.pumpWidget(_wrap(
            Scaffold(
              body: Column(children: [
                const Expanded(child: SizedBox.expand()),
                Padding(
                  padding: const EdgeInsets.all(Gap.sm),
                  child: Row(children: [
                    const Expanded(child: TextField(key: ValueKey('input'))),
                    IconButton(
                        key: const ValueKey('send'),
                        onPressed: () {},
                        icon: const Icon(Icons.search_rounded)),
                  ]),
                ),
              ]),
              bottomNavigationBar: AdBannerSlot(
                  screen: 'dictionary', bridge: _Bridge(), loadConfig: () async => _cfg()),
            ),
            lang: lang,
            scale: 2.0));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final ad = tester.getRect(find.byKey(const ValueKey('ad-banner-view')));
        final slot = tester.getRect(find.byKey(const ValueKey('ad-banner-slot')));
        for (final k in ['input', 'send']) {
          final r = tester.getRect(find.byKey(ValueKey(k)));
          expect(r.overlaps(ad), isFalse, reason: k);
          expect(r.bottom, lessThanOrEqualTo(slot.top), reason: k);
        }
      });

      testWidgets('above a bottom tab bar ($lang)', (tester) async {
        await tester.pumpWidget(_wrap(
            Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
                AdBannerSlot(
                    screen: 'circle_list', bridge: _Bridge(), loadConfig: () async => _cfg()),
                NavigationBar(
                    key: const ValueKey('tabs'),
                    destinations: const [
                      NavigationDestination(icon: Icon(Icons.forum_rounded), label: 'Chats'),
                      NavigationDestination(icon: Icon(Icons.call_rounded), label: 'Calls'),
                    ]),
              ]),
            ),
            lang: lang,
            scale: 2.0));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final ad = tester.getRect(find.byKey(const ValueKey('ad-banner-view')));
        final tabs = tester.getRect(find.byKey(const ValueKey('tabs')));
        expect(ad.bottom + 8, lessThanOrEqualTo(tabs.top));
        expect(ad.overlaps(tabs), isFalse);
      });
    }

    testWidgets('keyboard open -> banner hidden', (tester) async {
      await tester.pumpWidget(_wrap(Builder(
          builder: (c) => MediaQuery(
                data: MediaQuery.of(c).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
                child: Scaffold(
                  body: const TextField(),
                  bottomNavigationBar: AdBannerSlot(
                      screen: 'notes_todos', bridge: _Bridge(), loadConfig: () async => _cfg()),
                ),
              ))));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ad-banner-slot')), findsNothing);
    });
  });

  test('documents (PIN vault) never carries a banner', () {
    expect(AdPlacements.screenAllowed(AdSurface.banner, 'documents'), isFalse);
    expect(AdPlacements.bannerScreens.contains('documents'), isFalse);
  });
}
