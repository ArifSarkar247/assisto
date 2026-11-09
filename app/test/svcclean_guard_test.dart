// svcclean — PERMANENT GUARD (owner order 10 Nov 00:45, "never again"):
// All Services showed "Emergency hub" AND "Emergency" as two tiles. This test
// FAILS the build when:
//  (a) two tiles mean the same thing — the same screen, the same route, or the
//      same feature flag (only the listed, reasoned pairs are allowed);
//  (b) a tile name is cut ("...") at 360 dp in Bangla or English, at default
//      and at large font sizes (All Services and the Home shortcut tiles);
//  (c) a tile opens a stub — no screen, a blank screen, "not available" while
//      ON, or a "coming soon / next update" promise (the no-showpieces rule).
// Plus: Family & Safety is EXACTLY the owner's 8 tiles, every category stays
// small, and every old route / saved shortcut of a merged tile lands in the
// one new place.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/emergency_hub_screen.dart';
import 'package:assisto/screens/home_v2/all_services_screen.dart'
    show kAllServicesFourColMaxScale;
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/screens/home_v2/home_v2_tokens.dart';
import 'package:assisto/screens/merged/phone_tiles.dart';
import 'package:assisto/screens/merged/service_sections_screen.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/a11y_prefs.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/feature_unavailable.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';
import 'package:assisto/widgets/home_suggestions.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

import 'app_fonts.dart';
import 'fake_api.dart';

final ff = FeatureFlags.instance;

/// Every feature ON (what the owner ships on 8 Nov: all features on).
void _allOn() => ff.debugOverride = {for (final k in kFeatureDefaults.keys) k: true};

/// Two tiles may share ONE feature flag only when they are two different
/// jobs that the server switches together. Each pair has its reason; any
/// other shared flag fails.
const _sharedFlagOk = <String, String>{
  'money': 'Accounts (my own books) vs My dues (what I owe shops)',
  'booking_bot': 'My bookings (customer) vs Bookings (my business side)',
  'retention_auto': 'Retention (business sends) vs Shop messages (customer reads)',
  'anti_theft': 'Lost phone (after loss) vs Phone safety (before loss) — owner list',
};

/// Showpiece phrases (the no-showpieces rule).
final _promise = RegExp(
    r'coming soon|next (app )?update|future update|later version|শীঘ্রই আসছে|পরের আপডেটে',
    caseSensitive: false);

Future<AppLocalizations> _l(String lang) =>
    AppLocalizations.delegate.load(Locale(lang));

Widget _app(Widget home, {String lang = 'en', double scale = 1, bool dark = false}) {
  final app = AppState()
    ..api = FakeApi(lang: lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<Updater>(create: (_) => Updater()),
    ],
    child: A11yScope(
     prefs: A11yPrefs(),
     child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (ctx, w) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: w!),
      home: home,
    ),
    ),
  );
}

/// Timers / channels a screen started must end before the test ends.
Future<void> _drain(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  RealtimeChannel.instance.resetForTest();
  CallRuntime.instance.resetForTest();
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(seconds: 1));
    t.takeException();
  }
  for (var i = 0; i < 3; i++) {
    await t.pump(const Duration(minutes: 1));
    t.takeException();
  }
}

/// The All Services grids exactly as the screen lays them out at 360 dp.
Widget _grids(List<(String, List<String>)> groups, {required int columns}) =>
    Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HV2.pagePad),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final g in groups) ...[
              Text(g.$1),
              HV2Grid(columns: columns, children: [
                for (final l in g.$2)
                  HomeV2Tile(
                      key: ValueKey('g-${g.$1}-$l'),
                      route: l,
                      icon: Icons.circle,
                      label: l,
                      onTap: () {}),
              ]),
            ],
          ]),
        ),
      ),
    );

/// Names cut with "..." inside the pumped tiles.
List<String> _cut(WidgetTester t) {
  final out = <String>[];
  for (final e in find
      .descendant(of: find.byType(HomeV2Tile), matching: find.byType(RichText))
      .evaluate()) {
    final r = e.renderObject;
    if (r is RenderParagraph && r.didExceedMaxLines) {
      out.add(r.text.toPlainText());
    }
  }
  return out;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 150));
  }
}

bool _benign(Object e) =>
    e is MissingPluginException ||
    e is PlatformException ||
    e.toString().contains('HttpException') ||
    e.toString().contains('SocketException') ||
    e.toString().contains('ApiException') ||
    e.toString().contains('overflowed');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    Settings.resetForTest();
    ff.resetForTest();
    _allOn();
  });
  tearDown(() => ff.resetForTest());

  group('(a) one job = one tile', () {
    testWidgets('no two tiles open the same screen, route or (unlisted) flag',
        (t) async {
      await t.pumpWidget(const SizedBox());
      final ctx = t.element(find.byType(SizedBox));
      final en = await _l('en');
      final byScreen = <Type, List<String>>{};
      final byRoute = <String, List<String>>{};
      final byFlag = <String, List<String>>{};
      for (final s in SidebarSections.allModes) {
        for (final i in s.items) {
          final name = '${s.id}/${i.tileLabel(en)}';
          byScreen.putIfAbsent(i.builder(ctx).runtimeType, () => []).add(name);
          if (i.route != null) byRoute.putIfAbsent(i.route!, () => []).add(name);
          if (i.feature != null) byFlag.putIfAbsent(i.feature!, () => []).add(name);
        }
      }
      final bad = <String>[
        for (final e in byScreen.entries)
          if (e.value.length > 1) 'same screen ${e.key}: ${e.value}',
        for (final e in byRoute.entries)
          if (e.value.length > 1) 'same route ${e.key}: ${e.value}',
        for (final e in byFlag.entries)
          if (e.value.length > 1 && !_sharedFlagOk.containsKey(e.key))
            'same feature ${e.key}: ${e.value}',
        for (final e in byFlag.entries)
          if (e.value.length > 2) 'feature ${e.key} on ${e.value.length} tiles',
      ];
      // the same NAME twice is the owner's exact complaint
      final names = <String, int>{};
      for (final lang in ['en', 'bn']) {
        final l = await _l(lang);
        names.clear();
        for (final s in SidebarSections.allModes) {
          for (final i in s.items) {
            final n = i.tileLabel(l).trim().toLowerCase();
            names[n] = (names[n] ?? 0) + 1;
          }
        }
        for (final e in names.entries) {
          if (e.value > 1) bad.add('$lang: name "${e.key}" on ${e.value} tiles');
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('Family & Safety is EXACTLY the owner\'s 8 tiles, in order', () async {
      final en = await _l('en');
      final fs = SidebarSections.allModes.firstWhere((s) => s.id == 'family_safety');
      expect(fs.items.map((i) => i.tileLabel(en)).toList(), [
        en.moduleFamily,
        en.ccTitle,
        en.journeyHubTitle,
        en.svcEmergency,
        en.svcLostPhone,
        en.svcPhoneSafety,
        en.scamTitle,
        en.svcCctvWatch,
      ]);
      // Emergency carries the red route colour
      expect(fs.items[3].route, 'emergency');
    });

    test('every category stays small (about 8 tiles)', () {
      for (final s in SidebarSections.allModes) {
        expect(s.items.length, lessThanOrEqualTo(10), reason: s.id);
      }
    });

    test('merged tiles keep every feature: sections count as menu entries', () {
      final feats = {
        for (final s in SidebarSections.allModes)
          for (final i in s.items) ...i.features,
      };
      for (final f in ['nominee', 'probashi_plan', 'fall_detect', 'anti_theft',
          'emergency', 'budget_remittance', 'cctv_watchman', 'home_watchman']) {
        expect(feats, contains(f), reason: f);
      }
    });

    test('search finds a merged tile by the old names', () async {
      for (final lang in ['en', 'bn']) {
        final l = await _l(lang);
        for (final old in [l.nominee, l.fallDetectTitle, l.mlpTitle, l.securityTitle,
            l.upSellTitle, l.emhTitle]) {
          expect(SidebarSections.filter(l, old), isNotEmpty, reason: '$lang $old');
        }
      }
    });
  });

  // Lead (10 Nov, b312 home shot): "জরুরি SOS" twice (Discover card + tile),
  // "আমার ব্যবসা" twice (tile + bottom tab), SOS card text cut.
  group('(a) Home: one job = one place (carousel + tiles + bottom bar)', () {
    test('no shortcut tile repeats a bottom-bar tab; tiles unique', () {
      for (final on in [false, true]) {
        if (on) {
          _allOn();
        } else {
          ff.resetForTest();
        }
        final d = HomeV2Shortcuts.defaults();
        final canon = d.map(HomeQuickButtons.canon).toList();
        expect(canon.toSet().length, canon.length, reason: '$d');
        for (final r in HomeV2Shortcuts.bottomNavRoutes) {
          expect(d, isNot(contains(r)), reason: r);
          expect(HomeV2Shortcuts.catalog.map((s) => s.route), isNot(contains(r)),
              reason: r);
        }
      }
    });

    test('a saved My Business tile migrates in place, no empty slot', () {
      final saved = ['family', 'business', 'money'];
      final out = HomeV2Shortcuts.sanitize(saved);
      expect(out.length, saved.length);
      expect(out, isNot(contains('business')));
      expect(out[0], 'family');
      expect(out[2], 'money');
      expect(HomeV2Shortcuts.byRoute(out[1]), isNotNull);
    });

    test('Discover never repeats a tile or tab on the same home', () {
      final shown = {
        for (final r in HomeV2Shortcuts.defaults()) HomeQuickButtons.canon(r),
        ...HomeV2Shortcuts.bottomNavRoutes,
      };
      final cards = withoutHomeTiles(renderableDiscover(kDiscoverFallback), shown);
      for (final c in cards) {
        if (c.route.isEmpty) continue;
        expect(shown, isNot(contains(HomeQuickButtons.canon(c.route))),
            reason: c.key);
      }
      // the SOS card is the Emergency tile's job: not shown twice
      expect(cards.map((c) => c.key), isNot(contains('sos')));
      // a home WITHOUT the Emergency tile still gets the SOS card
      expect(
          withoutHomeTiles(renderableDiscover(kDiscoverFallback), {'family'})
              .map((c) => c.key),
          contains('sos'));
    });

    testWidgets('SOS card text fits whole at 360 dp (bn + en)', (t) async {
      for (final lang in ['en', 'bn']) {
        final l = await _l(lang);
        // 360 dp card text column (see HV2 discover tokens): ~158 dp
        for (final x in [
          (l.emergencySosBigButton, HV2.discoverTitle, 1),
          (l.svcSosCardDesc, HV2.discoverDesc, 2),
        ]) {
          await t.pumpWidget(_app(
              Center(
                child: SizedBox(
                  width: 158,
                  child: Text(x.$1,
                      maxLines: x.$3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: x.$2, height: 1.4)),
                ),
              ),
              lang: lang));
          final r = t.renderObject<RenderParagraph>(find.text(x.$1));
          expect(r.didExceedMaxLines, isFalse, reason: '$lang: ${x.$1}');
        }
      }
    });
  });

  group('old links land in the new place', () {
    testWidgets('routes of merged tiles open the merged screen', (t) async {
      await t.pumpWidget(const SizedBox());
      final ctx = t.element(find.byType(SizedBox));
      Type of(String r) => ChatNav.builderFor(r)!(ctx).runtimeType;
      expect(of('emergency'), EmergencyHubScreen);
      expect(of('emergency_hub'), EmergencyHubScreen);
      expect(of('fall_detect'), EmergencyHubScreen);
      for (final r in ['lost_stolen', 'my_lost_phone']) {
        expect(of(r), LostPhoneTileScreen, reason: r);
      }
      for (final r in ['phone_safety', 'security', 'sell_phone', 'used_phone_check']) {
        expect(of(r), PhoneSafetyTileScreen, reason: r);
      }
      for (final r in ['nominee', 'guardians', 'probashi_plan']) {
        expect(of(r), LandThenOpen, reason: r);
      }
    });

    test('saved home shortcuts of merged tiles migrate to the new tile', () {
      expect(HomeQuickButtons.canon('my_lost_phone'), 'lost_stolen');
      expect(HomeQuickButtons.canon('security'), 'phone_safety');
      expect(HomeQuickButtons.canon('emergency_hub'), 'emergency');
      expect(HomeQuickButtons.canon('nominee'), 'family');
      final out = HomeV2Shortcuts.sanitize(
          ['my_lost_phone', 'lost_stolen', 'emergency_hub', 'sell_phone', 'reminders']);
      expect(out, ['lost_stolen', 'emergency', 'phone_safety', 'reminders']);
      // merged-away tiles are never offered again on their own
      final cat = HomeV2Shortcuts.catalog.map((s) => s.route).toSet();
      for (final r in HomeQuickButtons.mergedAliases.keys) {
        expect(cat, isNot(contains(r)), reason: r);
      }
    });

    testWidgets('an old section route opens that section on top; Back = new place',
        (t) async {
      await t.pumpWidget(_app(ServiceSectionsScreen(
        title: 'Hub',
        intro: 'intro',
        open: 'b',
        sections: [
          ServiceSection(
              id: 'a', icon: Icons.circle, title: 'A', subtitle: 'a',
              builder: (_) => const Scaffold(body: Text('A page'))),
          ServiceSection(
              id: 'b', icon: Icons.circle, title: 'B', subtitle: 'b',
              builder: (_) => Scaffold(appBar: AppBar(), body: const Text('B page'))),
        ],
      )));
      await t.pumpAndSettle();
      expect(find.text('B page'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('svc-intro')), findsOneWidget);
      expect(find.byKey(const ValueKey('svc-a')), findsOneWidget);
    });
  });

  group('(b) no cut tile names at 360 dp', () {
    for (final lang in ['en', 'bn']) {
      for (final scale in [1.0, 1.15, 1.3, 2.0]) {
        testWidgets('All Services $lang x$scale', (t) async {
          t.view.physicalSize = const Size(360 * 3, 4000 * 3);
          t.view.devicePixelRatio = 3;
          addTearDown(t.view.reset);
          final l = await _l(lang);
          final groups = [
            (
              'core',
              [l.sidebarMyCircle, l.aichatTitle]
            ),
            for (final s in SidebarSections.allModes)
              (s.id, [for (final i in s.items) i.tileLabel(l)]),
          ];
          final cols = scale > kAllServicesFourColMaxScale ? 3 : 4;
          await t.pumpWidget(_app(_grids(groups, columns: cols),
              lang: lang, scale: scale));
          await t.pump();
          final cut = _cut(t);
          expect(cut, isEmpty, reason: 'cut at 360 dp $lang x$scale: $cut');
        });
      }
      for (final scale in [1.0, 2.0]) {
        testWidgets('Home shortcut tiles $lang x$scale', (t) async {
          t.view.physicalSize = const Size(360 * 3, 3000 * 3);
          t.view.devicePixelRatio = 3;
          addTearDown(t.view.reset);
          final l = await _l(lang);
          final cols = scale > HV2.threeColumnScale ? 3 : 4;
          await t.pumpWidget(_app(
              _grids([
                ('home', [for (final s in HomeV2Shortcuts.catalog) s.label(l)])
              ], columns: cols),
              lang: lang,
              scale: scale));
          await t.pump();
          final cut = _cut(t);
          expect(cut, isEmpty, reason: 'home cut $lang x$scale: $cut');
        });
      }
    }
  });

  group('(c) no stub behind a tile', () {
    for (final id in [
      for (final s in SidebarSections.allModes) s.id,
    ]) {
      testWidgets('$id: every tile opens a real screen', (t) async {
        t.view.physicalSize = const Size(360 * 3, 760 * 3);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        final sec = SidebarSections.allModes.firstWhere((s) => s.id == id);
        final errors = <String>[];
        for (final i in sec.items) {
          final orig = FlutterError.onError;
          FlutterError.onError = (d) {};
          try {
            await t.pumpWidget(_app(Builder(builder: i.builder), lang: 'bn'));
            await _settle(t);
            final key = '$id/${i.feature ?? i.route ?? sec.items.indexOf(i)}';
            if (find.byType(Scaffold).evaluate().isEmpty) errors.add('$key: no screen');
            if (find.byType(Text).evaluate().isEmpty) errors.add('$key: blank screen');
            if (find.byType(FeatureUnavailableScreen).evaluate().isNotEmpty) {
              errors.add('$key: not-available while ON');
            }
            for (final e in find.byType(Text).evaluate()) {
              final w = e.widget as Text;
              final s = w.data ?? w.textSpan?.toPlainText() ?? '';
              if (_promise.hasMatch(s)) errors.add('$key: promises "$s"');
            }
          } finally {
            final x = t.takeException();
            if (x != null && !_benign(x)) {
              // a crash on open is a broken tile too
              errors.add('$id/${i.feature}: ${x.toString().split('\n').first}');
            }
            await _drain(t);
            FlutterError.onError = orig;
          }
        }
        expect(errors, isEmpty, reason: errors.join('\n'));
      });
    }
  });
}
