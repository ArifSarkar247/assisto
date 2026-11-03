// ownerfix (owner fixes 3 Nov 02:55) — items 1 + 3:
//  1 ONE blood donor feature: the old registry screen is gone; "My saved
//    donors" (its donors, migrated) lives in the panel — never hidden,
//    available first, waiting by exact days, paused shown, header counts,
//    doctor line, private; every old link / chat / push opens the panel; NO
//    ads anywhere in blood donor;
//  3 home SOS tile -> Emergency hub, Blood donor next to SOS; Discover lead
//    order SOS, Train, Live Location, Destination Alarm, Blood donor;
//  visibility: owner / testers (preview) see blood donor in the menu; a
//    normal user only after the owner switches blood_donors ON.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/blood/blood_hub_screen.dart';
import 'package:assisto/screens/blood/blood_saved_screen.dart';
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/home_suggestions.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

import 'fake_blood.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false}) {
    token = 't';
  }

  final bool empty;
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      fakeBloodGet(path, bn: false, empty: empty) ?? <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    return {'ok': true, 'donor': {'id': 900, ...body}};
  }

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async => {'ok': true};
}

Widget _app(Widget child, ApiClient api, {String lang = 'en', double scale = 1}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, w) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    ),
  );
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 7000);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    FeatureFlags.instance.resetForTest();
  });
  tearDown(() => FeatureFlags.instance.resetForTest());

  group('My saved donors (the old list, inside the one panel)', () {
    testWidgets('never hidden, server order, exact days, counts, doctor line, private, no ad',
        (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      await t.pumpWidget(_app(const BloodSavedScreen(), _Fake()));
      await t.pumpAndSettle();
      expect(find.text(l.bsvPrivate), findsOneWidget);
      expect(find.text(l.bpListCounts(3, 1, 1)), findsOneWidget);
      final y = [
        for (final k in ['bsv-donor-501', 'bsv-donor-502', 'bsv-donor-503'])
          t.getTopLeft(find.byKey(ValueKey(k))).dy,
      ];
      expect(y[0] < y[1] && y[1] < y[2], isTrue, reason: 'available, waiting, paused');
      expect(find.text(l.bpCanNow), findsOneWidget);
      expect(find.text(l.bpStAgoLeft(43, 77)), findsOneWidget);
      expect(find.text(l.bpStPaused), findsOneWidget);
      expect(find.text(l.bsvFromOld), findsNWidgets(2));
      expect(find.byKey(const ValueKey('bsv-doctor-decides')), findsOneWidget);
      // Call / SMS only when a number exists
      expect(find.byKey(const ValueKey('bsv-call-501')), findsOneWidget);
      expect(find.byKey(const ValueKey('bsv-call-503')), findsNothing);
      expect(find.byType(AdBannerSlot), findsNothing);
    });

    testWidgets('empty: benefit + big button; add needs a name and a group', (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      final api = _Fake(empty: true);
      await t.pumpWidget(_app(const BloodSavedScreen(), api));
      await t.pumpAndSettle();
      expect(find.text(l.bsvEmptyTitle), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('bsv-empty-add')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('bsv-save')));
      await t.tap(find.byKey(const ValueKey('bsv-save')));
      await t.pump();
      expect(find.text(l.bsvErrName), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('bsv-name')), 'Nadia');
      await t.tap(find.byKey(const ValueKey('bsv-save')));
      await t.pump();
      expect(find.text(l.bsvErrGroup), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('bsv-g-AB-')));
      await t.tap(find.byKey(const ValueKey('bsv-g-AB-')));
      await t.pump();
      await t.ensureVisible(find.byKey(const ValueKey('bsv-save')));
      await t.tap(find.byKey(const ValueKey('bsv-save')));
      await t.pumpAndSettle();
      expect(api.posts.single.$1, '/blood-panel/saved');
      expect(api.posts.single.$2['name'], 'Nadia');
      expect(api.posts.single.$2['blood_group'], 'AB-');
      expect(api.posts.single.$2['available'], isTrue);
    });

    testWidgets('the panel Find tab opens My saved donors', (t) async {
      _tall(t);
      await t.pumpWidget(_app(const BloodHubScreen(), _Fake()));
      await t.pumpAndSettle();
      final row = find.byKey(const ValueKey('bp-saved'));
      expect(row, findsOneWidget);
      await t.tap(row);
      await t.pumpAndSettle();
      expect(find.byType(BloodSavedScreen), findsOneWidget);
      expect(find.byType(AdBannerSlot), findsNothing);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('200% text, 360 dp, $lang: no overflow', (t) async {
        t.view.physicalSize = const Size(1080, 6000);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(_app(const BloodSavedScreen(), _Fake(), lang: lang, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }
  });

  group('one feature, every entry point -> the panel', () {
    testWidgets('old route alias + chat phrase + push', (t) async {
      FeatureFlags.instance.debugOverride = {'blood_donors': true};
      await t.pumpWidget(const SizedBox());
      final ctx = t.element(find.byType(SizedBox));
      expect(ChatNav.routes['blood_donor']!(ctx), isA<BloodHubScreen>());
      expect(ChatNav.routes['blood_panel']!(ctx), isA<BloodHubScreen>());
      expect(FeatureFlags.featureOf('blood_donor'), 'blood_donors');
      for (final r in ['blood_donor', 'blood']) {
        expect(PushRouting.targetFor(PushPayload({'kind': 'x', 'route': r}))?.chatNavRoute,
            'blood_panel', reason: r);
      }
      expect(ChatNav.detectRoute('open blood donor'), 'blood_panel');
    });

    test('ONE menu entry; hidden for a normal user while OFF', () async {
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      List<String> labels() => [
            for (final s in SidebarSections.allModes)
              for (final i in s.items) i.label(l),
          ];
      expect(labels(), isNot(contains(l.hv2TileBloodDonor)));
      // owner / staff / allow-listed tester: the server sends it as a preview
      FeatureFlags.instance.applyForTest({
        'features': {'blood_donors': true},
        'preview': ['blood_donors'],
      });
      expect(FeatureFlags.instance.isOn('blood_donors'), isTrue);
      // exactly ONE blood donor entry, named "Blood donor" like everywhere
      // else (launchsweep2); the old registry names are not in the menu
      expect(labels().where((x) => x == l.hv2TileBloodDonor).length, 1);
      expect(labels(), isNot(contains(l.bpTitle)));
      expect(labels(), isNot(contains(l.bloodTitle)));
      // ...but the owner's home / Discover match normal users (preview = off)
      expect(FeatureFlags.instance.homeTileAllowed('blood_panel'), isFalse);
      expect(renderableDiscover(kDiscoverFallback).map((c) => c.key),
          isNot(contains('blood_donor')));
      // the owner switches it ON for everyone
      FeatureFlags.instance.applyForTest({
        'features': {'blood_donors': true},
        'preview': <String>[],
      });
      expect(FeatureFlags.instance.homeTileAllowed('blood_panel'), isTrue);
      expect(renderableDiscover(kDiscoverFallback).map((c) => c.key), contains('blood_donor'));
      // normal user, flag OFF
      FeatureFlags.instance.applyForTest({
        'features': {'blood_donors': false},
        'preview': <String>[],
      });
      expect(FeatureFlags.instance.routeAllowed('blood_panel'), isFalse);
      expect(FeatureFlags.instance.routeAllowed('blood_donor'), isFalse);
      expect(labels(), isNot(contains(l.hv2TileBloodDonor)));
    });

    test('NO ads anywhere in blood donor', () {
      for (final s in ['blood_panel', 'blood_hub', 'blood_saved', 'blood_request',
          'blood_thread', 'blood_setup', 'blood_verify', 'blood_banks', 'blood_donor']) {
        expect(AdPlacements.neverScreens, contains(s), reason: s);
        expect(AdRules.isBlockedScreen(s), isTrue, reason: s);
      }
    });
  });

  group('home + Discover (2 Nov decisions)', () {
    test('SOS tile opens the Emergency hub; Blood donor right after SOS', () {
      expect(HomeV2Shortcuts.openRoute('emergency'), 'emergency_hub');
      expect(kHomeSosRoute, kDiscoverSosRoute);
      FeatureFlags.instance.debugOverride = {'blood_donors': true};
      final d = HomeV2Shortcuts.defaults();
      expect(d.indexOf('blood_panel'), d.indexOf('emergency') + 1);
    });

    test('Discover lead order: SOS, Train, Live Location, Destination Alarm, Blood donor', () {
      FeatureFlags.instance.debugOverride = {
        'train_tracker': true, 'dest_alarm': true, 'blood_donors': true, 'safe_journey': true,
      };
      final keys = renderableDiscover(kDiscoverFallback).map((c) => c.key).toList();
      expect(keys.take(5), ['sos', 'train_tracker', 'journey', 'dest_alarm', 'blood_donor']);
      expect(kDiscoverFallback[2].route, 'journey');
      // the "opened cards move back" personalisation never moves them
      for (final c in kDiscoverFallback.take(5)) {
        expect(discoverMovable(c), isFalse, reason: c.key);
      }
      expect(discoverMovable(kDiscoverFallback[5]), isTrue);
      // flags OFF: SOS then Live Location
      FeatureFlags.instance.debugOverride = {
        'train_tracker': false, 'dest_alarm': false, 'blood_donors': false,
      };
      expect(renderableDiscover(kDiscoverFallback).take(2).map((c) => c.key),
          ['sos', 'journey']);
    });

    testWidgets('fallback titles are the Safe Journey final names', (t) async {
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      expect(kDiscoverFallback[2].title(l, 'en'), l.discoverLiveTitle);
      expect(kDiscoverFallback[3].title(l, 'en'), l.discoverDestTitle);
      expect(l.discoverLiveTitle, 'Live Location');
      expect(l.discoverDestTitle, 'Destination Alarm');
    });
  });
}
