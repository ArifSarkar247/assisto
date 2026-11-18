// bizai2: the owner's daily shop summary (server lines shown as-is, chase /
// stock / outcome cards only with data, empty state = benefit + button, the
// 9 pm switch) and the win-back ladder on a Free plan (emulator run: GET
// 402 made the whole screen an error — now readable, with a plans button
// instead of a button that only fails). bn + en, dark, 200% font.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/bizai/biz_daily_screen.dart';
import 'package:assisto/bizai/winback_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';

import 'bizai2_shots.dart';
import 'bizai_fakes.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    MaterialApp(
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
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('daily summary: lines, chase, stock, outcomes, switch', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(_app(BizDailyScreen(
        load: () async => fakeDaily(),
        setOn: (on) async {
          calls.add(on);
          return {'enabled': on};
        })));
    await _settle(tester);
    expect(find.text('Sales today: 2, total ৳800.00.'), findsOneWidget);
    expect(find.text('Remind tomorrow'), findsOneWidget);
    expect(find.textContaining('Karim'), findsOneWidget);
    expect(find.text('Will run out soon'), findsOneWidget);
    expect(find.textContaining('runs out in about 2 days'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('bizai2-daily-switch')), 200);
    expect(find.text('What really came back this week'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('bizai2-daily-switch'))); // gap-bizai
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bizai2-daily-switch')));
    await _settle(tester);
    expect(calls, [false]);
    final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('bizai2-daily-switch')));
    expect(sw.value, isFalse);
  });

  testWidgets('empty day: benefit line + open-khata button, no empty cards', (tester) async {
    await tester.pumpWidget(_app(BizDailyScreen(
        load: () async => fakeDaily(empty: true), setOn: (on) async => {'enabled': on})));
    await _settle(tester);
    expect(find.textContaining('Ring up sales'), findsOneWidget);
    expect(find.text('Open khata'), findsOneWidget);
    expect(find.text('Remind tomorrow'), findsNothing);
    expect(find.text('Will run out soon'), findsNothing);
  });

  testWidgets('Bangla, dark, 200% font: no overflow, Bangla digits', (tester) async {
    await tester.pumpWidget(_app(
        BizDailyScreen(load: () async => fakeDaily(bn: true), setOn: (on) async => {'enabled': on}),
        lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('আজকের দোকানের হিসাব'), findsWidgets);
    expect(find.text('আজ বিক্রি: ২টি, মোট ৳৮০০.০০।'), findsOneWidget);
  });

  testWidgets('load failure: honest error with retry', (tester) async {
    await tester.pumpWidget(_app(BizDailyScreen(load: () async => throw Exception('net'))));
    await _settle(tester);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('win-back on a Free plan: readable, plans button, no approve', (tester) async {
    final f = FakeWinbackFree();
    await tester.pumpWidget(_app(Scaffold(body: WinbackScreen(source: f))));
    await _settle(tester);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('bizai2-ladder-plans')), 200);
    expect(find.text('See the Business plan'), findsOneWidget);
    expect(find.textContaining('Looking is free'), findsOneWidget);
    expect(find.byKey(const ValueKey('bizai-ladder-approve')), findsNothing);
    expect(f.lastApprove, isNull);
  });

  testWidgets('win-back on Business: approve button stays', (tester) async {
    await tester.pumpWidget(_app(Scaffold(body: WinbackScreen(source: FakeWinback()))));
    await _settle(tester);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('bizai-ladder-approve')), 200);
    expect(find.byKey(const ValueKey('bizai2-ladder-plans')), findsNothing);
  });

  test('the 9 pm push and its notification row open the summary', () {
    expect(PushRouting.routeMap['business/daily'], 'biz_daily');
    expect(ChatNav.routes.containsKey('biz_daily'), isTrue);
  });
}
