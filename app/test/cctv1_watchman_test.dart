// cctv1: Home & shop watchman — the real journey on the app side (fake
// server): first run guide → setup wizard → camera check result with honest
// fixes → zones saved → alerts marked Wrong; family viewer is read-only;
// honest offline / hidden / error states; bn + en, dark mode and 200% text
// with NO overflow on every watchman screen.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/watchman_add_camera.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/screens/watchman/watchman_screen.dart';
import 'package:assisto/screens/watchman/watchman_setup.dart';
import 'package:assisto/screens/watchman/watchman_viewers.dart';
import 'package:assisto/screens/watchman/watchman_zones.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctv1_fakes.dart';
import 'cctv1_shots.dart';
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

late AppLocalizations en;

/// A real phone surface (360 dp wide); flows get a tall one so lazy lists
/// build every row.
void _phone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('first run: guide + welcome, then the wizard creates a home', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeWatchman('empty');
    await tester.pumpWidget(_app(WatchmanScreen(source: src)));
    await _settle(tester);
    expect(find.text(en.wmGuideTitle), findsOneWidget);
    expect(find.text(en.wmWelcomeTitle), findsOneWidget);
    await tester.tap(find.text(en.wmStartSetup));
    await _settle(tester);
    // step 1: shop is locked without Business, home is chosen
    expect(find.text(en.wmKindShopNeedsBusiness), findsOneWidget);
    await tester.tap(find.text(en.wmNext));
    await _settle(tester);
    await tester.tap(find.text(en.wmGwPc));
    await tester.tap(find.text(en.wmNext));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Flat');
    await tester.tap(find.text(en.wmCreatePlace));
    await _settle(tester, 20);
    expect(src.calls, contains('setup:home:pc'));
    // the pairing sheet opens with the code
    expect(find.text('PAIR-CODE-FAKE-1'), findsOneWidget);
  });

  testWidgets('shop needs Business: Next stays disabled for shop', (tester) async {
    _phone(tester, height: 2000);
    await tester.pumpWidget(_app(WatchmanSetupScreen(source: FakeWatchman(), canShop: false)));
    await _settle(tester);
    await tester.tap(find.text(en.wmKindShop));
    await tester.pump();
    final next = tester.widget<FilledButton>(find.widgetWithText(FilledButton, en.wmNext));
    expect(next.onPressed, isNull);
  });

  testWidgets('camera check: wrong safety code shows the Imou fix, retry goes back', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeWatchman()..checkOutcome = 'auth';
    await tester.pumpWidget(_app(WatchmanAddCameraScreen(
        source: src, site: const {'id': 1, 'gateway': 'pc'}, limits: const {}, credits: 0,
        pollEvery: const Duration(milliseconds: 10))));
    await _settle(tester);
    await tester.tap(find.text('Imou'));
    await _settle(tester);
    expect(find.text(en.wmHelpImou), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, en.wmCamIp), '192.168.1.20');
    await tester.enterText(find.widgetWithText(TextField, en.wmSecretImou), 'L2WRONG');
    await tester.ensureVisible(find.text(en.wmRunCheck));
    await tester.tap(find.text(en.wmRunCheck));
    await _settle(tester, 20);
    expect(src.calls, containsAll(['addCamera:imou', 'check:21']));
    expect(src.lastCheckBody!['secret'], 'L2WRONG');
    expect(src.lastCheckBody!.containsKey('username'), isFalse); // Imou: always admin
    expect(find.text(en.wmResultFailed), findsOneWidget);
    expect(find.text(en.wmFixAuthImou), findsOneWidget);
    expect(find.text(en.wmStepSkipped), findsOneWidget);
    await tester.tap(find.text(en.wmFixAndRetry));
    await _settle(tester);
    expect(find.text(en.wmRunCheck), findsOneWidget);
    // the secret field was cleared — never kept on the phone after hand-off
    expect(tester.widget<TextField>(find.widgetWithText(TextField, en.wmSecretImou)).controller!.text, '');
  });

  testWidgets('camera check OK offers zones; unreachable says what to fix', (tester) async {
    _phone(tester, height: 2000);
    await tester.pumpWidget(_app(cctv1Shots['wm_check_ok']!('en')));
    await _settle(tester);
    expect(find.text(en.wmResultOk), findsOneWidget);
    expect(find.text(en.wmDrawZonesNow), findsOneWidget);
    expect(find.text(en.wmEventsNotChecked), findsOneWidget);
    await tester.pumpWidget(_app(cctv1Shots['wm_check_no_gateway']!('en')));
    await _settle(tester);
    expect(find.text(en.wmResultNoAnswer), findsOneWidget);
    expect(find.text(en.wmFixGatewayNoAnswer), findsOneWidget);
  });

  testWidgets('zones: draw a no-entry area on the grid and save (schema v2)', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeWatchman();
    await tester.pumpWidget(_app(WatchmanZonesScreen(source: src, camera: FakeWatchman.cameraRow())));
    await _settle(tester);
    expect(find.text(en.wmZonesNoPreview), findsOneWidget);
    final canvas = find.bySemanticsLabel(en.wmZonesCanvasLabel);
    final box = tester.getRect(canvas);
    for (final p in [const Offset(0.6, 0.1), const Offset(0.9, 0.1), const Offset(0.9, 0.5)]) {
      await tester.tapAt(box.topLeft + Offset(box.width * p.dx, box.height * p.dy));
      await tester.pump();
    }
    await tester.tap(find.text(en.wmFinishZone));
    await tester.pump();
    await tester.ensureVisible(find.text(en.wmSave));
    await tester.tap(find.text(en.wmSave));
    await _settle(tester);
    final z = src.savedZones!;
    expect((z['zones'] as List).length, 3);
    final added = (z['zones'] as List).last as Map;
    expect(added['type'], 'restricted');
    expect((added['points'] as List).length, 3);
    expect(z['schedule'], {'days': [0, 1, 2, 3, 4], 'start': '22:00', 'end': '06:00'});
    expect(z['quiet_hours'], {'start': '23:00', 'end': '07:00'});
  });

  testWidgets('alerts: "Suspicious — please check", grouped count, owner marks Wrong', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeWatchman();
    await tester.pumpWidget(_app(WatchmanAlertsScreen(source: src, siteId: 1, owner: true)));
    await _settle(tester);
    expect(find.text(en.wmSuspiciousLabel), findsNWidgets(2));
    expect(find.textContaining(en.wmSeenTimes('3')), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, en.wmWrong).first);
    await _settle(tester);
    expect(src.markedVerdict, 'wrong');
    expect(find.text(en.wmMarkedWrong), findsOneWidget);
  });

  testWidgets('hikvision camera: owner gets its private push link (HTTP Listening)', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeWatchman();
    await tester.pumpWidget(_app(WatchmanScreen(source: src, guide: false)));
    await _settle(tester);
    // the Imou camera has no push link item; the Hikvision one does
    final menus = find.byTooltip(en.wmCameraMenu);
    await tester.tap(menus.first);
    await _settle(tester);
    expect(find.text(en.shopHookTitle), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);
    await tester.ensureVisible(menus.last);
    await tester.tap(menus.last);
    await _settle(tester);
    await tester.tap(find.text(en.shopHookTitle));
    await _settle(tester, 20);
    expect(src.calls, contains('camera:12'));
    expect(find.text(en.shopHookTitle), findsOneWidget);
    expect(find.textContaining('/shop/hook/hikvision/tok12'), findsOneWidget);
    expect(find.textContaining('/shop/hook/dahua/tok12'), findsOneWidget);
  });

  testWidgets('family viewer: read-only alerts, no setup buttons', (tester) async {
    _phone(tester, height: 2000);
    await tester.pumpWidget(_app(WatchmanAlertsScreen(source: FakeWatchman('viewer'), siteId: 1, owner: false)));
    await _settle(tester);
    expect(find.text(en.wmViewerReadOnly), findsOneWidget);
    expect(find.text(en.wmWrong), findsNothing);
    await tester.pumpWidget(_app(WatchmanScreen(source: FakeWatchman('viewer'), guide: false)));
    await _settle(tester);
    expect(find.text(en.wmSharedBy('Rahim')), findsOneWidget);
    expect(find.text(en.wmAddCamera), findsNothing);
    expect(find.text(en.wmConnectGateway), findsNothing);
  });

  testWidgets('honest states: offline gateway, hidden feature, network error', (tester) async {
    _phone(tester, height: 2000);
    await tester.pumpWidget(_app(WatchmanScreen(source: FakeWatchman('offline'), guide: false)));
    await _settle(tester);
    expect(find.textContaining('offline since'), findsOneWidget);
    expect(find.text(en.wmGatewayOfflineHelp), findsOneWidget);
    await tester.pumpWidget(_app(WatchmanScreen(source: FakeWatchman('off'), guide: false)));
    await _settle(tester);
    expect(find.text(en.wmFeatureOffTitle), findsOneWidget);
    final fail = FakeWatchman('fail');
    await tester.pumpWidget(_app(WatchmanScreen(source: fail, guide: false)));
    await _settle(tester);
    expect(find.text(en.wmLoadErrorTitle), findsOneWidget);
    await tester.tap(find.text(en.wmRetry));
    await _settle(tester);
    expect(fail.calls.where((c) => c == 'overview').length, 2);
  });

  testWidgets('viewers: unknown number shows the server reason', (tester) async {
    _phone(tester, height: 2000);
    final src = FakeWatchman();
    await tester.pumpWidget(_app(WatchmanViewersScreen(source: src, siteId: 1)));
    await _settle(tester);
    // the Add button stays disabled until a number is typed
    expect(tester.widget<FilledButton>(find.byWidgetPredicate((w) => w is FilledButton)).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '01799999999');
    await tester.pump();
    await tester.tap(find.text(en.wmFamilyAdd));
    await _settle(tester);
    expect(find.textContaining('No Assisto account'), findsOneWidget);
  });

  // 200% font, bn + en, light + dark: no overflow / layout error anywhere.
  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('every watchman screen at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
        _phone(tester);
        for (final e in cctv1Shots.entries) {
          await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
          await _settle(tester, 8);
          final err = tester.takeException();
          expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
        }
      });
    }
  }
}
