// home_v2 (owner final home design, 26 Oct): flag + fallback, header
// greeting / badges / menu, Discover restyle on the same tracked data path,
// the 12 shortcuts (owner order, real routes only, skip + fill, customised
// users kept, Edit picker with the pinned lock), the Ask Assisto card -> AI
// chat screen, the bottom bar (5 items, one-tap voice), one ad for Free only,
// no chat input on home, 200 % font, All Services catalogue.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

AppState _state(String lang, {FakeApi? api, String name = 'Arif Hossain'}) {
  final s = AppState();
  s.api = api ?? FakeApi(lang: lang);
  s.user = AppUser(
      id: 1,
      name: name,
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

Widget _home({bool free = false, CircleBadgeState? circle, List<String>? routes}) {
  HomeHero.debugReset();
  HomeHero.debugBridge = FakeHeroBridge();
  HomeHero.debugLoadConfig =
      () async => heroConfig(plan: free ? 'free' : 'premium');
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
      expect(g(23), t.hv2GreetNight);
      expect(g(3), t.hv2GreetNight);
      expect(hv2FirstName('Arif Hossain'), 'Arif');
      expect(hv2FirstName('  '), isNull);
      expect(hv2FirstName('+8801700000000'), isNull);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('first name, badges in the UI digits, menu opens drawer ($lang)',
          (tester) async {
        await _pump(tester, _home(), lang: lang);
        final t = _t(tester);
        expect(find.text(t.hv2GreetName(t.hv2GreetMorning, 'Arif')),
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
}
