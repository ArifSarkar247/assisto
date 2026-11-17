// savesweep (owner P0, 10 Nov 01:20): "Save does nothing" on the owner's
// phone in (a) Family accounting fund goal 15000, (b) Family accounting add
// expense 10000 bazar, (c) Mess and bachelor Add member. The server log showed
// NO request at all: the failure was inside the app. These tests reproduce
// each one exactly and fail on the old code:
//   (a)(b) Bangla keyboard digits (Bangla digits) -> int.tryParse null -> 0 ->
//          `if (p <= 0) return;` — dialog stays, no message, no call.
//   (c)    the sheet padded the keyboard twice (builder ctx outside
//          AppSheetInsets) -> Column overflow -> Save drawn but not tappable.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/famacct_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/mess_accounting_screen.dart';
import 'package:assisto/screens/mess/mess_detail_screen.dart'; // messv2
import 'package:assisto/state.dart';
import 'package:assisto/widgets/app_sheet.dart';
import 'package:assisto/widgets/famacct_sheets.dart';
import 'package:assisto/widgets/num_input.dart';

import 'fake_api.dart';

// Bangla digits from code points (no Bangla glyph literal in source).
String bnDigits(String latin) => String.fromCharCodes(latin.codeUnits
    .map((c) => c >= 0x30 && c <= 0x39 ? 0x09E6 + (c - 0x30) : c));

// messv2: Mess V2 records every POST (create mess, entries, members).
class _MessFake extends FakeApi {
  _MessFake({super.mode}) : super(lang: 'bn');
  final posts = <MapEntry<String, Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(MapEntry(path, body));
    return super.postJson(path, body);
  }
}

Widget _app(Widget home, {String lang = 'bn', AppState? state, double kb = 0}) {
  final app = state ??
      (AppState()
        ..api = FakeApi(lang: lang)
        ..user = AppUser(
            id: 1, name: 'Test', phone: '01700000009', email: '',
            autonomyLevel: 2, language: lang)
        ..locale = Locale(lang)
        ..loading = false);
  return ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx)
            .copyWith(viewInsets: EdgeInsets.only(bottom: kb)),
        child: child!,
      ),
      home: home,
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('shared number parser', () {
    test('Bangla, English, commas, taka sign', () {
      expect(parseNumInput(bnDigits('15000')), 15000);
      expect(parseNumInput('15,000'), 15000);
      expect(parseNumInput(bnDigits('1,50,000.50')), 150000.5);
      expect(parseNumInput('${String.fromCharCode(0x09F3)} ${bnDigits('250')}'), 250);
      expect(parseNumInput('Tk 99'), 99);
      expect(parseNumInput('-12.5'), -12.5);
      expect(parseNumInput(''), isNull);
      expect(parseNumInput('abc'), isNull);
      expect(parseIntInput(bnDigits('10000')), 10000);
      expect(takaToPoishaInput(bnDigits('15000')), 1500000);
      expect(takaToPoishaInput('12.345'), 1235);
      expect(takaToPoishaInput(''), isNull);
      // Arabic-Indic digits (some keyboards) too
      expect(parseIntInput(String.fromCharCodes([0x0661, 0x0662])), 12);
    });

    test('family accounting parser takes Bangla digits (owner bug a/b)', () {
      expect(FamAcctLocal.takaToPoisha(bnDigits('15000')), 1500000);
      expect(FamAcctLocal.takaToPoisha(bnDigits('10,000')), 1000000);
      expect(FamAcctLocal.takaToPoisha('12.50'), 1250);
    });

    test('LatinDigitsFormatter keeps Bangla digits in digits-only fields', () {
      const f = LatinDigitsFormatter();
      final out = FilteringTextInputFormatter.digitsOnly.formatEditUpdate(
          TextEditingValue.empty,
          f.formatEditUpdate(TextEditingValue.empty,
              TextEditingValue(text: bnDigits('1234'))));
      expect(out.text, '1234');
    });
  });

  testWidgets('(a) fund goal: Bangla 15000 saves; empty shows an error',
      (tester) async {
    int? result = -1;
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => result = await showAmountSheet(ctx, 'Goal'),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final t = AppLocalizations.of(tester.element(find.byType(AlertDialog)));
    // empty -> a visible reason, the dialog stays (never a silent dead Save)
    await tester.tap(find.byKey(const ValueKey('fa-amount-save')));
    await tester.pumpAndSettle();
    expect(find.text(t.ssAmountInvalid), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('fa-amount-field')), bnDigits('15000'));
    await tester.tap(find.byKey(const ValueKey('fa-amount-save')));
    await tester.pumpAndSettle();
    expect(result, 1500000);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('(b) add expense: Bangla 10000 + "bazar" returns the body',
      (tester) async {
    Map<String, dynamic>? body;
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => body = await showAddExpenseSheet(ctx, const [
            {'id': 7, 'name': 'Rahim'},
          ]),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('fa-expense-amount')), bnDigits('10000'));
    final t = AppLocalizations.of(tester.element(find.byType(AlertDialog)));
    await tester.enterText(
        find.widgetWithText(TextField, t.faNote), 'bazar');
    await tester.tap(find.byKey(const ValueKey('fa-expense-save')));
    await tester.pumpAndSettle();
    expect(body, isNotNull);
    expect(body!['total_poisha'], 1000000);
    expect(body!['note'], 'bazar');
  });

  // (c) was written for the V1 mess screen; Mess V2 (messv2) replaced it.
  // The same promise on V2: with a Bangla keyboard (330 dp) open on a 6.6"
  // phone, every mess Save is reachable by a finger and really sends —
  // create mess (name), add bazar (Bangla digits), add member from My Circle.
  Widget messApp(_MessFake api, Widget home) {
    final app = AppState()
      ..api = api
      ..user = AppUser(
          id: 1, name: 'Test', phone: '01700000009', email: '',
          autonomyLevel: 2, language: 'bn')
      ..locale = const Locale('bn')
      ..loading = false;
    return ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('bn'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(
            viewPadding: const EdgeInsets.only(top: 24, bottom: 48),
            padding: const EdgeInsets.only(top: 24),
            viewInsets: const EdgeInsets.only(bottom: 330),
          ),
          child: child!,
        ),
        home: home,
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  testWidgets('(c) mess V2 create: Save tappable with the keyboard open',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 2, 850 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final api = _MessFake(mode: FakeMode.empty);
    await tester.pumpWidget(messApp(api, const MessAccountingScreen()));
    await settle(tester);
    // the keyboard leaves little room: scroll the list to the button first
    await tester.scrollUntilVisible(find.byKey(const ValueKey('mess-create')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('mess-create')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('mess-name')), 'Rampura Mess');
    await tester.pump();
    final save = find.byKey(const ValueKey('mess-settings-save'));
    expect(save.hitTestable(), findsOneWidget,
        reason: 'Save is drawn but a tap does not reach it (dead Save)');
    await tester.tap(save.hitTestable());
    await settle(tester);
    expect(api.posts.where((e) => e.key == '/mess/v2').map((e) => e.value['name']),
        ['Rampura Mess']);
  });

  testWidgets('(c) mess V2 bazar: Bangla amount, Save tappable with the keyboard open',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 2, 850 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final api = _MessFake();
    await tester.pumpWidget(
        messApp(api, const MessDetailScreen(messId: 1, initialTab: 1)));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('mess-add-bazar')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('entry-amount')), bnDigits('500'));
    await tester.pump();
    final save = find.byKey(const ValueKey('entry-save'));
    expect(save.hitTestable(), findsOneWidget,
        reason: 'Save is drawn but a tap does not reach it (dead Save)');
    await tester.tap(save.hitTestable());
    await settle(tester);
    final p = api.posts.firstWhere((e) => e.key == '/mess/v2/1/entries');
    expect(p.value['amount'], 50000);
  });

  testWidgets('(c) mess V2 Add member from My Circle really sends', (tester) async {
    tester.view.physicalSize = const Size(393 * 2, 850 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final api = _MessFake();
    await tester.pumpWidget(
        messApp(api, const MessDetailScreen(messId: 1, initialTab: 4)));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('mess-add-member')));
    await settle(tester);
    final row = find.byKey(const ValueKey('mess-pick-8'));
    final add = find.descendant(of: row, matching: find.byType(FilledButton));
    expect(add.hitTestable(), findsOneWidget);
    await tester.tap(add.hitTestable());
    await settle(tester);
    final p = api.posts.firstWhere((e) => e.key == '/mess/v2/1/members');
    expect(p.value['circle_member_id'], 8);
  });

  testWidgets('every showAppSheet builder sees the keyboard inset once',
      (tester) async {
    double? seen;
    await tester.pumpWidget(_app(
        Scaffold(
          body: Builder(
            builder: (ctx2) => TextButton(
              onPressed: () => showAppSheet<void>(
                context: ctx2,
                builder: (sheetCtx) {
                  seen = MediaQuery.of(sheetCtx).viewInsets.bottom;
                  return const SizedBox(height: 40);
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
        kb: 300));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // AppSheetInsets already pads the keyboard; the builder must see 0.
    expect(seen, 0);
  });
}
