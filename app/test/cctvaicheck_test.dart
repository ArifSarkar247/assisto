// cctvaicheck (W4 B3/B4): the per-camera "AI দিয়ে যাচাই" switch (on with a
// key, disabled + honest without one, saves, reverts on failure, the "no AI"
// note only while the check is off) and alert cards with the AI label —
// person seen, probable false alarm, honest "not checked" — in Bangla digits,
// 200% text and dark with no overflow. The alert itself is always listed.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/camera_alert_types.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctvaicheck_fakes.dart';
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

SwitchListTile _tile(WidgetTester tester, String label) => tester.widget<SwitchListTile>(
    find.ancestor(of: find.text(label), matching: find.byType(SwitchListTile)));

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('AI switch: on with a key, the "no AI" note hidden, turning it off saves', (tester) async {
    _tall(tester);
    final src = FakeAiAlertTypes('ready');
    await tester.pumpWidget(_app(CameraAlertTypesScreen(cameraId: 5, cameraName: 'Shop door', source: src)));
    await _settle(tester);
    expect(_tile(tester, 'Check with AI').value, isTrue);
    expect(_tile(tester, 'Check with AI').onChanged, isNotNull);
    expect(find.textContaining('Used this month: 12 / 100'), findsOneWidget);
    expect(find.textContaining('Never video or sound'), findsOneWidget);
    expect(find.textContaining('No AI looks'), findsNothing);
    await tester.tap(find.text('Check with AI'));
    await _settle(tester);
    expect(src.saved.single['ai_check'], isFalse);
    expect(src.saved.single['person'], isTrue);          // the other switches ride along unchanged
    expect(_tile(tester, 'Check with AI').value, isFalse);
    expect(find.textContaining('No AI looks'), findsOneWidget);
  });

  testWidgets('no key: switch disabled and says why', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(CameraAlertTypesScreen(
        cameraId: 5, cameraName: 'Shop door', source: FakeAiAlertTypes('nokey'))));
    await _settle(tester);
    expect(_tile(tester, 'Check with AI').value, isFalse);
    expect(_tile(tester, 'Check with AI').onChanged, isNull);
    expect(find.textContaining('No AI key connected'), findsOneWidget);
  });

  testWidgets('a failed save reverts the AI switch with a message', (tester) async {
    _tall(tester);
    final src = FakeAiAlertTypes('savefail');
    await tester.pumpWidget(_app(CameraAlertTypesScreen(cameraId: 5, cameraName: 'Shop door', source: src)));
    await _settle(tester);
    await tester.tap(find.text('Check with AI'));
    await _settle(tester);
    expect(_tile(tester, 'Check with AI').value, isTrue);
    expect(find.text('Could not save. Check the internet and try again.'), findsOneWidget);
  });

  testWidgets('Bangla: switch title + Bangla digits', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(
        CameraAlertTypesScreen(cameraId: 5, cameraName: 'দরজা', source: FakeAiAlertTypes('ready', lang: 'bn')),
        lang: 'bn'));
    await _settle(tester);
    expect(find.text('AI দিয়ে যাচাই'), findsOneWidget);
    expect(find.textContaining('এই মাসে ব্যবহার ১২ / ১০০'), findsOneWidget);
  });

  testWidgets('alert cards carry the AI label; every alert is still listed', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(WatchmanAlertsScreen(source: FakeWatchmanAi(), siteId: 1, owner: true)));
    await _settle(tester, 20);
    expect(find.text('AI: Person seen 92%'), findsOneWidget);
    expect(find.textContaining('Probably a false alarm'), findsOneWidget);
    expect(find.textContaining('AI not checked'), findsOneWidget);
  });

  testWidgets('alert cards in Bangla', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(
        WatchmanAlertsScreen(source: FakeWatchmanAi(lang: 'bn'), siteId: 1, owner: true), lang: 'bn'));
    await _settle(tester, 20);
    expect(find.text('AI: মানুষ দেখা গেছে ৯২%'), findsOneWidget);
    expect(find.textContaining('সম্ভবত ভুল সতর্কতা'), findsOneWidget);
    expect(find.textContaining('এই মাসের AI সীমা শেষ'), findsOneWidget);
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('200% text, $lang, dark=$dark: no overflow', (tester) async {
        tester.view.physicalSize = const Size(1080, 2340);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_app(
            CameraAlertTypesScreen(cameraId: 5, cameraName: 'Gate', source: FakeAiAlertTypes('ready', lang: lang)),
            lang: lang, scale: 2.0, dark: dark));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(_app(
            WatchmanAlertsScreen(source: FakeWatchmanAi(lang: lang), siteId: 1, owner: true),
            lang: lang, scale: 2.0, dark: dark));
        await _settle(tester, 20);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
