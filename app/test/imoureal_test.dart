// imou-real (owner 17 Nov): before the serial + code sheet the app shows
// "remove it from Imou Life / EZVIZ / DMSS first" with our own drawings —
// bn / en, 200 % text, dark; cancel never opens the code sheet; an approved
// no-delete path (server switch) says so on the brand tile.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/cctvconnect/cctv_connect_screen.dart';
import 'package:assisto/cctvconnect/remove_first_sheet.dart';
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
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('Imou: the remove-first guide comes BEFORE the serial + code sheet', (tester) async {
    _tall(tester);
    final src = FakeCctvConnect(guides: true);
    await tester.pumpWidget(_app(CctvConnectScreen(siteId: 3, source: src, onFindOnWifi: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ccnBrand-imou')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ccnBeforeSheet')), findsOneWidget);
    expect(find.text('First remove the camera from Imou Life'), findsOneWidget);
    expect(find.byKey(const Key('ccnSerial')), findsNothing);
    expect(find.byKey(const Key('crfStep3')), findsOneWidget);       // 4 steps
    await tester.tap(find.byKey(const Key('ccnBeforeGo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ccnSerial')), findsOneWidget);
  });

  testWidgets('cancel on the guide never opens the code sheet', (tester) async {
    _tall(tester);
    final src = FakeCctvConnect(guides: true);
    await tester.pumpWidget(_app(CctvConnectScreen(siteId: 3, source: src, onFindOnWifi: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ccnBrand-dolynk')));
    await tester.pumpAndSettle();
    expect(find.text('First remove the device from DMSS'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ccnBeforeCancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ccnSerial')), findsNothing);
    expect(src.calls.where((c) => c.startsWith('link:')), isEmpty);
  });

  testWidgets('a brand without a guide (Hik-Connect) goes straight to the code sheet', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(CctvConnectScreen(
        siteId: 3, source: FakeCctvConnect(guides: true), onFindOnWifi: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ccnBrand-hikconnect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ccnBeforeSheet')), findsNothing);
    expect(find.byKey(const Key('ccnSerial')), findsOneWidget);
  });

  testWidgets('EZVIZ guide asks to turn Image Encryption off; Bangla digits', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(const Scaffold(body: CctvRemoveFirstSheet(guide: 'ezviz_app')),
        lang: 'bn'));
    await tester.pumpAndSettle();
    expect(find.text('আগে EZVIZ অ্যাপ থেকে ক্যামেরাটি সরান'), findsOneWidget);
    expect(find.textContaining('Image Encryption'), findsWidgets);
    expect(find.text('৫'), findsOneWidget);              // step numbers in Bangla digits
    expect(find.text('5'), findsNothing);
  });

  for (final g in ['imou_life', 'ezviz_app', 'dmss']) {
    testWidgets('$g: 200 % text + dark, no overflow, 48 dp buttons', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(Scaffold(body: CctvRemoveFirstSheet(guide: g)),
          lang: 'bn', scale: 2.0, dark: true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final go = tester.getSize(find.byKey(const Key('ccnBeforeGo')));
      expect(go.height, greaterThanOrEqualTo(48));
      final cancel = tester.getSize(find.byKey(const Key('ccnBeforeCancel')));
      expect(cancel.height, greaterThanOrEqualTo(48));
    });
  }

  testWidgets('unknown guide id = no sheet (true at once)', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(_app(Builder(builder: (c) {
      ctx = c;
      return const SizedBox.shrink();
    })));
    expect(await showRemoveFirstSheet(ctx, ''), isTrue);
    expect(await showRemoveFirstSheet(ctx, 'other'), isTrue);
  });

  testWidgets('approved no-delete path (server switch) leads on the Imou tile', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(CctvConnectScreen(
        siteId: 3, source: FakeCctvConnect(guides: true, leadImou: true), onFindOnWifi: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Recommended — no need to delete it from your app'), findsOneWidget);
    expect(find.text('Serial number + label code (remove it from the brand app first)'),
        findsNWidgets(2));                                   // EZVIZ + DoLynk
  });
}
