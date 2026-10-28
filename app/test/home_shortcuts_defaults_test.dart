// homeshort (owner real-phone test, 28 Oct): the home DEFAULT shortcuts.
// New default = My Circle (pinned) + Family Care, Safe Journey, Digital
// Ledger, CRM, Business, AI Sales Assistant, CCTV, Vehicle Tracking, Prepaid
// Meter, Emergency SOS, Account & Finance. Job Hunter, Phone Security, Budget
// and Contract Scanner left the default but stay in Edit shortcuts.
// Migration: new installs + never-edited users get the new set; a saved set
// that is EXACTLY an old default counts as never edited; every edited set is
// kept; the migration runs once per defaults version.
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

const _removed = ['jobs', 'lost_stolen', 'budget', 'contract'];

/// The screen each default must really open (no placeholder).
const _screens = {
  'family': 'FamilyScreen',
  'journey': 'JourneyStartScreen',
  'khata': 'KhataEntryScreen',
  'crm': 'CrmHomeScreen',
  'business': 'BusinessScreen',
  'sales_agent': 'SellerAgentScreen',
  'watchman': 'WatchmanScreen',
  'vehicle_tracking': 'VehicleTrackingScreen',
  'prepaid_meter': 'PrepaidMeterScreen',
  'emergency': 'EmergencyScreen',
  'money': 'MoneyScreen',
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
      expect(HomeV2Shortcuts.ownerOrder, _newDefault);
      expect(HomeV2Shortcuts.max, 11);
      expect(HomeV2Shortcuts.defaults(), _newDefault);
      expect(HomeV2Shortcuts.skippedDefaults(), isEmpty);
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
        final b = ChatNav.routes[r];
        expect(b, isNotNull, reason: r);
        expect(b!(ctx).runtimeType.toString(), _screens[r], reason: r);
        expect(HomeV2Shortcuts.byRoute(r), isNotNull, reason: r);
        expect(HomeV2Shortcuts.openRoute(r), r);
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
      expect(l(bn, 'business'), 'ব্যবসার হিসাব');   // owner 28 Oct: Business Accounts
      expect(l(en, 'business'), 'Business Accounts');
    });

    test('the 4 removed ones stay in Edit shortcuts', () {
      final cat = HomeV2Shortcuts.catalog.map((s) => s.route).toList();
      for (final r in [..._removed, ..._newDefault]) {
        expect(cat, contains(r), reason: r);
      }
      // the new defaults lead the Edit list, in order
      expect(cat.take(11).toList(), _newDefault);
    });

    test('flag OFF for this user -> skipped honestly, next real one fills',
        () {
      FeatureFlags.instance.debugOverride = {'crm': false};
      var d = HomeV2Shortcuts.defaults();
      expect(d, isNot(contains('crm')));
      expect(d.length, 11);
      expect(d.last, 'reminders');
      expect(HomeV2Shortcuts.skippedDefaults(), ['crm']);
      // business off hides the ledger too (same flag) -> two fills
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
      expect(HomeV2Shortcuts.defaults().last, 'notes');
    });
  });

  group('migration', () {
    test('new install: new set, version stored', () async {
      expect(await HomeV2Shortcuts.load(), _newDefault);
      expect(await _get(HomeV2Shortcuts.versionKey), '2');
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
      expect(await _get(HomeV2Shortcuts.versionKey), '2');
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
