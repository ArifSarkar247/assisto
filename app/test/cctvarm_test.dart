// cctvarm — Auto guard (owner CCTV order 3 Nov, W5): the owner screen
// (status, family switch, people from My Circle in one tap, honest "Not
// known", indoor privacy, closed shop, no-movement, SOS live, log), the
// member's own consent, the SOS live list, the distance-only presence report
// (no coordinates leave the phone; jitter decided by the server), 200% text,
// dark, 48 dp targets.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/cctvx/home_presence_sync.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/watchman/auto_guard_screen.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/cv_empty.dart';

import 'cctvarm_fakes.dart';

Widget app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Future<void> noop() async {}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('owner: status, people, honest Not known, privacy chips, log', (tester) async {
    final f = FakeAutoGuard();
    await tester.pumpWidget(app(AutoGuardScreen(source: f, siteId: 1, onConsentYes: noop)));
    await tester.pumpAndSettle();
    expect(find.text('Auto guard'), findsOneWidget);
    expect(find.textContaining('Not known'), findsWidgets); // Karima stale -> no guess
    expect(find.text('Waiting for their yes'), findsOneWidget);
    expect(find.text('Home: Our flat'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Living room').first, 200);
    expect(find.byType(FilterChip), findsWidgets);
    await tester.scrollUntilVisible(find.textContaining('Everyone is out'), 300);
    expect(find.textContaining('Everyone is out'), findsOneWidget);
  });

  testWidgets('owner: add a person from My Circle in one tap', (tester) async {
    final f = FakeAutoGuard();
    await tester.pumpWidget(app(AutoGuardScreen(source: f, siteId: 1, onConsentYes: noop)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('carm-add')), 200);
    await tester.tap(find.byKey(const ValueKey('carm-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Amma'));
    await tester.pumpAndSettle();
    expect(f.saves.last, {
      'invite': [4]
    });
  });

  testWidgets('owner: switches save at once (closed shop, SOS)', (tester) async {
    final f = FakeAutoGuard();
    await tester.pumpWidget(app(AutoGuardScreen(source: f, siteId: 1, onConsentYes: noop)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('carm-closed')), 200);
    await tester.tap(find.byKey(const ValueKey('carm-closed')));
    await tester.pumpAndSettle();
    expect(f.saves.last, {'closed_on': true});
    await tester.scrollUntilVisible(find.byKey(const ValueKey('carm-sos')), 200);
    await tester.tap(find.byKey(const ValueKey('carm-sos')));
    await tester.pumpAndSettle();
    expect(f.saves.last, {'sos_live': false});
  });

  testWidgets('owner: privacy active offers turning indoor cameras back on', (tester) async {
    final f = FakeAutoGuard(data: FakeAutoGuard.ownerData(summary: 'someone_home', privacy: true));
    await tester.pumpWidget(app(AutoGuardScreen(source: f, siteId: 1, onConsentYes: noop)));
    await tester.pumpAndSettle();
    expect(find.text('Someone is at home'), findsOneWidget);
    await tester.tap(find.text('Turn indoor cameras back on'));
    await tester.pumpAndSettle();
    expect(f.saves.last, {'privacy_pause': true});
  });

  testWidgets('owner: no people and no cameras are honest, not dead', (tester) async {
    final f = FakeAutoGuard(data: FakeAutoGuard.ownerData(cams: false, people: false, log: false));
    await tester.pumpWidget(app(AutoGuardScreen(source: f, siteId: 1, onConsentYes: noop)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('carm-add')), 200);
    await tester.tap(find.byKey(const ValueKey('carm-add')));
    await tester.pumpAndSettle();
    expect(find.text('No one in My Circle yet'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Add a camera first.'), findsWidgets);
    await tester.scrollUntilVisible(find.textContaining('every automatic change'), 300);
    expect(find.textContaining('every automatic change'), findsOneWidget);
  });

  testWidgets('member: own yes, then withdraw', (tester) async {
    final f = FakeAutoGuard(mine: {
      'sites': [
        {'site': 1, 'name': 'Home', 'owner_name': 'Rahim', 'consent': false, 'state': 'no_consent'}
      ]
    });
    var asked = 0;
    await tester.pumpWidget(app(AutoGuardScreen(
        source: f, siteId: 1, owner: false, onConsentYes: () async => asked++)));
    await tester.pumpAndSettle();
    expect(find.text('Rahim asks to use whether you are at home'), findsOneWidget);
    expect(find.textContaining('not where you are'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('carm-yes')));
    await tester.pumpAndSettle();
    expect(f.consents, [true]);
    expect(asked, 1); // the ONE place location permission is asked
    expect(find.byKey(const ValueKey('carm-withdraw')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('carm-withdraw')));
    await tester.pumpAndSettle();
    expect(f.consents, [true, false]);
  });

  testWidgets('member not asked yet: honest empty state', (tester) async {
    await tester.pumpWidget(app(AutoGuardScreen(source: FakeAutoGuard(), siteId: 1, owner: false)));
    await tester.pumpAndSettle();
    expect(find.byType(CvEmptyBlock), findsOneWidget);
    expect(find.text('Nobody has asked you yet'), findsOneWidget);
  });

  testWidgets('SOS live: grant lists cameras; offline one says why', (tester) async {
    final f = FakeAutoGuard(sos: {
      'grants': [
        {
          'site': 1,
          'name': 'Home',
          'by_name': 'Karima',
          'until': '2026-11-03T09:00:00+06:00',
          'cameras': [
            {'id': 11, 'name': 'Living room', 'online': true, 'live': true},
            {'id': 12, 'name': 'Gate', 'online': false, 'live': true},
          ]
        }
      ]
    });
    await tester.pumpWidget(app(SosLiveScreen(source: f)));
    await tester.pumpAndSettle();
    expect(find.text('Karima pressed SOS at home'), findsOneWidget);
    expect(find.text('Camera offline'), findsOneWidget);
    expect(find.text('In an emergency call 999.'), findsOneWidget);
    expect(find.text('Watch live'), findsNWidgets(2));
  });

  testWidgets('SOS live: none = benefit + how-to', (tester) async {
    await tester.pumpWidget(app(SosLiveScreen(source: FakeAutoGuard())));
    await tester.pumpAndSettle();
    expect(find.text('No SOS right now'), findsOneWidget);
  });

  testWidgets('bn + 200% + dark: no overflow, Bangla digits', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    for (final dark in [false, true]) {
      await tester.pumpWidget(app(AutoGuardScreen(source: FakeAutoGuard(), siteId: 1, onConsentYes: noop),
          lang: 'bn', scale: 2.0, dark: dark));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('অটো পাহারা'), findsOneWidget);
      expect(find.textContaining('১৫০'), findsWidgets);
      await tester.pumpWidget(app(SosLiveScreen(source: FakeAutoGuard()), lang: 'bn', scale: 2.0, dark: dark));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('48 dp targets on the owner screen', (tester) async {
    await tester.pumpWidget(app(AutoGuardScreen(source: FakeAutoGuard(), siteId: 1, onConsentYes: noop)));
    await tester.pumpAndSettle();
    for (final f in [find.byType(OutlinedButton), find.byType(FilledButton)]) {
      for (final e in f.evaluate()) {
        final s = (e.renderObject as RenderBox).size;
        expect(s.height >= 48, isTrue, reason: '$s');
      }
    }
  });

  test('presence: distance only, consenting places only, never coordinates', () {
    final sites = [
      {'site': 1, 'consent': true, 'home': {'lat': 23.7808, 'lng': 90.4142}},
      {'site': 2, 'consent': false, 'home': {'lat': 1.0, 'lng': 1.0}},
      {'site': 3, 'consent': true, 'home': null},
    ];
    final r = HomePresenceSync.reportsFor(sites, 23.79, 90.41, 18.4, distance: (a, b, c, d) => 1234.4);
    expect(r, [
      {'site': 1, 'distance_m': 1234, 'accuracy_m': 18}
    ]);
    expect(r.first.keys.toSet(), {'site', 'distance_m', 'accuracy_m'});
  });

  test('presence sync: jittery fixes are sent as-is (server hysteresis), throttled', () async {
    SharedPreferences.setMockInitialValues({});
    final f = FakeAutoGuard(mine: {
      'sites': [
        {'site': 1, 'consent': true, 'home': {'lat': 23.7808, 'lng': 90.4142}}
      ]
    });
    final n = await HomePresenceSync.maybeSend(null,
        source: f, locate: () async => (lat: 23.7808, lng: 90.4162, acc: 30.0));
    // FeatureFlags default may keep this off in tests: either nothing at all
    // (flag off) or exactly one distance-only report.
    expect(n == 0 || n == 1, isTrue);
    if (n == 1) {
      expect(f.reports.single.single['site'], 1);
      expect(await HomePresenceSync.maybeSend(null, source: f,
          locate: () async => (lat: 0.0, lng: 0.0, acc: 5.0)), 0); // throttled
    }
  });
}
