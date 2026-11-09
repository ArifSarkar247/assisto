// cctvroles (CCTV Guard V3 I + J): the audit list (exports / changes / "You",
// filter), the role sheet offers STAFF and says only the owner deletes /
// downloads, the owner's installer screen (code sheet, end with confirm),
// the technician's partner screen (apply gated, pending, setup status only,
// add a place by code). Bangla digits, 200 % text + dark with no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/cctv_installer_screens.dart';
import 'package:assisto/screens/watchman/cctv_team_screens.dart';
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

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('audit list: owner\'s own export says You; filter changes / views', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(CctvAccessLogScreen(source: FakeCctvTeam('audit'), siteId: 1)));
    await _settle(tester);
    expect(find.text('Who viewed or changed what'), findsOneWidget);
    expect(find.text('You'), findsNWidgets(3));
    expect(find.textContaining('Downloaded evidence'), findsOneWidget);
    expect(find.textContaining('Sumon (manager)'), findsOneWidget);
    expect(find.text('Jamal (guard)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ctr-log-change')));
    await _settle(tester);
    expect(find.text('Jamal (guard)'), findsNothing);
    expect(find.textContaining('Deleted'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ctr-log-view')));
    await _settle(tester);
    expect(find.text('Jamal (guard)'), findsOneWidget);
    expect(find.text('You'), findsNothing);
  });

  testWidgets('role sheet: staff is offered and only the owner deletes', (tester) async {
    _tall(tester);
    final src = FakeCctvTeam('data');
    await tester.pumpWidget(_app(Scaffold(
        body: CctvRoleSheet(
            source: src,
            siteId: 1,
            viewer: const {'user_id': 14, 'name': 'Sumon', 'role': 'family', 'cameras': [], 'all_cameras': true}))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ctr-owner-only')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('ctm-role-staff')));
    await tester.tap(find.byKey(const ValueKey('ctm-role-staff')));
    await _settle(tester);
    final save = find.byKey(const ValueKey('ctm-role-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await _settle(tester);
    expect(src.roleSaves.single['role'], 'staff');
  });

  testWidgets('owner installer screen: code sheet, then end with a confirm', (tester) async {
    _tall(tester);
    final src = FakeCctvTeam('data');
    await tester.pumpWidget(_app(CctvInstallerScreen(source: src, siteId: 1)));
    await _settle(tester);
    expect(find.text('Rana CCTV · Mirpur 10'), findsOneWidget);
    expect(find.textContaining('never video'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ctr-inst-end-21')));
    await _settle(tester);
    expect(src.ended, isEmpty); // nothing without the confirm
    await tester.tap(find.byKey(const ValueKey('ctr-inst-end-yes')));
    await _settle(tester);
    expect(src.ended, [21]);
    await tester.ensureVisible(find.byKey(const ValueKey('ctr-inst-make')));
    await tester.tap(find.byKey(const ValueKey('ctr-inst-make')));
    await _settle(tester);
    expect(find.text('K7MP Q2XR'), findsOneWidget);
    expect(find.textContaining('48 hours'), findsOneWidget);
  });

  testWidgets('owner installer screen: empty state has benefit + big button + how-to', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(CctvInstallerScreen(source: FakeCctvTeam('empty'), siteId: 1)));
    await _settle(tester);
    expect(find.text('No installer linked'), findsOneWidget);
    expect(find.text('Make installer code'), findsOneWidget);
  });

  testWidgets('partner: apply is gated until name and area are written', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(CctvPartnerScreen(source: FakeCctvTeam('empty'))));
    await _settle(tester);
    final apply = find.byKey(const ValueKey('ctr-part-apply'));
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('ctr-part-name')), 'Rana CCTV');
    await tester.enterText(find.byKey(const ValueKey('ctr-part-area')), 'Mirpur');
    await _settle(tester);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
  });

  testWidgets('partner: approved sees setup status only and adds a place by code', (tester) async {
    _tall(tester);
    final src = FakeCctvTeam('data');
    await tester.pumpWidget(_app(CctvPartnerScreen(source: src)));
    await _settle(tester);
    expect(find.text('Rahim Store'), findsOneWidget);
    expect(find.textContaining('3 of 4 cameras online'), findsOneWidget);
    expect(find.text('Setup complete · 2 of 2 cameras online'), findsOneWidget);
    expect(find.byType(Image), findsNothing); // never a photo
    final join = find.byKey(const ValueKey('ctr-part-join'));
    expect(tester.widget<FilledButton>(join).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('ctr-part-code')), 'k7mp-q2xr');
    await _settle(tester);
    await tester.tap(join);
    await _settle(tester);
    expect(src.joined, ['k7mp-q2xr']);
  });

  testWidgets('partner pending: honest wait message', (tester) async {
    await tester.pumpWidget(_app(CctvPartnerScreen(source: FakeCctvTeam('pending'))));
    await _settle(tester);
    expect(find.textContaining('Application sent'), findsOneWidget);
  });

  testWidgets('bn + 200 % + dark: Bangla digits, no overflow', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(CctvPartnerScreen(source: FakeCctvTeam('data', lang: 'bn')),
        lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('৪টির মধ্যে ৩টি'), findsOneWidget);
    await tester.pumpWidget(_app(CctvInstallerScreen(source: FakeCctvTeam('data', lang: 'bn'), siteId: 1),
        lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_app(CctvAccessLogScreen(source: FakeCctvTeam('audit', lang: 'bn'), siteId: 1),
        lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('সতর্কতা #২১২-এর প্রমাণ'), findsOneWidget);
  });
}
