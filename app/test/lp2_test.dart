// lpapp: Language Partner V2 — engine (bands, rounding, mistake types, SRS),
// E2E for the mock flow (section practice + full mock with the real timer),
// scoring display, role-play (AI + guided), the book-companion OMR sheet,
// vocabulary, and Bangla digits on the start screen.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_rules.dart' show AdConfig;
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/language_partner_screen.dart';
import 'package:assisto/screens/lp2/lp_companion.dart';
import 'package:assisto/screens/lp2/lp_data.dart';
import 'package:assisto/screens/lp2/lp_engine.dart';
import 'package:assisto/screens/lp2/lp_life.dart';
import 'package:assisto/screens/lp2/lp_mock.dart';
import 'package:assisto/screens/lp2/lp_score.dart';
import 'package:assisto/screens/lp2/lp_ui.dart' show lpIcon;
import 'dart:convert';
import 'package:assisto/screens/lp2/lp_vocab.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_lp2.dart';

Widget _app(Widget child, ApiClient api, {String lang = 'en', bool dark = false}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    ),
  );
}

FakeApi _api({String lang = 'en'}) => FakeApi(mode: FakeMode.data, lang: lang);

/// gap-lp: Submit now asks first (answers missing / full mock): confirm it.
Future<void> _submit(WidgetTester t) async {
  await t.tap(find.byKey(const Key('lp2-submit')));
  await t.pumpAndSettle();
  final ok = find.byKey(const Key('lp2-submit-confirm'));
  if (ok.evaluate().isNotEmpty) {
    await t.tap(ok);
    await t.pumpAndSettle();
  }
}

Future<void> _tapText(WidgetTester t, String s) async {
  await t.ensureVisible(find.text(s).first);
  await t.tap(find.text(s).first);
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugLpAsset = (a) async => File(a).readAsStringSync(); // sync: real IO never finishes under fake time
    debugLpPlay = (_) async {};
    LpOffline.debugDisabled = true;
    AdBannerSlot.debugLoadConfig = () async => AdConfig.fromJson({'plan': 'premium', 'paid': true, 'ads_enabled': false});
    LpContent.debugReset();
    lp2Posts.clear();
  });

  group('engine', () {
    test('public raw -> band tables', () {
      expect(rawToBand('listening', 'academic', 30, 40), 7.0);
      expect(rawToBand('listening', 'academic', 23, 40), 6.0);
      expect(rawToBand('reading', 'academic', 30, 40), 7.0);
      expect(rawToBand('reading', 'academic', 27, 40), 6.5);
      expect(rawToBand('reading', 'general', 30, 40), 6.0);
      expect(rawToBand('reading', 'general', 40, 40), 9.0);
      expect(rawToBand('listening', 'academic', 0, 40), 0);
      // a 20-question practice set is scaled to 40 first
      expect(rawToBand('listening', 'academic', 15, 20), 7.0);
    });

    test('overall band uses the IELTS rounding rule', () {
      double? o(List<double> b) =>
          overallBand({'listening': b[0], 'reading': b[1], 'writing': b[2], 'speaking': b[3]});
      expect(o([6.5, 6.5, 5, 6]), 6.0); // 6.0
      expect(o([6, 6, 6, 6.5]), 6.0); // 6.125 -> 6
      expect(o([7, 6.5, 6, 6]), 6.5); // 6.375 -> 6.5
      expect(o([6.5, 6.5, 6.5, 6]), 6.5); // 6.375 -> 6.5
      expect(o([7, 7, 6.5, 6.5]), 7.0); // 6.75 -> 7
      expect(o([6, 6.5, 6, 6.5]), 6.5); // 6.25 -> 6.5
      expect(overallBand({'listening': 7, 'reading': 6, 'writing': null, 'speaking': 6}), isNull);
      expect(lpHalf((6 + 2 * 6.5) / 3), 6.5); // writing: Task 2 counts double
    });

    test('mistake types', () {
      expect(mistakeType('accomodation', 'accommodation'), 'spelling');
      expect(mistakeType('Tuesdays', 'Tuesday'), 'plural');
      expect(mistakeType('the old bridge', 'bridge', wordLimit: 2), 'word_limit');
      expect(mistakeType('TRUE', 'NOT GIVEN'), 'tfng');
      expect(mistakeType('F', 'NG'), 'tfng');
      expect(mistakeType('C', 'B'), 'matching');
      expect(mistakeType('D', 'B', isMap: true), 'map');
      expect(mistakeType('', 'library'), 'blank');
      expect(mistakeType('car park', 'parking'), 'other');
      expect(mistakeType('car park', 'parking / car park'), isNull); // "/" alternatives
      expect(mistakeType('bridge', '(the) bridge'), isNull); // optional words
      expect(mistakeType('the bridge', '(the) bridge'), isNull);
      expect(mistakeType('t', 'TRUE'), isNull);
      expect(mistakeType('Library.', 'library'), isNull);
    });

    test('markSheet counts only keyed questions', () {
      final r = markSheet('listening', 'academic', {1: 'library', 2: 'Tuesdays', 3: 'B'},
          {1: 'library', 2: 'Tuesday', 3: 'C', 4: ''});
      expect(r.raw, 1);
      expect(r.total, 3);
      expect(r.counts, {'plural': 1, 'matching': 1});
      expect(r.mistakes[1], isNull);
    });

    test('vocabulary spaced repetition', () {
      final s = <String, VocabState>{'a': const VocabState(2, 100), 'b': const VocabState(1, 105)};
      expect(dueWords(['a', 'b', 'c', 'd'], s, 100, newPerDay: 1), ['a', 'c']);
      final n = vocabNext(const VocabState(2, 100), true, 100);
      expect((n.box, n.due), (3, 104));
      final f = vocabNext(const VocabState(4, 100), false, 100);
      expect((f.box, f.due), (1, 101));
      expect(vocabNext(null, true, 100).box, 1);
      expect(clock(1800), '30:00');
      expect(clock(3725), '1:02:05');
    });
  });

  test('every scenario / topic icon name has an icon (bundled + lpcontent extra content)', () {
    final names = <String>{
      for (final f in ['assets/lp/life_en_v1.json', 'assets/lp/vocab_v1.json'])
        for (final i in [
          ...((jsonDecode(File(f).readAsStringSync()) as Map)['scenarios'] as List? ?? const []),
          ...((jsonDecode(File(f).readAsStringSync()) as Map)['topics'] as List? ?? const []),
        ])
          '${(i as Map)['icon']}',
      // lpcontent (ci/lpcontent): 20 more scenarios + 16 more topics
      'apartment', 'business_center', 'call', 'construction', 'currency_exchange', 'emergency',
      'engineering', 'groups', 'hotel', 'local_police', 'local_shipping', 'local_taxi',
      'medical_services', 'medication', 'receipt_long', 'restaurant', 'school', 'shopping_cart',
      'sim_card', 'train', 'account_tree', 'bolt', 'edit_note', 'family_restroom', 'forum', 'gavel',
      'home', 'location_city', 'luggage', 'newspaper', 'room_service', 'science', 'theater_comedy',
      'trending_up',
    };
    final missing = names.where((n) => lpIcon(n, Icons.help_rounded) == Icons.help_rounded).toList();
    expect(missing, isEmpty);
  });

  group('start (screen 1)', () {
    testWidgets('IELTS card, Life English card, chips, goal + streak', (t) async {
      await t.pumpWidget(_app(const LanguagePartnerScreen(), _api()));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('lp2-goal')), findsOneWidget);
      expect(find.text("Today's goal"), findsOneWidget);
      expect(find.text('3-day streak'), findsOneWidget);
      expect(find.text('10 of 15 minutes today'), findsOneWidget);
      expect(find.text('Last mock: band 6.5'), findsOneWidget);
      expect(find.byKey(const Key('lp2-ielts')), findsOneWidget);
      expect(find.byKey(const Key('lp2-life')), findsOneWidget);
      expect(find.text('2 of 10 situations practised'), findsOneWidget);
      await t.scrollUntilVisible(find.text('Other languages'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Japan · JLPT / JFT'), findsOneWidget);
      expect(find.text('Other languages'), findsOneWidget);
      expect(find.text('French · A1'), findsOneWidget); // lpfinish: one course = one chip
    });

    testWidgets('Bangla: no ASCII digits except the A1 level name', (t) async {
      await t.pumpWidget(_app(const LanguagePartnerScreen(), _api(lang: 'bn'), lang: 'bn'));
      await t.pumpAndSettle();
      final texts = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').toList();
      expect(texts.where((s) => RegExp(r'[0-9]').hasMatch(s.replaceAll('A1', ''))), isEmpty);
      expect(texts.any((s) => s.contains('৩')), isTrue);
    });
  });

  group('mock flow (E2E)', () {
    testWidgets('free user: full mock explains Premium; section practice marks and shows the result',
        (t) async {
      await t.pumpWidget(_app(const LpIeltsHub(), _api()));
      await t.pumpAndSettle();
      expect(find.text('Free plan: 1 mock section left this week'), findsOneWidget);
      expect(find.text('Beta · under review'), findsWidgets);
      await t.tap(find.byKey(const Key('lp2-full-ac-001')));
      await t.pumpAndSettle();
      expect(find.textContaining('Full mock tests with the real timer'), findsOneWidget);
      await t.tapAt(const Offset(10, 10)); // close the sheet
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('lp2-sec-ac-001-reading')));
      await t.tap(find.byKey(const Key('lp2-sec-ac-001-reading')));
      await t.pumpAndSettle();
      expect(find.text('Section practice'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^(1:00:00|59:5\d)$')), findsOneWidget); // the real Reading timer
      expect(find.text('Floating gardens of the delta'), findsOneWidget);
      await _tapText(t, 'Questions');
      await _tapText(t, 'TRUE');
      await t.enterText(find.byType(TextFormField).first, 'hyacinth');
      await t.pump();
      await _submit(t);
      final mark = lp2Posts.firstWhere((p) => '${p['path']}'.endsWith('/mark'));
      expect(mark['section'], 'reading');
      expect(mark['answers'], {'1': 'TRUE', '4': 'hyacinth'});
      expect(find.text('Your result'), findsOneWidget);
      expect(find.byKey(const Key('lp2-overall')), findsOneWidget);
      expect(find.text('6.5'), findsWidgets);
      expect(find.text('Not taken this time'), findsNWidgets(3));
      await t.scrollUntilVisible(find.byKey(const Key('lp2-weak')), 200, scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const Key('lp2-weak')), findsOneWidget);
      await t.scrollUntilVisible(find.text('Practice score — not an official IELTS result.'), 200,
          scrollable: find.byType(Scrollable).first);
      // practice weak areas -> generated questions -> marked with explanations
      await t.scrollUntilVisible(find.byKey(const Key('lp2-weak')), -200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byKey(const Key('lp2-weak')));
      await t.pumpAndSettle();
      expect(lp2Posts.last['path'], 'lp/weak/practice');
      expect(lp2Posts.last['tags'], ['tfng']);
      await _tapText(t, 'TRUE');
      await _tapText(t, 'Check answers');
      expect(find.text('1 of 2 right'), findsOneWidget);
      expect(find.text('Double c and double m.'), findsOneWidget);
    });

    testWidgets('full mock: timer counts down, four sections, overall band + AI comment', (t) async {
      const mock = {'id': 'ac-001', 'kind': 'academic', 'title_en': 'Academic mock 1', 'title_bn': 'x'};
      await t.pumpWidget(_app(const LpMockRunner(mock: mock, sections: kLpSections, full: true), _api()));
      await t.pumpAndSettle();
      expect(find.text('Full mock · section 1 of 4'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^(30:00|29:5\d)$')), findsOneWidget);
      final before = t.widget<Text>(find.textContaining(RegExp(r'^(30:00|29:5\d)$'))).data!;
      await t.pump(const Duration(seconds: 1));
      expect(t.widget<Text>(find.textContaining(RegExp(r'^29:5\d$'))).data, isNot(before)); // it counts down
      expect(find.text('Exam mode: the recording plays once.'), findsOneWidget);
      await _submit(t); // listening -> reading
      expect(find.textContaining(RegExp(r'^(1:00:00|59:5\d)$')), findsOneWidget);
      await _submit(t); // reading -> writing
      await t.enterText(find.byKey(const Key('lp2-w1')), 'In 2005 most people took the bus; by 2025 the metro led.');
      await _submit(t); // writing -> speaking
      await t.enterText(find.byKey(const Key('lp2-s1')), 'I live in Dhaka near a busy market.');
      await _submit(t); // finish
      final paths = lp2Posts.map((p) => p['path']).toList();
      expect(paths, [
        'lp/mocks/ac-001/mark',
        'lp/mocks/ac-001/mark',
        'lp/score/writing',
        'lp/score/speaking',
        'lp/mocks/ac-001/finish',
      ]);
      expect(lp2Posts[2]['task'], 1);
      expect(lp2Posts[2]['variant'], 'academic');
      final fin = lp2Posts.last['bands'] as Map;
      expect(fin, {'listening': 7.0, 'reading': 6.5, 'writing': 6.0, 'speaking': 6.0});
      expect(t.widget<Text>(find.byKey(const Key('lp2-overall'))).data, '6.5');
      expect(find.text('Only one task was answered — the real exam needs both.'), findsOneWidget);
      expect(find.textContaining('Strong listening.'), findsOneWidget);
    });

    testWidgets('time up submits the section by itself', (t) async {
      const mock = {'id': 'ac-001', 'kind': 'academic', 'title_en': 'Academic mock 1'};
      await t.pumpWidget(_app(const LpMockRunner(mock: mock, sections: ['listening'], full: false), _api()));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 50)); // load (the exam timer keeps ticking: no settle)
      }
      expect(find.text('30:00'), findsOneWidget);
      for (var i = 0; i < 1801; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(lp2Posts.first['path'], 'lp/mocks/ac-001/mark');
      expect(find.text('Your result'), findsOneWidget);
    });
  });

  group('scoring display', () {
    testWidgets('writing score: criteria, mistakes with Bangla, practice label', (t) async {
      await t.pumpWidget(_app(
          Scaffold(body: SingleChildScrollView(child: LpScoreView(r: fakeLp2Writing(), title: 'Task 2'))),
          _api(lang: 'bn'),
          lang: 'bn'));
      await t.pumpAndSettle();
      expect(find.text('ব্যান্ড ৬.৫'), findsOneWidget);
      expect(find.textContaining('Task response'), findsOneWidget);
      expect(find.text('"People" নিজেই বহুবচন, তাই s লাগবে না।'), findsOneWidget);
      expect(find.byKey(const Key('lp2-fix')), findsOneWidget);
      expect(find.text('অনুশীলনের স্কোর — অফিসিয়াল IELTS ফল নয়।'), findsOneWidget);
    });

    testWidgets('not scored: says why and offers plans (nothing charged)', (t) async {
      await t.pumpWidget(_app(
          Scaffold(body: LpScoreView(r: const {'ai_state': 'credits'}, title: 'Task 2')), _api()));
      await t.pumpAndSettle();
      expect(find.textContaining('no credits left'), findsOneWidget);
      expect(find.text('See plans'), findsOneWidget);
    });
  });

  group('role-play (screen 3)', () {
    testWidgets('AI officer question, user answer, yellow correction, reply', (t) async {
      await t.pumpWidget(_app(LpRolePlayScreen(scenario: lp2Scenario('embassy')), _api()));
      await t.pumpAndSettle();
      expect(find.textContaining('Why do you want to travel'), findsOneWidget);
      expect(find.byKey(const Key('lp2-hold')), findsOneWidget);
      await t.tap(find.byKey(const Key('lp2-type')));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'I want study master degree');
      await t.tap(find.byIcon(Icons.send_rounded));
      await t.pumpAndSettle();
      final post = lp2Posts.single;
      expect(post['path'], 'lp/life/roleplay');
      expect(post['scenario_id'], 'embassy');
      expect((post['history'] as List).first['role'], 'assistant');
      expect(find.byKey(const Key('lp2-fix')), findsOneWidget);
      expect(find.text("I want to study for a master's degree."), findsOneWidget);
      expect(find.text('Thank you. And who will pay for your studies?'), findsOneWidget);
      expect(find.text('Say it right'), findsOneWidget);
      await t.tap(find.byIcon(Icons.mic_rounded).last); // back to the hold-to-speak button
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('lp2-hold'))); // a tap explains how to hold
      await t.pump();
      expect(find.text('Hold the button while you speak, then let go.'), findsOneWidget);
    });

    testWidgets('guided practice: pronunciation percent from the model answer (key-free)', (t) async {
      await t.pumpWidget(_app(LpRolePlayScreen(scenario: lp2Scenario('bank')), _api()));
      await t.pumpAndSettle();
      await _tapText(t, 'Guided practice');
      expect(find.text('How can I help you today?'), findsOneWidget);
      await t.tap(find.byKey(const Key('lp2-type')));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'I want to send money to my family in Bangladesh.');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pumpAndSettle();
      expect(find.text('Pronunciation 100%'), findsOneWidget);
      expect(find.text('Good English!'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Five hundred dollar what is rate');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('lp2-fix')), findsOneWidget);
      expect(find.textContaining('Pronunciation '), findsWidgets);
      expect(lp2Posts, isEmpty); // guided practice never calls the AI
    });
  });

  group('book companion (screen 4) OMR', () {
    testWidgets('answer sheet -> own key -> band + mistake types; no-content footer', (t) async {
      await t.pumpWidget(_app(const LpCompanionScreen(), _api()));
      await t.pumpAndSettle();
      expect(find.text('Book 20'), findsOneWidget);
      await t.tap(find.byKey(const Key('lp2-timer-btn')));
      await t.pump(); // the timer appears
      expect(find.text('30:00'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      expect(find.textContaining(RegExp(r'^29:5\d$')), findsOneWidget);
      const ans = {1: 'library', 2: 'Tuesdays', 3: 'B', 4: 'accomodation'};
      const key = {1: 'library', 2: 'Tuesday', 3: 'C', 4: 'accommodation'};
      for (final e in ans.entries) {
        await t.enterText(find.byKey(Key('lp2-a${e.key}')), e.value);
      }
      await t.scrollUntilVisible(find.byKey(const Key('lp2-to-key')), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byKey(const Key('lp2-to-key')));
      await t.pumpAndSettle();
      for (final e in key.entries) {
        await t.ensureVisible(find.byKey(Key('lp2-k${e.key}')));
        await t.enterText(find.byKey(Key('lp2-k${e.key}')), e.value);
      }
      await t.scrollUntilVisible(find.byKey(const Key('lp2-mark')), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byKey(const Key('lp2-mark')));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.byKey(const Key('lp2-omr-score')), -300, scrollable: find.byType(Scrollable).first);
      expect(find.text('1 of 4 correct'), findsOneWidget);
      expect(find.byKey(const Key('lp2-omr-score')), findsOneWidget);
      expect(find.text('Mistake types'), findsOneWidget);
      expect(find.textContaining('Spelling · 1'), findsOneWidget);
      expect(find.textContaining('Plural / singular · 1'), findsOneWidget);
      expect(find.textContaining('Matching · 1'), findsOneWidget);
      final saved = lp2Posts.firstWhere((p) => p['path'] == 'lp/companion/mark');
      expect(saved['book'], 20);
      expect(saved['key'], {'1': 'library', '2': 'Tuesday', '3': 'C', '4': 'accommodation'});
      await t.scrollUntilVisible(
          find.text('Questions, audio and answers are not kept in the app. Use your own book.'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const Key('lp2-nocontent')), findsOneWidget);
    });

    testWidgets('mark without a key asks for the key', (t) async {
      await t.pumpWidget(_app(const LpCompanionScreen(), _api()));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.byKey(const Key('lp2-to-key')), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byKey(const Key('lp2-to-key')));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.byKey(const Key('lp2-mark')), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byKey(const Key('lp2-mark')));
      await t.pump();
      expect(find.text('Type the answer key from your book first.'), findsOneWidget);
    });
  });

  group('vocabulary', () {
    testWidgets('session: word -> meaning -> knew it -> saved; finish summary', (t) async {
      final words = [
        {'id': 'x_a', 'w': 'curriculum', 'pos': 'n', 'bn': 'পাঠ্যক্রম', 'ex': 'The school changed its curriculum.'},
        {'id': 'x_b', 'w': 'literacy', 'pos': 'n', 'bn': 'সাক্ষরতা', 'ex': 'Adult literacy has improved.'},
      ];
      await t.pumpWidget(_app(LpVocabSession(words: words, rows: const [], title: 'Education'), _api()));
      await t.pumpAndSettle();
      expect(find.text('curriculum'), findsOneWidget);
      await t.tap(find.byKey(const Key('lp2-show')));
      await t.pumpAndSettle();
      expect(find.text('পাঠ্যক্রম'), findsOneWidget);
      await t.tap(find.byKey(const Key('lp2-knew')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('lp2-show')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('lp2-notyet')));
      await t.pumpAndSettle();
      expect(find.text('Session complete'), findsOneWidget);
      expect(find.textContaining('You knew 1 of 2'), findsOneWidget);
    });

    testWidgets('topic lists: IELTS and life, from the bundled file', (t) async {
      await t.pumpWidget(_app(const LpVocabScreen(), _api()));
      await t.pumpAndSettle();
      expect(find.text('Education'), findsOneWidget);
      await _tapText(t, 'Life');
      expect(find.text('Workplace abroad'), findsOneWidget);
    });
  });

  testWidgets('Life English list: 10 scenarios offline', (t) async {
    await t.pumpWidget(_app(const LpLifeListScreen(), _api()));
    await t.pumpAndSettle();
    expect(find.text('Airport and immigration'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Job interview'), 200);
    expect(find.text('Job interview'), findsOneWidget);
  });
}
