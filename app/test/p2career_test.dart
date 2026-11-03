// p2career: CV export (style/ATS), Find jobs (legal sources, honest source
// labels, saved searches, track + deadline), role interview (rubric + AI
// honest state), and the career_plus gate on the three existing screens.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/career/cv_export_screen.dart';
import 'package:assisto/screens/career/interview_role_screen.dart';
import 'package:assisto/screens/career/job_find_screen.dart';
import 'package:assisto/screens/cv_builder_screen.dart';
import 'package:assisto/screens/mock_interview_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

AppState _state(String lang, {FakeMode mode = FakeMode.data}) {
  final s = AppState();
  s.api = FakeApi(lang: lang, mode: mode);
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  s.online = true;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false, FakeMode mode = FakeMode.data}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(lang, mode: mode),
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

void _phone(WidgetTester tester, {double height = 2400}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

final _ascii = RegExp(r'[0-9]');

void _noAsciiDigits(WidgetTester tester) {
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    final s = w.data ?? w.textSpan?.toPlainText() ?? '';
    if (s.contains('http') || s.contains('@')) continue;
    expect(_ascii.hasMatch(s), isFalse, reason: 'ASCII digit in Bangla UI: "$s"');
  }
}

void main() {
  late AppLocalizations en;
  late AppLocalizations bn;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  group('Find jobs', () {
    testWidgets('legal sources, honest labels, search with source label, track + deadline ask', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const JobFindScreen()));
      await _settle(tester);
      expect(find.text(en.crrCareerjetOff), findsOneWidget);
      expect(find.text(en.crrJobsSavedSearches), findsOneWidget);
      expect(find.text('accountant · Dhaka'), findsOneWidget);
      expect(find.text(en.crrCompanyLinkOnly), findsOneWidget); // plain link is open-only
      expect(find.textContaining(en.crrLinkOnly), findsWidgets); // portals: link only
      // empty query is refused with a clear line
      await tester.tap(find.text(en.crrJobsSearch));
      await _settle(tester);
      expect(find.text(en.crrJobsQueryNeeded), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'accounts');
      await tester.tap(find.text(en.crrJobsSearch));
      await _settle(tester);
      expect(find.text('Accounts Officer'), findsOneWidget);
      expect(find.text(en.crrJobsSourceLabel('Acme Foods')), findsOneWidget);
      expect(find.text('Careerjet: ${en.crrSrcNotConnected}'), findsOneWidget);
      await tester.ensureVisible(find.text(en.crrJobsTrack));
      await tester.tap(find.text(en.crrJobsTrack));
      await _settle(tester);
      expect(find.text(en.crrJobsDeadlineAsk), findsOneWidget);
      await tester.tap(find.text(en.crrJobsDeadlineSkip));
      await _settle(tester);
      expect(find.text(en.crrJobsDeadlineAsk), findsNothing);
    });

    testWidgets('empty: benefit line + add button; Bangla digits; 200% font no overflow', (tester) async {
      _phone(tester, height: 4000);
      await tester.pumpWidget(_app(const JobFindScreen(), lang: 'bn', scale: 2.0, mode: FakeMode.empty));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(bn.crrCompaniesEmpty), findsOneWidget);
      expect(find.text(bn.crrCompanyAdd), findsOneWidget);
      _noAsciiDigits(tester);
    });

    testWidgets('add-company sheet: Save stays off until a test passes', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const JobFindScreen()));
      await _settle(tester);
      await tester.ensureVisible(find.text(en.crrCompanyAdd));
      await tester.tap(find.text(en.crrCompanyAdd));
      await _settle(tester);
      final save = find.widgetWithText(FilledButton, en.save);
      expect(save, findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(find.text(en.crrCompanyValueGh), findsOneWidget);
      await tester.tap(find.text(en.crrKindRss));
      await _settle(tester);
      expect(find.text(en.crrCompanyValueUrl), findsOneWidget);
    });
  });

  group('Role interview', () {
    testWidgets('role -> question -> rubric score -> honest AI state -> finish', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const InterviewRoleScreen()));
      await _settle(tester);
      expect(find.text('Bank officer'), findsOneWidget);
      await tester.tap(find.text('Bank officer'));
      await _settle(tester);
      expect(find.text('How would you handle an angry customer?'), findsOneWidget);
      expect(find.text(en.crrRoleQuestionOf('1', '2')), findsOneWidget);
      await tester.tap(find.text(en.crrSubmit));
      await _settle(tester);
      expect(find.text(en.crrEmptyAnswer), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'I listen, stay calm and find a solution.');
      await tester.tap(find.text(en.crrSubmit));
      await _settle(tester);
      expect(find.text(en.crrScore('75')), findsOneWidget);
      expect(find.text(en.crrRubricLabel), findsOneWidget);
      expect(find.text(en.crrTipCoverTopics), findsOneWidget);
      expect(find.text(en.crrCoveredCount('3', '5')), findsOneWidget);
      await tester.ensureVisible(find.text(en.crrAiFeedbackBtn));
      await tester.tap(find.text(en.crrAiFeedbackBtn));
      await _settle(tester);
      expect(find.text(en.crrAiFeedbackBtn), findsNothing); // replaced by the honest message
      await tester.ensureVisible(find.text(en.crrNext));
      await tester.tap(find.text(en.crrNext));
      await _settle(tester);
      expect(find.text('Why do you want to work in a bank?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Because I like serving customers.');
      await tester.tap(find.text(en.crrSubmit));
      await _settle(tester);
      await tester.ensureVisible(find.text(en.crrFinish));
      await tester.tap(find.text(en.crrFinish));
      await _settle(tester);
      expect(find.text(en.crrDoneTitle), findsOneWidget);
      expect(find.text(en.crrDoneAvg('75')), findsOneWidget);
    });

    testWidgets('Bangla: Bangla digits, 200% font, dark, mic on the answer box', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(_app(const InterviewRoleScreen(), lang: 'bn', scale: 2.0, dark: true));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      _noAsciiDigits(tester);
      await tester.tap(find.text('ব্যাংক অফিসার'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.mic_none_rounded).evaluate().isNotEmpty ||
          find.byIcon(Icons.mic_rounded).evaluate().isNotEmpty, isTrue);
      _noAsciiDigits(tester);
    });
  });

  group('CV export', () {
    testWidgets('style chips, govt personal fields, ATS card, PDF + print', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const CvExportScreen(recordId: 1)));
      await _settle(tester);
      expect(find.text(en.crrAtsScore('78')), findsOneWidget);
      expect(find.text(en.crrAtsSummary), findsOneWidget);
      expect(find.text(en.crrFather), findsNothing);
      await tester.tap(find.text(en.crrFmtGovt));
      await _settle(tester);
      expect(find.text(en.crrFather), findsOneWidget);
      expect(find.text(en.crrFmtHelpGovt), findsOneWidget);
      // English CV: direct PDF + print page; Bangla CV: print page only
      expect(find.text(en.crrPdfDownload), findsOneWidget);
      await tester.tap(find.text(en.crrLangBn));
      await _settle(tester);
      expect(find.text(en.crrPdfDownload), findsNothing);
      expect(find.text(en.crrPrintPage), findsOneWidget);
    });

    testWidgets('Bangla, 200% font, dark: no overflow, Bangla digits', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(const CvExportScreen(recordId: 1), lang: 'bn', scale: 2.0, dark: true));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      _noAsciiDigits(tester);
    });
  });

  group('career_plus gate on existing screens', () {
    testWidgets('CV builder: bar hidden when OFF, fill-from-profile works when ON', (tester) async {
      _phone(tester);
      FeatureFlags.instance.debugOverride = {'career_plus': false};
      await tester.pumpWidget(_app(const CvBuilderScreen()));
      await _settle(tester);
      final start = find.text(en.cvStart);
      if (start.evaluate().isNotEmpty) {
        await tester.tap(start);
        await _settle(tester);
      }
      expect(find.text(en.crrFillProfile), findsNothing);
      FeatureFlags.instance.debugOverride = {'career_plus': true};
      await tester.pumpWidget(_app(const CvBuilderScreen()));
      await _settle(tester);
      if (find.text(en.cvStart).evaluate().isNotEmpty) {
        await tester.tap(find.text(en.cvStart));
        await _settle(tester);
      }
      expect(find.text(en.crrCvExportAction), findsOneWidget);
      await tester.tap(find.text(en.crrFillProfile));
      await _settle(tester);
      expect(find.text('Rahim Uddin'), findsOneWidget);
    });

    testWidgets('Mock interview: role entry only when ON', (tester) async {
      _phone(tester);
      FeatureFlags.instance.debugOverride = {'career_plus': false};
      await tester.pumpWidget(_app(const MockInterviewScreen()));
      await _settle(tester);
      expect(find.text(en.crrRoleEntry), findsNothing);
      FeatureFlags.instance.debugOverride = {'career_plus': true};
      await tester.pumpWidget(_app(const MockInterviewScreen()));
      await _settle(tester);
      expect(find.text(en.crrRoleEntry), findsOneWidget);
    });
  });
}
