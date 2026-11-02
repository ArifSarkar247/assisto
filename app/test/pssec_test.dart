// pssec: Personal Secretary — on-phone message pick-up parser, the Today
// brief screen (data / empty / fail, bn + en, 200% font, dark) with My Circle
// "Tell / Remind" + Done, and the pick-up sheet (nothing saved until the user
// confirms; the message text itself is never sent).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/ps/ps_extract.dart';
import 'package:assisto/screens/pa/ps_pickup_sheet.dart';
import 'package:assisto/screens/pa/ps_today_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_psec.dart';

class _PsApi extends FakeApi {
  _PsApi({FakeMode mode = FakeMode.data}) : super(mode: mode, lang: 'en');
  final updates = <List<dynamic>>[];
  final creates = <List<dynamic>>[];
  final paths = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    return super.getJson(path);
  }

  @override
  Future<void> updateItem(String path, int id, Map<String, dynamic> body) async {
    updates.add([path, id, body]);
  }

  @override
  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) async {
    creates.add([path, body]);
    return {'id': 99, ...body};
  }
}

AppState _stub(ApiClient api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '', autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(AppState s, Widget home,
        {String lang = 'en', double scale = 1, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: s,
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        darkTheme: AssistoTheme.dark,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (ctx, w) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: w!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('psExtract (on-phone parser)', () {
    final now = DateTime(2026, 10, 13, 10);

    test('blank gives nothing', () {
      expect(psExtract('   ', now: now), isNull);
    });

    test('English meeting with day + time', () {
      final p = psExtract('next Friday 5pm meeting', now: now)!;
      expect(p.kind, PsKind.meeting);
      expect(p.when, DateTime(2026, 10, 16, 17));
      expect(p.dateOnly, isFalse);
    });

    test('Bangla day word, meeting kind', () {
      final p = psExtract('পরশু মিটিং', now: now)!;
      expect(p.kind, PsKind.meeting);
      expect(p.when?.day, 15);
    });

    test('WhatsApp copy: sender becomes the counterpart, its clock is ignored', () {
      final p = psExtract('[13/10/26, 9:41 am] Karim Bhai: call mom at 5pm', now: now)!;
      expect(p.counterpart, 'Karim Bhai');
      expect(p.when, DateTime(2026, 10, 13, 17));
      expect(p.kind, PsKind.reminder);
    });

    test('follow-up words (bn + en)', () {
      expect(psKindOf('Please send the quotation'), PsKind.followup);
      expect(psKindOf('কোটেশনটা পাঠাবেন'), PsKind.followup);
      expect(psKindOf('ওষুধ খেতে হবে'), PsKind.reminder);
    });

    test('only the first line is the task; long text is capped', () {
      final p = psExtract('\n\nBuy rice\nand also oil', now: now)!;
      expect(p.title.contains('oil'), isFalse);
      final long = psExtract('x' * 200, now: now)!;
      expect(long.title.length, lessThanOrEqualTo(80));
    });
  });

  group('PsTodayScreen', () {
    testWidgets('data: sections, clash, Tell / Remind people, Done PATCHes', (tester) async {
      final api = _PsApi();
      await tester.pumpWidget(_app(_stub(api, 'en'), const PsTodayScreen()));
      await _settle(tester);
      expect(api.paths, contains('/ps/today'));
      expect(find.text("Today's meetings"), findsOneWidget);
      expect(find.textContaining('Bank loan meeting'), findsWidgets);
      expect(find.byKey(const ValueKey('ps-tell-7')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('ps-done-21')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('ps-remind-8')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ps-done-21')));
      await _settle(tester);
      expect(api.updates.single[0], 'pa/followups');
      expect(api.updates.single[1], 21);
      expect((api.updates.single[2] as Map)['status'], 'done');
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty: benefit line + big button + how-to', (tester) async {
      await tester.pumpWidget(
          _app(_stub(_PsApi(mode: FakeMode.empty), 'en'), const PsTodayScreen()));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ps-today-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('ps-empty-add')), findsOneWidget);
    });

    testWidgets('fail: honest message + retry', (tester) async {
      await tester.pumpWidget(
          _app(_stub(_PsApi(mode: FakeMode.fail), 'en'), const PsTodayScreen()));
      await _settle(tester);
      final t = AppLocalizations.of(tester.element(find.byType(PsTodayScreen)));
      expect(find.text(t.psecLoadFailed), findsOneWidget);
    });

    for (final dark in [false, true]) {
      testWidgets('bn at 200% font (dark=$dark): no overflow', (tester) async {
        tester.view.physicalSize = const Size(360 * 3, 800 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_app(_stub(_PsApi(), 'bn'), const PsTodayScreen(),
            lang: 'bn', scale: 2, dark: dark));
        await _settle(tester);
        expect(find.text('আজকের ব্রিফ'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('PsPickupSheet', () {
    Future<_PsApi> open(WidgetTester tester, String text) async {
      final api = _PsApi();
      await tester.pumpWidget(_app(
          _stub(api, 'en'),
          Builder(
              builder: (ctx) => Scaffold(
                    body: Center(
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                            builder: (_) => Scaffold(
                                body: PsPickupSheet(
                                    initialText: text,
                                    now: DateTime(2026, 10, 13, 10))))),
                        child: const Text('open'),
                      ),
                    ),
                  ))));
      await tester.tap(find.text('open'));
      await _settle(tester);
      return api;
    }

    testWidgets('meeting proposal → confirm creates one schedule row', (tester) async {
      final api = await open(tester, kPsecShotMessage.replaceAll('Gulshan office', 'office'));
      expect(api.creates, isEmpty); // nothing saved before the user confirms
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('ps-kind-meeting')));
      expect(chip.selected, isTrue);
      expect(find.widgetWithText(TextField, 'Karim Bhai'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('ps-pickup-add')));
      await tester.tap(find.byKey(const ValueKey('ps-pickup-add')));
      await _settle(tester);
      expect(api.creates.single[0], 'pa_schedule');
      final body = api.creates.single[1] as Map;
      expect(body['start'], startsWith('2026-10-16T17:00'));
      expect(body['people'], ['Karim Bhai']);
      expect(body.containsKey('message'), isFalse); // the pasted text is never stored
      expect(find.byType(PsPickupSheet), findsNothing); // closed
    });

    testWidgets('follow-up needs a person before Add is enabled', (tester) async {
      final api = await open(tester, 'Please send the quotation');
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('ps-kind-followup'))).selected,
          isTrue);
      final btn = find.byKey(const ValueKey('ps-pickup-add'));
      expect(btn, findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(btn).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('ps-pickup-who')), 'Lawyer');
      await tester.pump();
      expect(tester.widget<ButtonStyleButton>(btn).onPressed, isNotNull);
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await _settle(tester);
      expect(api.creates.single[0], 'pa/followups');
      expect((api.creates.single[1] as Map)['counterpart'], 'Lawyer');
    });
  });
}
