// homeshort (owner real-phone test, 28 Oct): the home DEFAULT shortcuts.
// New default = My Circle (pinned) + Family Care, Safe Journey, Digital
// Ledger, CRM, Business, AI Sales Assistant, CCTV, Vehicle Tracking, Prepaid
// Meter, Emergency SOS, Account & Finance. Job Hunter, Phone Security, Budget
// and Contract Scanner left the default but stay in Edit shortcuts.
// Migration: new installs + never-edited users get the new set; a saved set
// that is EXACTLY an old default counts as never edited; every edited set is
// kept; the migration runs once per defaults version.
// homeshort (owner 9 Nov 11:25): Digital Ledger left the default (it is the
// first tile inside My Business), City Service took its slot (skipped until
// its screen + flag exist), "Business Accounts" is now "My Business".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/home_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/home_v2/home_v2_screen.dart';
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/circle_badges.dart';
import 'package:assisto/widgets/home_hero.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';

import 'app_fonts.dart';
import 'fake_api.dart';
import 'h1_home_fakes.dart';

const _newDefault = [
  'family',
  'journey',
  'crm',
  'business',
  'sales_agent',
  'watchman',
  'vehicle_tracking',
  'prepaid_meter',
  'emergency',
  'money',
  'reminders', // fills City Service's slot until its screen ships
];

/// The 2 Nov (v3) default as builds up to 316 showed it — with Digital Ledger.
const _v3Default = [
  'family',
  'journey',
  'khata',
  'crm',
  'business',
  'sales_agent',
  'watchman',
  'vehicle_tracking',
  'prepaid_meter',
  'emergency',
  'money',
];

/// homeorder (owner order 2 Nov): Blood donor right next to SOS in the
/// owner order; flag blood_donors is OFF by default, so the shown default is
/// still [_newDefault] until the owner switches it on.
const _ownerOrder = [
  'family',
  'journey',
  'city_service',
  'crm',
  'business',
  'sales_agent',
  'watchman',
  'vehicle_tracking',
  'prepaid_meter',
  'emergency',
  'blood_panel',
  'money',
];

const _removed = ['jobs', 'lost_stolen', 'budget', 'contract'];

/// The screen each default must really open (no placeholder).
const _screens = {
  'family': 'FamilyScreen',
  'journey': 'SafeJourneyHubScreen', // sjlive: three cards, Live Location first
  'crm': 'CrmHomeScreen',
  'business': 'BusinessScreen',
  'sales_agent': 'SellerAgentScreen',
  'watchman': 'WatchmanScreen',
  'vehicle_tracking': 'VehicleTrackingScreen',
  'prepaid_meter': 'PrepaidMeterScreen',
  'emergency': 'EmergencyHubScreen', // ownerfix: SOS tile -> Emergency hub
  'money': 'MoneyScreen',
  'reminders': 'RemindersScreen',
};

Future<void> _prefs(Map<String, Object> v) async {
  SharedPreferences.setMockInitialValues(v);
  Settings.resetForTest();
}

Future<String?> _get(String k) => Settings.getString(k);

AppState _state(String lang) {
  final s = AppState();
  s.api = FakeApi(lang: lang);
  s.user = AppUser(
      id: 1,
      name: lang == 'bn' ? 'রহিম' : 'Rahim',
      phone: '+8801700000000',
      email: '',
      autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Future<void> _pumpHome(WidgetTester tester,
    {required String lang, required double scale, required Size size}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  HomeHero.debugReset();
  HomeHero.debugBridge = FakeHeroBridge();
  HomeHero.debugLoadConfig = () async => heroConfig(plan: 'premium');
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: _state(lang)),
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
      builder: (c, child) => MediaQuery(
          data:
              MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: HomeV2Screen(
        debugNow: DateTime(2026, 10, 28, 9),
        debugBadges: const HomeBadges(myCircleUnread: 3, notifUnseen: 2),
        debugCircle: const CircleBadgeState(unread: 3, missed: true),
      ),
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() async {
    await loadAppFonts();
    PackageInfo.setMockInitialValues(
        appName: 'Assisto',
        packageName: 'com.assisto.assisto',
        version: '1.0.0',
        buildNumber: '272',
        buildSignature: '');
  });
  setUp(() async {
    await _prefs({});
    CircleBadges.instance.reset();
    FeatureFlags.instance.resetForTest();
  });
  tearDown(() {
    FeatureFlags.instance.resetForTest();
    HomeHero.debugReset();
  });

  group('the new default set', () {
    test('owner order + 2 picks, exactly the 11 slots, My Circle not in it',
        () {
      expect(HomeV2Shortcuts.ownerOrder, _ownerOrder);
      expect(HomeV2Shortcuts.max, 11);
      expect(HomeV2Shortcuts.defaults(), _newDefault);
      expect(HomeV2Shortcuts.skippedDefaults(), ['city_service', 'blood_panel']);
      expect(HomeV2Shortcuts.defaults(), isNot(contains('khata')));
      for (final r in _removed) {
        expect(HomeV2Shortcuts.defaults(), isNot(contains(r)), reason: r);
      }
      for (final a in HomeQuickButtons.pinnedAliases) {
        expect(HomeV2Shortcuts.defaults(), isNot(contains(a)));
      }
    });

    testWidgets('every default resolves to its real screen', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final ctx = tester.element(find.byType(SizedBox));
      for (final r in HomeV2Shortcuts.defaults()) {
        final b = ChatNav.routes[HomeV2Shortcuts.openRoute(r)];
        expect(b, isNotNull, reason: r);
        expect(b!(ctx).runtimeType.toString(), _screens[r], reason: r);
        expect(HomeV2Shortcuts.byRoute(r), isNotNull, reason: r);
        expect(HomeV2Shortcuts.openRoute(r),
            r == 'emergency' ? 'emergency_hub' : r);
      }
    });

    test('bn + en labels exist and are real words', () async {
      for (final lang in ['en', 'bn']) {
        final t = await AppLocalizations.delegate.load(Locale(lang));
        for (final r in HomeV2Shortcuts.defaults()) {
          final l = HomeV2Shortcuts.byRoute(r)!.label(t);
          expect(l.trim(), isNotEmpty, reason: '$lang $r');
          expect(l.contains('{'), isFalse, reason: '$lang $r');
        }
      }
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      String l(AppLocalizations t, String r) =>
          HomeV2Shortcuts.byRoute(r)!.label(t);
      expect(l(en, 'crm'), 'CRM');
      expect(l(en, 'emergency'), 'Emergency SOS');
      expect(l(bn, 'emergency'), 'জরুরি SOS');
      expect(l(en, 'money'), 'Account & Finance');
      expect(l(bn, 'money'), 'হিসাব ও অর্থ');
      // homeshort (owner 9 Nov): "Business Accounts" -> "My Business"
      expect(l(bn, 'business'), 'আমার ব্যবসা');
      expect(l(en, 'business'), 'My Business');
      expect(l(en, 'khata'), 'Digital Ledger');
      expect(en.hv2TileCityService, 'City Service');
      expect(bn.hv2TileCityService, 'সিটি সার্ভিস');
      expect(en.hv2NewBadge, 'New');
      expect(bn.hv2NewBadge, 'নতুন');
    });

    test('homeorder: Blood donor ON -> right next to SOS, still 11 slots',
        () {
      FeatureFlags.instance.debugOverride = {'blood_donors': true};
      final d = HomeV2Shortcuts.defaults();
      expect(d.length, 11);
      expect(d.indexOf('blood_panel'), d.indexOf('emergency') + 1);
      expect(HomeV2Shortcuts.skippedDefaults(), ['city_service']);
      // My Circle stays pinned outside the 11; money moves to Edit / All
      // services (still pinnable)
      expect(d, isNot(contains('circle')));
      expect(HomeV2Shortcuts.catalog.map((s) => s.route),
          containsAll(['money', 'blood_panel']));
    });

    test('the 4 removed ones + Digital Ledger stay in Edit shortcuts', () {
      final cat = HomeV2Shortcuts.catalog.map((s) => s.route).toList();
      for (final r in [..._removed, ..._newDefault, 'khata']) {
        expect(cat, contains(r), reason: r);
      }
      // the owner's defaults lead the Edit list, in order
      expect(cat.take(10).toList(), _newDefault.take(10).toList());
      // City Service has no screen in this build -> not offered (no dead tile)
      expect(cat, isNot(contains('city_service')));
    });

    test('flag OFF for this user -> skipped honestly, next real one fills',
        () {
      FeatureFlags.instance.debugOverride = {'crm': false};
      var d = HomeV2Shortcuts.defaults();
      expect(d, isNot(contains('crm')));
      expect(d.length, 11);
      expect(d.last, 'notes');
      expect(HomeV2Shortcuts.skippedDefaults(),
          ['city_service', 'crm', 'blood_panel']);
      // business off -> its slot filled too
      FeatureFlags.instance.debugOverride = {'business': false};
      d = HomeV2Shortcuts.defaults();
      expect(d, isNot(contains('khata')));
      expect(d, isNot(contains('business')));
      expect(d.sublist(9), ['reminders', 'notes']);
      for (final r in d) {
        expect(ChatNav.routes.containsKey(r), isTrue, reason: r);
      }
      // a PREVIEW-only feature (owner / testers) is off for the home too
      FeatureFlags.instance.resetForTest();
      FeatureFlags.instance.applyForTest({
        'features': {'business_agent': true},
        'preview': ['business_agent'],
      });
      expect(HomeV2Shortcuts.defaults(), isNot(contains('sales_agent')));
      // the fill also skips a flag-off pool entry (reminders hidden)
      FeatureFlags.instance.resetForTest();
      FeatureFlags.instance.debugOverride = {'crm': false, 'reminders': false};
      expect(HomeV2Shortcuts.defaults().last, 'documents');
    });
  });

  group('migration', () {
    test('new install: new set, version stored', () async {
      expect(await HomeV2Shortcuts.load(), _newDefault);
      expect(await _get(HomeV2Shortcuts.versionKey), '4');
    });

    test('never edited (no saved set) on an old build: new set', () async {
      await _prefs({HomeV2Shortcuts.versionKey: '1'});
      expect(await HomeV2Shortcuts.load(), _newDefault);
    });

    test('saved set == the old default exactly -> new set', () async {
      await _prefs({
        HomeV2Shortcuts.prefsKey: jsonEncode(HomeV2Shortcuts.legacyOwnerOrder),
      });
      expect(await HomeV2Shortcuts.load(), _newDefault);
      expect(await _get(HomeV2Shortcuts.prefsKey), anyOf(isNull, ''));
    });

    test('old default as computed with flags off (skips + fills) -> new set',
        () async {
      // build < 262: CCTV + vehicle tracking off -> reminders, money filled
      final old = [
        'family', 'journey', 'khata', 'sales_agent', 'jobs', 'lost_stolen',
        'prepaid_meter', 'budget', 'contract', 'reminders', 'money', //
      ];
      expect(HomeV2Shortcuts.isLegacyDefault(old), isTrue);
      await _prefs({HomeV2Shortcuts.prefsKey: jsonEncode(old)});
      expect(await HomeV2Shortcuts.load(), _newDefault);
      // reminders hidden too -> money, notes filled
      expect(
          HomeV2Shortcuts.isLegacyDefault([
            'family', 'journey', 'khata', 'sales_agent', 'jobs', //
            'lost_stolen', 'prepaid_meter', 'budget', 'contract', 'money',
            'notes',
          ]),
          isTrue);
    });

    test('old-home six never edited (shipped / server default) -> new set',
        () async {
      await _prefs({
        HomeQuickButtons.prefsKey: jsonEncode(HomeQuickButtons.defaults),
      });
      expect(await HomeV2Shortcuts.load(), _newDefault);
      // with a flag-off one dropped (reminders hidden)
      await _prefs({
        HomeQuickButtons.prefsKey:
            jsonEncode(['money', 'notes', 'ai_chat', 'family', 'documents']),
      });
      expect(await HomeV2Shortcuts.load(), _newDefault);
      // the owner default the server sent (cached), saved unchanged
      final server = ['family', 'money', 'emergency', 'notes', 'scam', 'tax'];
      await _prefs({
        HomeQuickButtons.serverPrefsKey: jsonEncode(server),
        HomeQuickButtons.prefsKey: jsonEncode(server),
      });
      expect(await HomeV2Shortcuts.load(), _newDefault);
    });

    test('homeorder: the 28 Oct default saved unchanged -> new set', () async {
      FeatureFlags.instance.debugOverride = {'blood_donors': true};
      await _prefs({
        HomeV2Shortcuts.versionKey: '2',
        HomeV2Shortcuts.prefsKey: jsonEncode(_v3Default),
      });
      final d = await HomeV2Shortcuts.load();
      expect(d.indexOf('blood_panel'), d.indexOf('emergency') + 1);
      expect(await _get(HomeV2Shortcuts.versionKey), '4');
      // but a user who changed the 28 Oct set keeps theirs
      final mine = [..._v3Default.reversed];
      await _prefs({
        HomeV2Shortcuts.versionKey: '2',
        HomeV2Shortcuts.prefsKey: jsonEncode(mine),
      });
      expect(await HomeV2Shortcuts.load(), mine);
    });

    test('edited sets are kept exactly', () async {
      final edited = <List<String>>[
        // reordered old default
        ['journey', 'family', 'khata', 'sales_agent', 'watchman',
          'vehicle_tracking', 'jobs', 'lost_stolen', 'prepaid_meter',
          'budget', 'contract'],
        // removed one (10 tiles)
        ['family', 'journey', 'khata', 'sales_agent', 'watchman',
          'vehicle_tracking', 'jobs', 'lost_stolen', 'prepaid_meter',
          'budget'],
        // swapped one for a non-pool feature
        ['family', 'journey', 'khata', 'sales_agent', 'watchman',
          'vehicle_tracking', 'jobs', 'lost_stolen', 'prepaid_meter',
          'budget', 'nearby'],
        // a short personal set
        ['jobs', 'budget', 'contract'],
      ];
      for (final e in edited) {
        expect(HomeV2Shortcuts.isLegacyDefault(e), isFalse, reason: '$e');
        await _prefs({HomeV2Shortcuts.prefsKey: jsonEncode(e)});
        expect(await HomeV2Shortcuts.load(), e, reason: '$e');
        expect(await _get(HomeV2Shortcuts.prefsKey), jsonEncode(e));
      }
      // an edited old-home six (reordered / other picks) is kept too
      for (final six in [
        ['money', 'reminders', 'notes', 'ai_chat', 'family', 'documents'],
        ['money', 'notes', 'emergency', 'scam', 'tax', 'memory'],
      ]) {
        await _prefs({HomeQuickButtons.prefsKey: jsonEncode(six)});
        expect(await HomeV2Shortcuts.load(), six, reason: '$six');
        expect(await _get(HomeQuickButtons.prefsKey), jsonEncode(six));
      }
    });

    test('runs ONCE: after it, a saved old-default set is the user\'s choice',
        () async {
      expect(await HomeV2Shortcuts.load(), _newDefault);
      expect(await _get(HomeV2Shortcuts.versionKey), '4');
      // the user later deliberately picks exactly the old 11 and saves
      await HomeV2Shortcuts.save(HomeV2Shortcuts.legacyOwnerOrder);
      expect(await HomeV2Shortcuts.load(), HomeV2Shortcuts.legacyOwnerOrder);
      expect(await HomeV2Shortcuts.load(), HomeV2Shortcuts.legacyOwnerOrder);
    });

    test('the old home\'s server default never overrides this list',
        () async {
      await _prefs({
        HomeQuickButtons.serverPrefsKey:
            jsonEncode(['reminders', 'notes', 'tax', 'scam', 'memory', 'jobs']),
      });
      expect(await HomeV2Shortcuts.load(), _newDefault);
    });

    test('a saved set always wins over a new default (Edit still works)',
        () async {
      await HomeV2Shortcuts.save(['contract', 'jobs']);
      expect(await HomeV2Shortcuts.load(), ['contract', 'jobs']);
    });
  });

  // homeshort (owner 9 Nov 11:25): Digital Ledger -> inside My Business,
  // City Service in its home slot. Decision (least surprising): never-edited
  // users get the new set; an EDITED set keeps Digital Ledger exactly where
  // the user put it (nothing they chose disappears).
  group('homeshort v4 migration', () {
    test('2 Nov default saved unchanged -> new set, no ledger', () async {
      await _prefs({
        HomeV2Shortcuts.versionKey: '3',
        HomeV2Shortcuts.prefsKey: jsonEncode(_v3Default),
      });
      expect(HomeV2Shortcuts.isLegacyDefault(_v3Default), isTrue);
      final d = await HomeV2Shortcuts.load();
      expect(d, _newDefault);
      expect(d, isNot(contains('khata')));
      expect(await _get(HomeV2Shortcuts.versionKey), '4');
    });

    test('2 Nov default with Blood donor ON, saved unchanged -> new set',
        () async {
      FeatureFlags.instance.debugOverride = {'blood_donors': true};
      final v3 = [
        'family', 'journey', 'khata', 'crm', 'business', 'sales_agent', //
        'watchman', 'vehicle_tracking', 'prepaid_meter', 'emergency',
        'blood_panel',
      ];
      await _prefs({
        HomeV2Shortcuts.versionKey: '3',
        HomeV2Shortcuts.prefsKey: jsonEncode(v3),
      });
      final d = await HomeV2Shortcuts.load();
      expect(d, isNot(contains('khata')));
      expect(d.indexOf('blood_panel'), d.indexOf('emergency') + 1);
    });

    test('edited set with Digital Ledger keeps it in place (no loss)',
        () async {
      for (final mine in [
        // ledger moved to the front by the user
        ['khata', 'family', 'journey', 'crm', 'business', 'money'],
        // the 2 Nov default with one tile swapped
        [
          'family', 'journey', 'khata', 'crm', 'business', 'sales_agent', //
          'watchman', 'vehicle_tracking', 'prepaid_meter', 'emergency',
          'nearby',
        ],
        // only the ledger
        ['khata'],
      ]) {
        expect(HomeV2Shortcuts.isLegacyDefault(mine), isFalse, reason: '$mine');
        await _prefs({
          HomeV2Shortcuts.versionKey: '3',
          HomeV2Shortcuts.prefsKey: jsonEncode(mine),
        });
        expect(await HomeV2Shortcuts.load(), mine, reason: '$mine');
        expect(await _get(HomeV2Shortcuts.prefsKey), jsonEncode(mine));
        expect(await _get(HomeV2Shortcuts.versionKey), '4');
      }
    });

    test('old-home six with the ledger is kept too', () async {
      final six = ['khata', 'money', 'notes', 'family', 'tax', 'memory'];
      await _prefs({
        HomeV2Shortcuts.versionKey: '3',
        HomeQuickButtons.prefsKey: jsonEncode(six),
      });
      expect(await HomeV2Shortcuts.load(), six);
    });

    test('a user can still pin Digital Ledger back from Edit', () async {
      await HomeV2Shortcuts.load();
      await HomeV2Shortcuts.save([..._newDefault.take(10), 'khata']);
      expect((await HomeV2Shortcuts.load()).last, 'khata');
    });

    test('City Service: no screen in this build -> never a dead tile',
        () async {
      expect(ChatNav.routes.containsKey(kCityServiceRoute), isFalse);
      expect(HomeV2Shortcuts.byRoute(kCityServiceRoute), isNull);
      expect(HomeV2Shortcuts.sanitize([kCityServiceRoute, 'family']),
          ['family']);
      // its slot in the owner order is Digital Ledger's old one
      expect(HomeV2Shortcuts.ownerOrder.indexOf(kCityServiceRoute),
          HomeV2Shortcuts.v3OwnerOrder.indexOf('khata'));
    });

    test('"New" badge: shown until opened once, then remembered', () async {
      expect(HomeV2Shortcuts.newTiles, {kCityServiceRoute});
      expect(await HomeV2Shortcuts.newSeen(), isEmpty);
      await HomeV2Shortcuts.markNewSeen('family'); // not a new tile: ignored
      expect(await HomeV2Shortcuts.newSeen(), isEmpty);
      await HomeV2Shortcuts.markNewSeen(kCityServiceRoute);
      Settings.resetForTest();
      expect(await HomeV2Shortcuts.newSeen(), {kCityServiceRoute});
    });

    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('New badge renders + is announced ($lang dark=$dark)',
            (tester) async {
          final sh = tester.ensureSemantics();
          addTearDown(sh.dispose);
          await tester.binding.setSurfaceSize(const Size(360, 400));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(MaterialApp(
            locale: Locale(lang),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: dark ? AssistoTheme.dark : AssistoTheme.light,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 90,
                  child: HomeV2Tile(
                    route: kCityServiceRoute,
                    icon: Icons.directions_transit_outlined,
                    label: lang == 'bn' ? 'সিটি সার্ভিস' : 'City Service',
                    isNew: true,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ));
          await tester.pump();
          expect(find.byKey(const ValueKey('hv2_new_badge')), findsOneWidget);
          expect(find.text(lang == 'bn' ? 'নতুন' : 'New'), findsOneWidget);
          expect(
              find.bySemanticsLabel(RegExp(lang == 'bn'
                  ? r'সিটি সার্ভিস.*নতুন'
                  : r'City Service.*New')),
              findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('home look', () {
    for (final lang in ['en', 'bn']) {
      for (final scale in [1.0, 2.0]) {
        for (final size in [const Size(390, 2600), const Size(360, 2600)]) {
          testWidgets(
              'new default tiles, in order, labels not clipped '
              '($lang ${scale}x ${size.width.toInt()})', (tester) async {
            await _pumpHome(tester, lang: lang, scale: scale, size: size);
            final tiles = tester
                .widgetList<HomeV2Tile>(find.byType(HomeV2Tile))
                .map((w) => w.route)
                .toList();
            expect(tiles, ['circle', ..._newDefault]);
            for (final r in _newDefault) {
              final tile = find.byKey(ValueKey('hv2_tile_$r'));
              expect(tile, findsOneWidget, reason: r);
              final sz = tester.getSize(tile);
              expect(sz.height, greaterThanOrEqualTo(48), reason: r);
              for (final p in tester.renderObjectList<RenderParagraph>(
                  find.descendant(of: tile, matching: find.byType(RichText)))) {
                expect(p.didExceedMaxLines, isFalse, reason: '$lang $r');
              }
            }
            expect(tester.takeException(), isNull);
            await _unmount(tester);
          });
        }
      }
    }
  });
}
