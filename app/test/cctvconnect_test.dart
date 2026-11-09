// cctvconnect (CCTV Guard V3 A1 + B): brand-cloud connect flow, the
// same-Wi-Fi empty state (never a dead end), the channel picker, and the
// daily DVR check card — bn / en, 200 % text, dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/cctvconnect/cctv_connect_screen.dart';
import 'package:assisto/cctvconnect/dvr_health_card.dart';
import 'package:assisto/cctvconnect/link_devices_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';

import 'cctvconnect_fakes.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
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
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('brands + linked DVR; connect sheet sends serial + code, then the picker opens',
      (tester) async {
    _tall(tester);
    final src = FakeCctvConnect();
    await tester.pumpWidget(_app(CctvConnectScreen(siteId: 3, source: src, onFindOnWifi: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Hikvision Hik-Connect'), findsWidgets);
    expect(find.byKey(const ValueKey('ccnBrand-ezviz')), findsOneWidget);
    expect(find.byKey(const Key('ccnWifi')), findsOneWidget); // the Wi-Fi path is always there
    await tester.tap(find.byKey(const ValueKey('ccnBrand-ezviz')));
    await tester.pumpAndSettle();
    // no consent yet: the Connect button is off
    expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('ccnConnect'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('ccnConsent')));
    await tester.pumpAndSettle();
    // empty -> asks for both, never calls the server
    await tester.tap(find.byKey(const Key('ccnConnect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ccnMsg')), findsOneWidget);
    expect(src.calls.where((c) => c.startsWith('link:')), isEmpty);
    await tester.enterText(find.byKey(const Key('ccnSerial')), 'SIMEZDVR1');
    await tester.enterText(find.byKey(const Key('ccnCode')), 'ABC123');
    await tester.tap(find.byKey(const Key('ccnConnect')));
    await tester.pumpAndSettle();
    expect(src.calls, contains('link:ezviz:3:SIMEZDVR1:ABC123:consent'));
    expect(find.byType(CctvLinkDevicesScreen), findsOneWidget);
  });

  testWidgets('Imou: one tap opens the vendor consent page in the browser', (tester) async {
    _tall(tester);
    final src = FakeCctvConnect();
    Uri? opened;
    await tester.pumpWidget(_app(CctvConnectScreen(
        siteId: 3,
        source: src,
        onFindOnWifi: () {},
        openUrl: (u) async {
          opened = u;
          return true;
        })));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ccnOauth-ezviz')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ccnOauth-imou')));
    await tester.pumpAndSettle();
    expect(src.calls, contains('oauth:imou:3'));
    expect(opened.toString(), contains('/cctv/connect/oauth/go?state='));
    expect(find.textContaining('89'), findsOneWidget); // permission days left
  });

  testWidgets('a wrong code shows the server words in the sheet', (tester) async {
    _tall(tester);
    final src = FakeCctvConnect()
      ..linkError = ApiException('The serial number or label code did not match.', 422);
    await tester.pumpWidget(_app(CctvConnectScreen(siteId: 3, source: src, onFindOnWifi: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ccnBrand-imou')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ccnConsent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ccnSerial')), 'X1');
    await tester.enterText(find.byKey(const Key('ccnCode')), 'BAD1');
    await tester.tap(find.byKey(const Key('ccnConnect')));
    await tester.pumpAndSettle();
    expect(find.text('The serial number or label code did not match.'), findsOneWidget);
  });

  testWidgets('no brand cloud yet: benefit + big Wi-Fi button (no dead end), bn', (tester) async {
    _tall(tester);
    var tapped = false;
    await tester.pumpWidget(_app(
        CctvConnectScreen(
            siteId: 3,
            source: FakeCctvConnect(lang: 'bn', noProviders: true, noLinks: true),
            onFindOnWifi: () => tapped = true),
        lang: 'bn'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ccnEmpty')), findsOneWidget);
    final t = await AppLocalizations.delegate.load(const Locale('bn'));
    await tester.tap(find.text(t.ccnFindOnWifi));
    expect(tapped, isTrue);
  });

  testWidgets('remove link asks first, then revokes', (tester) async {
    _tall(tester);
    final src = FakeCctvConnect();
    await tester.pumpWidget(_app(CctvConnectScreen(siteId: 3, source: src)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ccnRemove-5')));
    await tester.pumpAndSettle();
    expect(src.calls.where((c) => c.startsWith('revoke')), isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove link'));
    await tester.pumpAndSettle();
    expect(src.calls, contains('revoke:5'));
  });

  testWidgets('channel picker: added channel locked, online ones pre-ticked, import',
      (tester) async {
    _tall(tester);
    final src = FakeCctvConnect();
    await tester.pumpWidget(_app(CctvLinkDevicesScreen(source: src, linkId: 5)));
    await tester.pumpAndSettle();
    final added = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('ccnCh-SIMHKDVR0001-1')));
    expect(added.onChanged, isNull);
    final offline = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('ccnCh-SIMHKDVR0001-4')));
    expect(offline.value, isFalse);
    expect(find.text('Add selected cameras (2)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ccnImport')));
    await tester.pumpAndSettle();
    expect(src.calls, contains('import:5:2'));
    expect(find.byKey(const Key('ccnResult')), findsOneWidget);
  });

  testWidgets('DVR check card: green / red with what-to-do, 200% text, dark, target days',
      (tester) async {
    final red = FakeCctvConnect(healthStatus: 'red');
    await tester.pumpWidget(_app(
        Scaffold(body: ListView(children: [DvrHealthCard(siteId: 1, source: red, initiallyOpen: true)])),
        scale: 2.0,
        dark: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Needs attention'), findsWidgets);
    expect(find.textContaining('What to do'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('dvrHealthTarget')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ccnDays-30')));
    await tester.pumpAndSettle();
    expect(red.calls, contains('target:1:30'));

    final green = FakeCctvConnect(lang: 'bn');
    await tester.pumpWidget(_app(
        Scaffold(body: ListView(children: [DvrHealthCard(siteId: 2, source: green, owner: false)])),
        lang: 'bn'));
    await tester.pumpAndSettle();
    final t = await AppLocalizations.delegate.load(const Locale('bn'));
    expect(find.text(t.ccnHealthGreen), findsOneWidget);
    expect(find.byKey(const Key('dvrHealthTarget')), findsNothing); // viewers cannot change it
    expect(find.textContaining('১২'), findsOneWidget); // Bangla digits
  });
}
