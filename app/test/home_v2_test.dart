// home_v2 (owner final home design, 26 Oct): flag + fallback, header
// greeting / badges / menu, Discover restyle on the same tracked data path,
// the 12 shortcuts (owner order, real routes only, skip + fill, customised
// users kept, Edit picker with the pinned lock), the Ask Assisto card -> AI
// chat screen, the bottom bar (5 items, one-tap voice), one ad for Free only,
// no chat input on home, 200 % font, All Services catalogue.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

import 'package:assisto/ads/admob_hero_bridge.dart' show heroTemplateStyle;
import 'package:assisto/ads/hero_ad.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/home_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/app_drawer.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/screens/home_v2/all_services_screen.dart';
import 'package:assisto/screens/home_v2/assisto_chat_screen.dart';
import 'package:assisto/screens/home_v2/home_v2_header.dart';
import 'package:assisto/screens/home_v2/home_v2_screen.dart';
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/circle_badges.dart';
import 'package:assisto/widgets/home_hero.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';
import 'package:assisto/widgets/home_suggestions.dart';

import 'app_fonts.dart';
import 'fake_api.dart';
import 'h1_home_fakes.dart';

class _Nav extends NavigatorObserver {
  final List<String?> pushed = [];
  @override
  void didPush(Route route, Route? previousRoute) {
    pushed.add(route.settings.name);
  }
}

class _TrackApi extends FakeApi {
  final List<Map<String, dynamic>> tracked = [];
  _TrackApi(String lang) : super(lang: lang);

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/discover/track') {
      tracked.add(body);
      return {'ok': true};
    }
    return super.postJson(path, body);
  }
}

AppState _state(String lang, {FakeApi? api, String? name}) {
  final s = AppState();
  s.api = api ?? FakeApi(lang: lang);
  s.user = AppUser(
      id: 1,
      name: name ?? (lang == 'bn' ? 'রহিম উদ্দিন' : 'Rahim Uddin'),
      phone: '+8801700000000',
      email: '',
      autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Future<_Nav> _pump(WidgetTester tester, Widget home,
    {String lang = 'en',
    bool dark = false,
    double scale = 1.0,
    FakeApi? api,
    Size size = const Size(390, 844)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final nav = _Nav();
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(
          value: _state(lang, api: api)),
      ChangeNotifierProvider<Updater>(create: (_) => Updater()),
    ],
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
      darkTheme: AssistoTheme.dark,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      navigatorObservers: [nav],
      builder: (c, child) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    ),
  ));
  await _settle(tester);
  return nav;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Widget _home(
    {bool free = false,
    CircleBadgeState? circle,
    List<String>? routes,
    String? size,
    FakeHeroBridge? bridge}) {
  HomeHero.debugReset();
  HomeHero.debugBridge = bridge ?? FakeHeroBridge();
  HomeHero.debugLoadConfig =
      () async => heroConfig(plan: free ? 'free' : 'premium', size: size);
  return HomeV2Screen(
    debugNow: DateTime(2026, 10, 26, 9),
    debugBadges: const HomeBadges(myCircleUnread: 3, notifUnseen: 2),
    debugCircle: circle ?? const CircleBadgeState(unread: 3, missed: true),
    debugRoutes: routes,
  );
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

void main() {
  setUpAll(() async {
    await loadAppFonts();
    PackageInfo.setMockInitialValues(
        appName: 'Assisto',
        packageName: 'com.assisto.assisto',
        version: '1.0.0',
        buildNumber: '248',
        buildSignature: '');
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    CircleBadges.instance.reset();
    FeatureFlags.instance.resetForTest();
  });
  tearDown(() {
    FeatureFlags.instance.resetForTest();
    HomeHero.debugReset();
  });

  group('flag home_v2', () {
    test('registered, ON by default (shipped), owns no route', () {
      expect(kFeatureDefaults['home_v2'], isTrue);
      expect(kRouteFeature.values, isNot(contains('home_v2')));
    });

    test('ON -> new home; OFF -> the old home unchanged', () {
      expect(selectHome(), isA<HomeV2Screen>());
      FeatureFlags.instance.debugOverride = {'home_v2': false};
      expect(selectHome(), isA<HomeScreen>());
      expect(selectHome(v2: true), isA<HomeV2Screen>());
    });
  });

  group('header', () {
    test('greeting by time of day', () async {
      final t = await AppLocalizations.delegate.load(const Locale('bn'));
      String g(int h) => hv2Greeting(t, DateTime(2026, 1, 1, h));
      expect(g(6), t.hv2GreetMorning);
      expect(g(13), t.hv2GreetNoon);
      expect(g(17), t.hv2GreetAfternoon);
      expect(g(19), t.hv2GreetEvening);
      expect(g(23), t.hv2GreetLate);
      expect(g(3), t.hv2GreetLate);
      expect(hv2FirstName('Rahim Uddin'), 'Rahim');
      expect(hv2FirstName('  '), isNull);
      expect(hv2FirstName('+8801700000000'), isNull);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('first name, badges in the UI digits, menu opens drawer ($lang)',
          (tester) async {
        await _pump(tester, _home(), lang: lang);
        final t = _t(tester);
        expect(find.text(t.hv2GreetName(t.hv2GreetMorning, lang == 'bn' ? 'রহিম' : 'Rahim')),
            findsOneWidget);
        expect(find.text(lang == 'bn' ? '২' : '2'), findsOneWidget);
        // header + pinned tile both show the circle count
        expect(find.text(lang == 'bn' ? '৩' : '3'), findsNWidgets(2));
        // My Circle keeps the three-person icon everywhere on home
        expect(find.byIcon(Icons.diversity_3), findsNWidgets(2));
        await tester.tap(find.byKey(const ValueKey('hv2_menu')));
        await _settle(tester);
        expect(find.byType(AppDrawer), findsOneWidget);
        await _unmount(tester);
      });
    }
  });

  group('home body', () {
    testWidgets('no chat input and no new-chat FAB on home', (tester) async {
      await _pump(tester, _home());
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      await _unmount(tester);
    });

    testWidgets('Discover restyle: same server data, impressions + clicks',
        (tester) async {
      final api = _TrackApi('en');
      await _pump(tester, _home(), api: api);
      expect(find.byType(DiscoverCardV2), findsWidgets);
      expect(find.text('Photo Studio'), findsOneWidget); // server seed card 1
      expect(api.tracked.map((e) => '${e['card_id']}:${e['event']}'),
          contains('1:impression'));
      await tester.tap(find.byKey(const ValueKey('discover_v2_photo_enhance')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.tracked.map((e) => '${e['card_id']}:${e['event']}'),
          contains('1:click'));
      await _unmount(tester);
    });

    testWidgets('Ask Assisto opens the AI chat screen', (tester) async {
      final nav = await _pump(tester, _home());
      await tester.ensureVisible(find.byKey(const ValueKey('hv2_ask')));
      await tester.tap(find.byKey(const ValueKey('hv2_ask')));
      await _settle(tester);
      expect(nav.pushed.last, AssistoChatScreen.routeName);
      expect(find.byType(AssistoChatScreen), findsOneWidget);
      // the chat keeps History + New chat (the input lives in the thread)
      expect(find.byKey(const ValueKey('hv2_chat_history')), findsOneWidget);
      expect(find.byKey(const ValueKey('hv2_chat_new')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('bottom bar: 5 items; Assisto Voice is one tap', (tester) async {
      final nav = await _pump(tester, _home());
      for (final k in [
        'hv2_nav_home',
        'hv2_nav_all',
        'hv2_voice',
        'hv2_nav_reminders',
        'hv2_nav_business'
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      await tester.tap(find.byKey(const ValueKey('hv2_voice')));
      await tester.pump();
      expect(nav.pushed.last, 'voice_assistant');
      await _unmount(tester);
    });

    testWidgets('All Services opens the catalogue', (tester) async {
      final nav = await _pump(tester, _home());
      await tester.tap(find.byKey(const ValueKey('hv2_nav_all')));
      await _settle(tester);
      expect(nav.pushed.last, 'all_services');
      expect(find.byType(AllServicesScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Free: exactly one labelled ad; Premium: none', (tester) async {
      await _pump(tester, _home(free: true));
      await _settle(tester);
      expect(find.byKey(const ValueKey('fake-native-ad')), findsOneWidget);
      expect(find.text(_t(tester).h1AdLabel), findsOneWidget);
      await _unmount(tester);
      await _pump(tester, _home(free: false));
      await _settle(tester);
      expect(find.byKey(const ValueKey('fake-native-ad')), findsNothing);
      await _unmount(tester);
    });

    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('200 % font: no overflow, 3 columns ($lang dark=$dark)',
            (tester) async {
          await _pump(tester, _home(),
              lang: lang, dark: dark, scale: 2.0, size: const Size(360, 800));
          expect(tester.takeException(), isNull);
          final a = tester.getTopLeft(
              find.byKey(const ValueKey('hv2_tile_circle')));
          final d = tester.getTopLeft(
              find.byKey(const ValueKey('hv2_tile_khata')));
          expect(d.dy, greaterThan(a.dy)); // 4th tile starts row 2
          expect(d.dx, a.dx);
          await _unmount(tester);
        });
      }
    }

    // owner 26 Oct (build 250): one-line purple subtitle on the pinned
    // My Circle tile only; screen reader says "My Circle, chat and call".
    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('My Circle subtitle, one line at 200 % ($lang dark=$dark)',
            (tester) async {
          await _pump(tester, _home(),
              lang: lang, dark: dark, scale: 2.0, size: const Size(360, 800));
          expect(tester.takeException(), isNull);
          final t = lookupAppLocalizations(Locale(lang));
          final sub = find.byKey(const ValueKey('hv2_tile_subtitle'));
          expect(sub, findsOneWidget); // only the pinned tile has one
          expect(
              find.descendant(
                  of: find.byKey(const ValueKey('hv2_tile_circle')),
                  matching: sub),
              findsOneWidget);
          final w = tester.widget<Text>(sub);
          expect(w.data, t.hv2CircleSub);
          expect(w.maxLines, 1);
          expect(w.overflow, TextOverflow.ellipsis);
          expect(w.style!.fontWeight, FontWeight.w600);
          expect(w.style!.color,
              dark ? const Color(0xFFE08AE0) : const Color(0xFF800080));
          // one line: its height is about one line even at 200 %
          final h = tester.getSize(sub).height;
          expect(h, lessThan(w.style!.fontSize! * 1.6 * 1.6));
          final tile = tester.getSemantics(
              find.byKey(const ValueKey('hv2_tile_circle')));
          expect(tile.label, startsWith(t.hv2CircleA11y));
          await _unmount(tester);
        });
      }
    }

    testWidgets('normal font: 4 columns', (tester) async {
      await _pump(tester, _home());
      final a = tester.getTopLeft(find.byKey(const ValueKey('hv2_tile_circle')));
      final d = tester.getTopLeft(find.byKey(const ValueKey('hv2_tile_khata')));
      expect(d.dy, a.dy);
      await _unmount(tester);
    });
  });

  group('shortcuts', () {
    test('owner order, real routes, flag-hidden skipped + filled', () {
      // defaults: CCTV (home_watchman) is hidden -> Reminders fills slot 11
      expect(HomeV2Shortcuts.defaults(), [
        'family',
        'journey',
        'khata',
        'sales_agent',
        'vehicle_tracking',
        'jobs',
        'lost_stolen',
        'prepaid_meter',
        'budget',
        'contract',
        'reminders',
      ]);
      expect(HomeV2Shortcuts.skippedDefaults(), ['watchman']);
      for (final r in HomeV2Shortcuts.defaults()) {
        expect(ChatNav.routes.containsKey(r), isTrue, reason: r);
      }
      // Play-style flags: vehicles + anti-theft hidden -> next real features
      FeatureFlags.instance.debugOverride = {
        'vehicle_tracking': false,
        'anti_theft': false,
      };
      final d = HomeV2Shortcuts.defaults();
      expect(d, isNot(contains('vehicle_tracking')));
      expect(d, isNot(contains('lost_stolen')));
      expect(d.length, HomeV2Shortcuts.max);
      expect(d.sublist(8), ['reminders', 'money', 'notes']);
      // CCTV appears in its slot the day the owner turns it on
      FeatureFlags.instance.debugOverride = {'home_watchman': true};
      expect(HomeV2Shortcuts.defaults()[4], 'watchman');
    });

    test('a saved set is kept exactly (no top-up, no My Circle)', () {
      expect(HomeV2Shortcuts.sanitize(['notes', 'circle', 'notes', 'nope']),
          ['notes']);
      expect(HomeV2Shortcuts.max, 11);
    });

    test('old-home customised users keep their own six', () async {
      SharedPreferences.setMockInitialValues({
        HomeQuickButtons.prefsKey:
            jsonEncode(['money', 'notes', 'emergency', 'scam', 'tax', 'memory']),
      });
      Settings.resetForTest();
      expect(await HomeV2Shortcuts.load(),
          ['money', 'notes', 'emergency', 'scam', 'tax', 'memory']);
      // a v2 save wins over the old six
      await HomeV2Shortcuts.save(['jobs', 'budget']);
      expect(await HomeV2Shortcuts.load(), ['jobs', 'budget']);
    });

    test('new users get the owner default', () async {
      expect(await HomeV2Shortcuts.load(), HomeV2Shortcuts.defaults());
    });

    testWidgets('12 tiles, My Circle pinned first with count + missed dot',
        (tester) async {
      await _pump(tester, _home());
      expect(find.byType(HomeV2Tile), findsNWidgets(12));
      final first = tester.widget<HomeV2Tile>(find.byType(HomeV2Tile).first);
      expect(first.route, 'circle');
      expect(first.pinned, isTrue);
      expect(find.byKey(const ValueKey('hv2_unread')), findsOneWidget);
      expect(find.byKey(const ValueKey('hv2_missed_dot')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('ONE Edit button opens the picker with My Circle locked',
        (tester) async {
      await _pump(tester, _home());
      expect(find.byKey(const ValueKey('hv2_edit')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hv2_edit')));
      await _settle(tester);
      expect(find.byType(QuickButtonsPicker), findsOneWidget);
      expect(find.byKey(const ValueKey('quick_pinned_lock')), findsOneWidget);
      expect(find.text(_t(tester).hv2PickTitle), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('a tile opens its real screen route', (tester) async {
      final nav = await _pump(tester, _home(routes: ['budget']));
      await tester.tap(find.byKey(const ValueKey('hv2_tile_budget')));
      await tester.pump();
      expect(nav.pushed.last, 'budget');
      await _unmount(tester);
    });
  });

  group('All Services', () {
    testWidgets('built from the sidebar, flag-aware, searchable',
        (tester) async {
      const tall = Size(390, 6000);
      await _pump(tester, const AllServicesScreen(), size: tall);
      final t = _t(tester);
      expect(find.text(t.sidebarMyCircle), findsOneWidget);
      expect(find.text(t.jobHunter), findsOneWidget);
      await _unmount(tester);
      FeatureFlags.instance.debugOverride = {'jobs': false};
      await _pump(tester, const AllServicesScreen(), size: tall);
      expect(find.text(t.jobHunter), findsNothing);
      await tester.enterText(
          find.byKey(const ValueKey('all_search')), 'zzzz-nothing');
      await _settle(tester);
      expect(find.text(t.hv2AllEmpty), findsOneWidget);
      await _unmount(tester);
    });
  });

  // ---------------------------------------------------------------------
  // owner feedback 27 Oct (build 249, real phone)
  group('owner feedback 27 Oct', () {
    test('greeting windows (device local time), en + bn', () async {
      for (final lang in ['en', 'bn']) {
        final t = await AppLocalizations.delegate.load(Locale(lang));
        String g(int h, int m) => hv2Greeting(t, DateTime(2026, 10, 27, h, m));
        expect(g(4, 59), t.hv2GreetLate, reason: lang);
        expect(g(5, 0), t.hv2GreetMorning, reason: lang);
        expect(g(11, 59), t.hv2GreetMorning, reason: lang);
        expect(g(12, 0), t.hv2GreetNoon, reason: lang);
        expect(g(15, 59), t.hv2GreetNoon, reason: lang);
        expect(g(16, 0), t.hv2GreetAfternoon, reason: lang);
        expect(g(17, 59), t.hv2GreetAfternoon, reason: lang);
        expect(g(18, 0), t.hv2GreetEvening, reason: lang);
        expect(g(21, 59), t.hv2GreetEvening, reason: lang);
        expect(g(22, 0), t.hv2GreetLate, reason: lang);
        expect(g(2, 0), t.hv2GreetLate, reason: lang);
      }
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      // the owner's exact words
      expect(en.hv2GreetMorning, 'Good morning');
      expect(en.hv2GreetNoon, 'Good afternoon');
      expect(en.hv2GreetAfternoon, 'Good afternoon');
      expect(en.hv2GreetEvening, 'Good evening');
      expect(en.hv2GreetLate, 'Hello, still up');
      expect(bn.hv2GreetMorning, 'শুভ সকাল');
      expect(bn.hv2GreetNoon, 'শুভ দুপুর');
      expect(bn.hv2GreetAfternoon, 'শুভ বিকাল');
      expect(bn.hv2GreetEvening, 'শুভ সন্ধ্যা');
      expect(bn.hv2GreetLate, 'শুভ রাত্রি');
      // 2 AM never says "Good evening" (the build 249 bug)
      final two = DateTime(2026, 10, 27, 2);
      expect(hv2GreetingLine(en, two, 'Rahim'), 'Hello Rahim, still up?');
      expect(hv2GreetingLine(en, two, null), 'Hello, still up?');
      expect(hv2GreetingLine(bn, two, 'রহিম'), 'শুভ রাত্রি, রহিম!');
      expect(hv2GreetingLine(en, two, 'Rahim'), isNot(contains('evening')));
      expect(hv2GreetingLine(en, DateTime(2026, 10, 27, 9), 'Rahim'),
          'Good morning, Rahim!');
    });

    test('preview-only feature -> no home tile; enabled -> tile', () async {
      // the owner / testers get CCTV as a server PREVIEW only
      FeatureFlags.instance.applyForTest({
        'features': {'home_watchman': true, 'scam_check': true},
        'preview': ['home_watchman', 'scam_check'],
      });
      expect(FeatureFlags.instance.isPreviewRoute('watchman'), isTrue);
      expect(ChatNav.routes.containsKey('watchman'), isTrue); // still reachable
      final d = HomeV2Shortcuts.defaults();
      expect(d, isNot(contains('watchman')));
      expect(d.length, HomeV2Shortcuts.max);
      expect(d.last, 'reminders'); // the next real feature fills the slot
      expect(HomeV2Shortcuts.skippedDefaults(), contains('watchman'));
      // a user-picked set drops it too
      expect(HomeV2Shortcuts.sanitize(['watchman', 'notes']), ['notes']);
      // old home (fallback) quick buttons follow the same rule
      expect(HomeQuickButtons.sanitize(['scam', 'money']), isNot(contains('scam')));
      expect(HomeQuickButtons.catalog.map((s) => s.route), isNot(contains('scam')));
      // turned ON for everyone (no preview) -> a real tile in its slot
      FeatureFlags.instance.applyForTest({
        'features': {'home_watchman': true, 'scam_check': true},
        'preview': <String>[],
      });
      expect(HomeV2Shortcuts.defaults()[4], 'watchman');
      expect(HomeQuickButtons.sanitize(['scam', 'money']).first, 'scam');
    });

    testWidgets('preview-only: no home tile, "Preview" tag in All Services',
        (tester) async {
      FeatureFlags.instance.applyForTest({
        'features': {'home_watchman': true},
        'preview': ['home_watchman'],
      });
      await _pump(tester, _home());
      expect(find.byKey(const ValueKey('hv2_tile_watchman')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('hv2_nav_all')));
      await _settle(tester);
      final t = _t(tester);
      await tester.enterText(find.byKey(const ValueKey('all_search')), 'cctv');
      await _settle(tester);
      expect(find.text(t.wmTitle), findsWidgets);
      expect(find.text(t.ffPreviewTag), findsWidgets);
      await _unmount(tester);
    });

    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('compact ad: <= 110 dp, between shortcuts and Ask card, '
            'Remove-ads link outside the ad ($lang dark=$dark)', (tester) async {
          final nav = await _pump(tester, _home(free: true),
              lang: lang, dark: dark);
          await _settle(tester);
          final t = _t(tester);
          final box = find.byKey(const ValueKey('hero-ad-box'));
          expect(box, findsOneWidget);
          expect(tester.getSize(box).height, inInclusiveRange(90, 110));
          expect(find.byKey(const ValueKey('fake-native-large')), findsNothing);
          // position: below the shortcuts, above the Ask (Need help) card
          final grid = tester.getRect(find.byType(HV2Grid).first);
          final ad = tester.getRect(box);
          final ask = tester.getRect(find.byKey(const ValueKey('hv2_ask')));
          expect(ad.top, greaterThan(grid.bottom));
          expect(ad.bottom, lessThan(ask.top));
          // label visible, link separate: not inside the ad box, no overlap,
          // >= 8 dp of space, its own TalkBack button
          expect(find.text(t.h1AdLabel), findsOneWidget);
          final link = find.byKey(const ValueKey('hero-remove-ads'));
          expect(link, findsOneWidget);
          expect(find.descendant(of: box, matching: link), findsNothing);
          final l = tester.getRect(link);
          expect(l.overlaps(ad), isFalse);
          expect(ad.top - l.bottom, greaterThanOrEqualTo(8));
          expect(l.height, greaterThanOrEqualTo(48));
          final sem = tester.getSemantics(link);
          expect(sem.label, t.hv2RemoveAdsA11y);
          // its own node: not the ad's node, not merged into it
          final adSem = tester.getSemantics(box);
          expect(sem.id, isNot(adSem.id));
          expect(adSem.label, isNot(contains(t.hv2RemoveAds)));
          // no close / X anywhere on the ad
          for (final i in [Icons.close, Icons.close_rounded, Icons.cancel]) {
            expect(find.descendant(of: box, matching: find.byIcon(i)),
                findsNothing);
          }
          // the link opens the Premium plans
          await tester.ensureVisible(link);
          await tester.tap(link);
          await tester.pump();
          expect(nav.pushed.last, 'plans');
          await _unmount(tester);
        });
      }
    }

    testWidgets('compact ad at 200 % font: no overflow, grows sanely',
        (tester) async {
      // tall surface so the whole page (incl. the ad) is built at once
      await _pump(tester, _home(free: true),
          scale: 2.0, size: const Size(360, 2000));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final box = find.byKey(const ValueKey('hero-ad-box'));
      expect(tester.getSize(box).height, lessThanOrEqualTo(110));
      final card = tester.getRect(find.byType(CompactAdFrame));
      // label/link row grows with the font; the whole card stays small
      expect(card.height, lessThanOrEqualTo(200));
      await _unmount(tester);
    });

    testWidgets('server home_native_size: large -> big card; unknown -> compact',
        (tester) async {
      final big = FakeHeroBridge();
      await _pump(tester, _home(free: true, size: 'large', bridge: big));
      await _settle(tester);
      expect(big.lastSize, HeroAdSize.large);
      expect(find.byKey(const ValueKey('fake-native-large')), findsOneWidget);
      expect(find.byKey(const ValueKey('hero-remove-ads')), findsOneWidget);
      final box = find.byKey(const ValueKey('hero-ad-box'));
      expect(tester.getSize(box).height, greaterThan(110));
      final l = tester.getRect(find.byKey(const ValueKey('hero-remove-ads')));
      expect(l.overlaps(tester.getRect(box)), isFalse);
      expect(find.descendant(of: box, matching: find.byIcon(Icons.close)),
          findsNothing);
      expect(find.text(_t(tester).h1AdLabel), findsOneWidget);
      await _unmount(tester);
      final odd = FakeHeroBridge();
      await _pump(tester, _home(free: true, size: 'gigantic', bridge: odd));
      await _settle(tester);
      expect(odd.lastSize, HeroAdSize.compact);
      expect(tester.getSize(find.byKey(const ValueKey('hero-ad-box'))).height,
          lessThanOrEqualTo(110));
      await _unmount(tester);
    });

    test('config: size + daily cap parsing (no config -> compact, 20)', () {
      expect(HeroAdConfig.none.size, HeroAdSize.compact);
      expect(HeroAdConfig.none.dailyCap, 20);
      expect(HeroAdConfig.fromJson(heroConfig()).size, HeroAdSize.compact);
      expect(HeroAdConfig.fromJson(heroConfig(size: 'large')).size,
          HeroAdSize.large);
      expect(HeroAdConfig.fromJson(heroConfig(size: ' LARGE ')).size,
          HeroAdSize.large);
      expect(HeroAdConfig.fromJson(heroConfig(size: 'xl')).size,
          HeroAdSize.compact);
      expect(HeroAdConfig.fromJson(heroConfig(cap: 7)).dailyCap, 7);
      expect(HeroAdConfig.fromJson(heroConfig(cap: 999)).dailyCap, 50);
      expect(HeroAdRules.compactAdHeight(328), 90);
      expect(HeroAdRules.compactAdHeight(400), 100);
      expect(HeroAdRules.compactAdHeight(900), 110);
    });

    test('policy: official templates, SDK AdChoices, real ids only by switch',
        () {
      expect(heroTemplateStyle(null, HeroAdSize.compact).templateType,
          TemplateType.small);
      expect(heroTemplateStyle(null, HeroAdSize.large).templateType,
          TemplateType.medium);
      const look = HeroAdLook(
          background: Color(0xFF000001),
          headline: Color(0xFF000002),
          body: Color(0xFF000003),
          ctaBackground: Color(0xFF000004),
          ctaText: Color(0xFF000005),
          textScale: 2.0);
      final st = heroTemplateStyle(look, HeroAdSize.compact);
      expect(st.templateType, TemplateType.small);
      // the SDK view's text grows at most 1.3x (never clipped)
      expect(st.primaryTextStyle!.size! * 2.0, closeTo(14 * 1.3, 0.01));
      final src = File('lib/ads/admob_hero_bridge.dart').readAsStringSync();
      expect(src, contains('AdChoicesPlacement.topRightCorner'));
      expect(src, isNot(contains('Icons.close')));
      // real unit only with the server switch (configured) + matching app id
      final test = HeroAdConfig.fromJson(
          {...heroConfig(), 'units': {'native': 'ca-app-pub-1/2'}});
      expect(test.unit(builtAppId: 'ca-app-pub-1~3'), HeroAdIds.testNative);
      final real = HeroAdConfig.fromJson({
        ...heroConfig(),
        'configured': true,
        'app_id': 'ca-app-pub-1~3',
        'units': {'native': 'ca-app-pub-1/2'},
      });
      expect(real.unit(builtAppId: 'ca-app-pub-1~3'), 'ca-app-pub-1/2');
      // the native ad validator popup is switched off in every CI build
      final ci = File('../.github/workflows/android.yml').readAsStringSync();
      expect(ci, contains('com.google.android.gms.ads.flag.NATIVE_AD_DEBUGGER_ENABLED'));
    });

    testWidgets('refresh: <= once per 60 s, only while home visible + resumed',
        (tester) async {
      var visible = true;
      final b = FakeHeroBridge();
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: ListView(children: [
            HomeHero(
                fallback: const SizedBox.shrink(),
                availableHeight: 300,
                bridge: b,
                loadConfig: () async => heroConfig(refresh: 60),
                isHomeVisible: () => visible,
                onRemoveAds: () {}),
          ]),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(b.loads, 1);
      await tester.pump(const Duration(seconds: 50));
      expect(b.loads, 1, reason: 'never faster than 60 s');
      await tester.pump(const Duration(seconds: 11));
      await tester.pump(const Duration(milliseconds: 100));
      expect(b.loads, 2);
      // covered by another screen: no reload however long
      visible = false;
      await tester.pump(const Duration(seconds: 200));
      expect(b.loads, 2);
      // home visible again -> reload within a few seconds (it is overdue)
      visible = true;
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 100));
      expect(b.loads, 3);
      // background: no timer, no load
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 300));
      expect(b.loads, 3);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 100));
      expect(b.loads, 4);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('daily cap: 20 impressions today -> no native load',
        (tester) async {
      final now = DateTime.now();
      for (var i = 0; i < 20; i++) {
        await HeroDailyCap.recordImpression(now: now);
      }
      expect(await HeroDailyCap.today(now: now), 20);
      expect(await HeroDailyCap.reached(20, now: now), isTrue);
      expect(await HeroDailyCap.reached(21, now: now), isFalse);
      // a new day starts at zero
      expect(await HeroDailyCap.today(now: now.add(const Duration(days: 1))), 0);
      final b = FakeHeroBridge();
      await _pump(tester, _home(free: true, bridge: b));
      await _settle(tester);
      expect(b.loads, 0);
      expect(find.byKey(const ValueKey('hero-ad-box')), findsNothing);
      await _unmount(tester);
    });
  });
}
