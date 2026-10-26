// budrem: Budget and Remittance on the app side (fake server). The Bangla
// quick-entry parser (the owner's own example, Bangla digits, lakh/hajar,
// rate, channel words, relation -> My Circle member), the entry form (taka
// from the rate the user got, validation), offline entry that syncs later
// with the same client id, the family plan versus actual, the savings goal,
// bills, the monthly report shared ONLY on tap, the year view, the
// expected-money reminder, the home tile switch, and every screen at 200%
// text in bn + en, light + dark with no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/screens/remittance/remit_entry_screen.dart';
import 'package:assisto/screens/remittance/remit_parser.dart';
import 'package:assisto/screens/remittance/remit_report_screen.dart';
import 'package:assisto/screens/remittance/remit_source.dart';
import 'package:assisto/screens/remittance/remittance_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'budrem_fakes.dart';
import 'budrem_shots.dart';
import 'fake_api.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'Rahim', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
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
        builder: (ctx, child) =>
            MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

late AppLocalizations en;
late AppLocalizations bn;
final _now = DateTime(2026, 10, 20);
const _members = [
  {'id': 7, 'name': 'Karim', 'relation': 'brother'},
  {'id': 8, 'name': 'Salma', 'relation': 'sister'},
];

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('quick-entry parser (offline, rule-based)', () {
    test("the owner's example: bhai 20 hajar taka pathaise bikashe", () {
      final d = RemitParser.parse('ভাই ২০ হাজার টাকা পাঠাইছে বিকাশে', now: _now);
      expect(d.amount, 20000);
      expect(d.currency, 'BDT');
      expect(d.channel, 'bkash');
      expect(d.relation, 'brother');
      expect(d.memberId, isNull);
    });
    test('a relation word picks the ONE My Circle member with it', () {
      final d = RemitParser.parse('ভাইয়া ২০ হাজার টাকা পাঠাইছে বিকাশে', members: _members, now: _now);
      expect(d.relation, 'brother');
      expect(d.memberId, 7);
      expect(d.memberName, 'Karim');
    });
    test('a member named in the sentence wins', () {
      final d = RemitParser.parse('Salma sent 300 dirham by MoneyGram', members: _members, now: _now);
      expect((d.memberId, d.amount, d.currency, d.channel), (8, 300, 'AED', 'moneygram'));
    });
    test('Bangla digits with a comma, Nagad', () {
      final d = RemitParser.parse('স্বামী ২৫,৫০০ টাকা নগদে দিছে', now: _now);
      expect((d.amount, d.currency, d.channel, d.relation), (25500, 'BDT', 'nagad', 'husband'));
    });
    test('foreign currency + the rate the user got', () {
      final d = RemitParser.parse('আব্বা ৫০০ রিয়াল পাঠাইছে ব্যাংকে রেট ৩২.৫', now: _now);
      expect((d.amount, d.currency, d.channel, d.relation, d.rate), (500, 'SAR', 'bank', 'father', 32.5));
    });
    test('der lakh by Western Union, yesterday', () {
      final d = RemitParser.parse('গতকাল দেড় লাখ টাকা ওয়েস্টার্ন ইউনিয়নে এসেছে', now: _now);
      expect(d.amount, 150000);
      expect(d.channel, 'western_union');
      expect(d.date, DateTime(2026, 10, 19));
    });
    test('number words: bish hajar; Rocket; sister', () {
      final d = RemitParser.parse('আপু বিশ হাজার রকেটে পাঠাল', now: _now);
      expect((d.amount, d.channel, d.relation), (20000, 'rocket', 'sister'));
    });
    test('Banglish + 20k', () {
      final d = RemitParser.parse('bhai 20k taka bkash e pathaise', now: _now);
      expect((d.amount, d.currency, d.channel, d.relation), (20000, 'BDT', 'bkash', 'brother'));
    });
    test('ringgit in lakh-free English', () {
      final d = RemitParser.parse('Son sent 1,200 ringgit to my bank account', now: _now);
      expect((d.amount, d.currency, d.channel, d.relation), (1200, 'MYR', 'bank', 'son'));
    });
    test('nothing to understand -> an empty draft (the form says so)', () {
      expect(RemitParser.parse('hello there', now: _now).isEmpty, isTrue);
      expect(RemitParser.parse('', now: _now).isEmpty, isTrue);
    });
    test('only legal channels exist', () {
      expect(RemitParser.channels,
          ['bank', 'bkash', 'nagad', 'rocket', 'western_union', 'moneygram', 'other']);
      expect(RemitParser.parse('hundi te 50000 taka', now: _now).channel, isNull);
    });
  });

  group('entry form', () {
    testWidgets("quick sentence fills the form; nothing is saved until Save", (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('data');
      final d = RemitParser.parse('ভাই ২০ হাজার টাকা পাঠাইছে বিকাশে', members: _members, now: _now);
      await tester.pumpWidget(_app(RemitEntryScreen(
          source: f, queue: RemitQueue(f), draft: d, said: 'ভাই ২০ হাজার টাকা পাঠাইছে বিকাশে', members: _members)));
      await _settle(tester);
      expect(find.text(en.rmtUnderstoodCheck), findsOneWidget);
      expect(f.created, isEmpty); // shown for checking, not saved
      expect(tester.widget<TextFormField>(find.byKey(const ValueKey('rmt_amount'))).controller!.text, '20000');
      await tester.tap(find.byKey(const ValueKey('rmt_save')));
      await _settle(tester);
      expect(f.created, hasLength(1));
      final b = f.created.single;
      expect((b['amount'], b['currency'], b['channel'], b['sender_member_id'], b['sender_name']),
          ('20000', 'BDT', 'bkash', 7, 'Karim'));
      expect(b['source'], 'text');
      expect('${b['client_id']}'.length, inInclusiveRange(8, 36));
    });

    testWidgets('a relation with no member becomes the sender name; no currency word = taka', (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('data');
      f.prefs[kRmLastCurrency] = 'SAR'; // last entry was in riyal
      final d = RemitParser.parse('আম্মা ৫০০০ টাকা পাঠাইছে নগদে', now: _now);
      await tester.pumpWidget(
          _app(RemitEntryScreen(source: f, queue: RemitQueue(f), draft: d, members: const [])));
      await _settle(tester);
      expect(tester.widget<TextFormField>(find.byKey(const ValueKey('rmt_sender'))).controller!.text,
          en.rmtRelMother);
      final d2 = RemitParser.parse('ভাই ২০ হাজার বিকাশে', now: _now);
      expect(d2.currency, isNull);
      await tester.pumpWidget(
          _app(RemitEntryScreen(source: f, queue: RemitQueue(f), draft: d2, members: const [])));
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('rmt_save')));
      await tester.tap(find.byKey(const ValueKey('rmt_save')));
      await _settle(tester);
      expect(f.created.last['currency'], 'BDT');
    });

    testWidgets('foreign money: taka comes from the rate the user got', (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemitEntryScreen(source: f, queue: RemitQueue(f), members: _members)));
      await _settle(tester);
      // validation: empty amount refused, nothing sent
      await tester.tap(find.byKey(const ValueKey('rmt_save')));
      await _settle(tester);
      expect(find.text(en.rmtErrAmount), findsWidgets);
      expect(f.created, isEmpty);
      await tester.tap(find.byKey(const ValueKey('rmt_currency')));
      await _settle(tester);
      await tester.tap(find.text(en.rmtCurSAR).last);
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rmt_amount')), '500');
      await tester.enterText(find.byKey(const ValueKey('rmt_rate')), '32.5');
      await tester.pump();
      expect(tester.widget<TextFormField>(find.byKey(const ValueKey('rmt_taka'))).controller!.text, '16250');
      await tester.tap(find.byKey(const ValueKey('rmt_ch_western_union')));
      await tester.tap(find.text('Karim'));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('rmt_save')));
      await tester.tap(find.byKey(const ValueKey('rmt_save')));
      await _settle(tester);
      final b = f.created.single;
      expect((b['currency'], b['rate'], b['taka'], b['channel'], b['sender_member_id']),
          ('SAR', '32.5', '16250', 'western_union', 7));
    });
  });

  group('offline entry', () {
    testWidgets('written offline -> kept on the phone -> synced later, once', (tester) async {
      _phone(tester, height: 2400);
      final f = FakeRemit('offline');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('rmt_offline')), findsOneWidget);
      expect(find.text(en.rmtOfflineEntryBody), findsOneWidget);
      // the quick box works offline too
      await tester.enterText(find.byKey(const ValueKey('rmt_quick')), 'bhai 20 hajar taka bkash e');
      await tester.tap(find.byKey(const ValueKey('rmt_quick_go')));
      await _settle(tester);
      expect(find.text(en.rmtUnderstoodCheck), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('rmt_save')));
      await tester.tap(find.byKey(const ValueKey('rmt_save')));
      await _settle(tester);
      expect(find.text(en.rmtSavedOffline), findsOneWidget);
      expect(find.byKey(const ValueKey('rmt_pending')), findsOneWidget);
      expect(find.text(en.rmtWaitingSync), findsOneWidget);
      expect(f.created, isEmpty);
      expect(f.prefs[RemitQueue.prefsKey], contains('20000'));
      // back online: Sync now sends it with its client id
      f.offline = false;
      await tester.tap(find.text(en.rmtSyncNow));
      await _settle(tester);
      expect(f.created, hasLength(1));
      expect(find.byKey(const ValueKey('rmt_pending')), findsNothing);
    });

    test('a retry of the same client id never doubles (server idempotent)', () async {
      final f = FakeRemit('data');
      final q = RemitQueue(f);
      await q.load();
      final body = {'client_id': 'offline-0001', 'amount': '100', 'currency': 'BDT', 'channel': 'bkash',
        'received_on': '2026-10-20'};
      f.offline = true;
      await q.add('entry', body);
      await q.add('spend', {'client_id': 'spend-0001', 'category': 'food', 'amount': '50'});
      var r = await q.flush();
      expect((r.sent, r.offline, q.items.length), (0, true, 2));
      f.offline = false;
      r = await q.flush();
      expect((r.sent, q.items.length), (2, 0));
      await f.createEntry(body); // the same id again
      expect(f.entries.where((e) => e['client_id'] == 'offline-0001'), hasLength(1));
      // a reload of the queue from the phone store keeps nothing sent
      final q2 = RemitQueue(f);
      await q2.load();
      expect(q2.items, isEmpty);
    });
  });

  group('family budget', () {
    testWidgets('plan versus actual, edit plan, add spending, savings goal, bills', (tester) async {
      _phone(tester, height: 3000);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now, initialTab: 1)));
      await _settle(tester);
      expect(find.text(en.rmtPlanTitle), findsOneWidget);
      expect(find.text(en.rmtStateOver), findsOneWidget); // rent 9,000 of 8,000
      expect(find.text(en.rmtStateNear), findsWidgets); // food 10,500 of 12,000
      // edit the plan
      await tester.tap(find.byKey(const ValueKey('rmt_plan_edit')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rmt_plan_food')), '15000');
      await tester.tap(find.byKey(const ValueKey('rmt_sheet_save')));
      await _settle(tester);
      expect(f.calls, contains('plan'));
      expect(f.plan['food'], 15000);
      // add spending (medicine)
      await tester.tap(find.byKey(const ValueKey('rmt_spend_add')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('rmt_spend_health')));
      await tester.enterText(find.byKey(const ValueKey('rmt_spend_amount')), '800');
      await tester.tap(find.byKey(const ValueKey('rmt_sheet_save')));
      await _settle(tester);
      expect(f.calls, contains('spend:health:800'));
      // savings goal progress
      expect(find.textContaining('Roof repair'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('rmt_goal_add')));
      await tester.tap(find.byKey(const ValueKey('rmt_goal_add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rmt_amount_only')), '2000');
      await tester.tap(find.byKey(const ValueKey('rmt_sheet_save')));
      await _settle(tester);
      expect(f.calls, contains('goaladd:2000'));
      expect(f.goal!['saved'], '42000.00');
      // bills: one paid, one with "Mark paid" + "Remind me"
      expect(find.text(en.rmtBillPaid), findsOneWidget);
      await tester.ensureVisible(find.text(en.rmtBillMarkPaid));
      await tester.tap(find.text(en.rmtBillMarkPaid));
      await _settle(tester);
      expect(f.calls, contains('billpaid:2:2026-10'));
      await tester.ensureVisible(find.text(en.rmtBillRemind));
      await tester.tap(find.text(en.rmtBillRemind));
      await _settle(tester);
      expect(f.calls.any((c) => c.startsWith('reminder:')), isTrue);
      expect(f.calls.any((c) => c.startsWith('billupd:2:reminder_local_id')), isTrue);
    });

    testWidgets('set a first savings goal', (tester) async {
      _phone(tester, height: 2400);
      final f = FakeRemit('empty');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now, initialTab: 1)));
      await _settle(tester);
      expect(find.text(en.rmtPlanEmpty), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('rmt_goal_set')));
      await tester.tap(find.byKey(const ValueKey('rmt_goal_set')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rmt_goal_title')), 'Wedding');
      await tester.enterText(find.byKey(const ValueKey('rmt_goal_target')), '200000');
      await tester.tap(find.byKey(const ValueKey('rmt_sheet_save')));
      await _settle(tester);
      expect(f.calls, contains('goal:Wedding:200000'));
    });
  });

  group('report + share', () {
    testWidgets('the report is shared ONLY when the user taps Share and picks a member', (tester) async {
      _phone(tester, height: 1600);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemitReportScreen(source: f, month: FakeRemit.month, initialLang: 'en')));
      await _settle(tester);
      expect(find.textContaining('Where it went'), findsOneWidget);
      expect(f.calls.where((c) => c.startsWith('share')), isEmpty); // opening never shares
      // switch to Bangla: the server builds the Bangla summary
      await tester.tap(find.byKey(const ValueKey('rmt_report_bn')));
      await _settle(tester);
      expect(f.calls, contains('report:2026-10:bn'));
      expect(f.shared, isEmpty);
      await tester.tap(find.byKey(const ValueKey('rmt_share')));
      await _settle(tester);
      // picker: cancel first -> still nothing sent
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      expect(f.shared, isEmpty);
      await tester.tap(find.byKey(const ValueKey('rmt_share')));
      await _settle(tester);
      await tester.tap(find.text('Karim'));
      await _settle(tester);
      expect(f.shared, isEmpty); // the confirm dialog comes first
      await tester.tap(find.byKey(const ValueKey('rmt_share_send')));
      await _settle(tester);
      expect(f.calls.where((c) => c.startsWith('share:')).toList(), ['share:7']);
      expect(f.shared.single, contains('৳'));
      expect(find.text(en.rmtShareSent('Karim')), findsWidgets);
    });

    testWidgets('the main screen never shares on its own', (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now)));
      await _settle(tester);
      expect(f.calls.where((c) => c.startsWith('share')), isEmpty);
    });
  });

  group('month, expected money, year', () {
    testWidgets('first run shows the 30-second guide; Got it remembers', (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('empty');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, now: _now)));
      await _settle(tester);
      expect(find.text(en.rmtGuideTitle), findsOneWidget);
      expect(find.text(en.rmtEmptyMonth), findsOneWidget);
      await tester.tap(find.text(en.rmtGotIt));
      await _settle(tester);
      expect(find.text(en.rmtGuideTitle), findsNothing);
      expect(f.prefs[kRmGuideSeen], '1');
      expect(f.guideDone, isTrue);
    });

    testWidgets('expected money missing -> a warning card and ONE reminder', (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('missing');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('rmt_expected_missing')), findsOneWidget);
      expect(f.notes, contains('show:remit-missing-2026-10'));
      // a reload the same month shows no second notification
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now)));
      await _settle(tester);
      expect(f.notes.where((n) => n.startsWith('show:')), hasLength(1));
    });

    testWidgets('month list shows the entries; tapping one opens the edit form', (tester) async {
      _phone(tester, height: 2400);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now)));
      await _settle(tester);
      expect(find.text('Karim'), findsOneWidget);
      expect(find.textContaining(en.rmtForeignLine('500', 'SAR', '32.5')), findsOneWidget);
      await tester.tap(find.text('Karim'));
      await _settle(tester);
      expect(find.text(en.rmtEditEntryTitle), findsOneWidget);
      expect(find.text(en.rmtDeleteEntry), findsOneWidget);
    });

    testWidgets('year view: total, by sender, by channel, savings built', (tester) async {
      _phone(tester, height: 3000);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now, initialTab: 2)));
      await _settle(tester);
      expect(f.calls, contains('year:2026'));
      expect(find.text('৳3,12,500'), findsOneWidget);
      expect(find.text(en.rmtBySender), findsOneWidget);
      expect(find.text('৳2,16,250'), findsOneWidget);
      expect(find.text(en.rmtChWesternUnion), findsOneWidget);
      expect(find.text('৳44,000'), findsOneWidget);
    });

    testWidgets('delete all asks first, then deletes', (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now)));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('rmt_menu')));
      await _settle(tester);
      await tester.tap(find.text(en.rmtDeleteAll));
      await _settle(tester);
      expect(find.text(en.rmtDeleteAllTitle), findsOneWidget);
      expect(f.calls, isNot(contains('deleteAll')));
      await tester.tap(find.byKey(const ValueKey('rmt_confirm_yes')));
      await _settle(tester);
      expect(f.calls, contains('deleteAll'));
      expect(f.entries, isEmpty);
    });

    testWidgets('flag off -> an honest "not available yet", no add button', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(RemittanceScreen(source: FakeRemit('off'), guide: false, now: _now)));
      await _settle(tester);
      expect(find.text(en.rmtOffTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('rmt_add')), findsNothing);
    });
  });

  group('home tile', () {
    tearDown(() => FeatureFlags.instance.debugOverride = null);
    test('flag OFF: "Budget" opens the existing budget; ON: Budget and Remittance', () {
      FeatureFlags.instance.debugOverride = {'budget_remittance': false};
      expect(HomeV2Shortcuts.openRoute('budget'), 'budget');
      expect(HomeV2Shortcuts.byRoute('budget')!.label(en), en.budgetTitle);
      FeatureFlags.instance.debugOverride = {'budget_remittance': true};
      expect(HomeV2Shortcuts.openRoute('budget'), 'remittance');
      expect(HomeV2Shortcuts.byRoute('budget')!.label(en), 'Budget and Remittance');
      expect(HomeV2Shortcuts.byRoute('budget')!.label(bn), 'বাজেট ও রেমিট্যান্স');
      expect(HomeV2Shortcuts.openRoute('khata'), 'khata');
    });
  });

  // 200% font, bn + en, light + dark: no overflow / layout error anywhere.
  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('every remittance screen at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
        _phone(tester);
        for (final e in budremShots.entries) {
          await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
          await _settle(tester, 8);
          final err = tester.takeException();
          expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
        }
      });
    }
  }
}
