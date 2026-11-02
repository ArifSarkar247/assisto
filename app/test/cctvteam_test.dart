// cctvteam (W11): multi-site grid (status pills, fresh photo, guard sees only
// the gate), role sheet (a guard needs a camera), share links (make with a
// chosen time, revoke), access log, private neighbourhood watch (send stays
// disabled until the user confirms; report). Bangla digits, 200 % text + dark
// with no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/cctv_grid_screen.dart';
import 'package:assisto/screens/watchman/cctv_team_screens.dart';
import 'package:assisto/screens/watchman/cctv_watch_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctvteam_fakes.dart';
import 'fake_api.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('grid: every place + camera with honest status pills; fresh photo', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final src = FakeCctvTeam('data');
    await tester.pumpWidget(_app(CctvGridScreen(source: src)));
    await _settle(tester);
    expect(find.text('Rahim Store'), findsOneWidget);
    expect(find.byKey(const ValueKey('ctm-tile-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('ctm-tile-6')), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Not connected yet'), findsOneWidget);
    expect(find.text('No photo yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ctm-tile-5')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ctm-live')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ctm-fresh')));
    await _settle(tester);
    expect(src.freshCalls, 1);
    expect(find.text('Fresh photo from the camera.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('grid: a guard sees only the gate', (tester) async {
    await tester.pumpWidget(_app(CctvGridScreen(source: FakeCctvTeam('guard'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ctm-tile-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('ctm-tile-6')), findsNothing);
    expect(find.text('Guard'), findsOneWidget);
  });

  testWidgets('grid: empty state has a benefit line + a big button', (tester) async {
    var setup = 0;
    await tester.pumpWidget(_app(CctvGridScreen(source: FakeCctvTeam('empty'), onSetup: () => setup++)));
    await _settle(tester);
    expect(find.text('No camera to show yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cv-empty-primary')));
    await _settle(tester);
    expect(setup, 1);
  });

  testWidgets('grid: Bangla digits, 200% text and dark without overflow', (tester) async {
    await tester.pumpWidget(_app(CctvGridScreen(source: FakeCctvTeam('data', lang: 'bn')),
        lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('৪ মিনিট'), findsWidgets);
    expect(find.textContaining('4 '), findsNothing);
  });

  testWidgets('role sheet: a guard must get at least one camera', (tester) async {
    final src = FakeCctvTeam('data');
    bool? saved;
    await tester.pumpWidget(_app(_Launcher(
        open: (c) async => saved = await showCctvRoleSheet(c, src,
            siteId: 1,
            viewer: const {'user_id': 12, 'name': 'Jamal', 'role': 'family', 'cameras': [], 'all_cameras': true}))));
    await tester.tap(find.text('open'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ctm-role-guard')));
    await _settle(tester);
    final save = find.byKey(const ValueKey('ctm-role-save'));
    await tester.ensureVisible(save);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('ctm-cam-5')));
    await tester.tap(find.byKey(const ValueKey('ctm-cam-5')));
    await _settle(tester);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await _settle(tester);
    expect(src.roleSaves.single, {'role': 'guard', 'cameras': [5], 'live_ok': false});
    expect(saved, true);
  });

  testWidgets('share links: make one for 24 hours, then revoke another', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final src = FakeCctvTeam('data');
    await tester.pumpWidget(_app(CctvShareLinksScreen(source: src, siteId: 1, siteName: 'Rahim Store')));
    await _settle(tester);
    expect(find.textContaining('Shared until'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ctm-revoke-4')));
    await _settle(tester);
    expect(src.revoked, [4]);
    await tester.tap(find.byKey(const ValueKey('ctm-new-link')));
    await _settle(tester);
    final make = find.byKey(const ValueKey('ctm-link-make'));
    expect(tester.widget<FilledButton>(make).onPressed, isNull); // no camera yet
    await tester.tap(find.byKey(const ValueKey('ctm-link-cam-5')));
    await tester.tap(find.text('24 hours'));
    await _settle(tester);
    await tester.ensureVisible(make);
    await tester.tap(make);
    await _settle(tester);
    expect(src.linksMade.single['hours'], 24);
    expect(src.linksMade.single['cameras'], [5]);
    expect(find.text('https://lifeassisto.com/c/AbCdEfGh12345678'), findsOneWidget);
  });

  testWidgets('access log lists who looked, incl. a share link', (tester) async {
    await tester.pumpWidget(_app(CctvAccessLogScreen(source: FakeCctvTeam('data'), siteId: 1)));
    await _settle(tester);
    expect(find.text('Jamal (guard)'), findsOneWidget);
    expect(find.text('Link: Cousin Rafiq'), findsOneWidget);
    expect(find.textContaining('No Assisto staff'), findsOneWidget);
  });

  testWidgets('neighbourhood watch: never sent without an explicit confirm', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final src = FakeCctvTeam('data');
    await tester.pumpWidget(_app(_Launcher(open: (c) => showCctvWatchShareSheet(c, src, camera: 5))));
    await tester.tap(find.text('open'));
    await _settle(tester);
    final send = find.byKey(const ValueKey('ctm-watch-send'));
    await tester.ensureVisible(send);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    final confirm = find.byKey(const ValueKey('ctm-watch-confirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await _settle(tester);
    await tester.ensureVisible(send);
    await tester.tap(send);
    await _settle(tester);
    expect(src.shares.single['confirm'], true);
    expect(src.shares.single['group'], 21);
    expect(src.shares.single['camera'], 5);
    expect(src.shares.single['hours'], 24);
    expect(find.textContaining('NOT blurred'), findsNothing); // sheet closed
  });

  testWidgets('neighbourhood watch: report a post; empty groups explain how', (tester) async {
    final src = FakeCctvTeam('data');
    await tester.pumpWidget(_app(CctvWatchGroupScreen(source: src, groupId: 21, name: 'Road 3 watch')));
    await _settle(tester);
    await tester.tap(find.text('Report').first);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ctm-report-send')));
    await _settle(tester);
    expect(src.reports, ['31:private:false']);

    await tester.pumpWidget(_app(CctvWatchScreen(source: FakeCctvTeam('empty'))));
    await _settle(tester);
    expect(find.text('No private group yet'), findsOneWidget);
    expect(find.textContaining('Communities'), findsWidgets);
  });
}

/// Opens a sheet the way the app does (a real route, so its pop is real).
class _Launcher extends StatelessWidget {
  final Future<void> Function(BuildContext) open;
  const _Launcher({required this.open});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Builder(
              builder: (c) => TextButton(onPressed: () => open(c), child: const Text('open'))),
        ),
      );
}
