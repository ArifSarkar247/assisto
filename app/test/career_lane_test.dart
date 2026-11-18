// career lane: Bangla CV PDF button + language, mock interview charge-once
// cost line, stale AI feedback cleared on a re-check, "End here" summary with
// per-question scores; Bangla digits, 200% font, dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/career/cv_export_screen.dart';
import 'package:assisto/screens/career/interview_role_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

/// FakeApi + a server that charges AI feedback once per answer and records
/// what the app asked for.
class _CareerApi extends FakeApi {
  _CareerApi({required super.lang});
  final List<String> gets = [];
  final Map<String, int> aiCalls = {};
  int charged = 0;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    return super.getJson(path);
  }

  @override
  Future<List<int>> getBytes(String path) async {
    gets.add(path);
    return '%PDF-1.4 fake'.codeUnits;
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    if (path != '/career/interview/feedback') return super.postJson(path, body);
    final answer = '${body['answer']}';
    final score = answer.length > 30 ? 80 : 40;
    final rubric = {
      'score': score, 'words': answer.split(' ').length, 'has_example': false, 'fillers': 0,
      'hits': [], 'missing': [], 'tips': ['add_example'], 'outline': {'bn': '', 'en': ''},
    };
    if (body['ai'] != true) return {'rubric': rubric, 'ai': null};
    final key = '${body['qid']}|$answer';
    final n = aiCalls[key] = (aiCalls[key] ?? 0) + 1;
    if (n == 1) charged += 1;
    return {
      'rubric': rubric,
      'ai': {'ai_used': true, 'text': 'AI-FEEDBACK $answer', 'cached': n > 1, 'charged': n > 1 ? 0 : 1},
    };
  }
}

Widget _app(Widget home, _CareerApi api, {String lang = 'en', double scale = 1.0, bool dark = false}) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  s.online = true;
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
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    ),
  );
}

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
    if (s.contains('http') || s.contains('@') || s.contains('AI-FEEDBACK')) continue;
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

  testWidgets('CV: Bangla CV gets the direct PDF in Bangla', (tester) async {
    _phone(tester);
    final api = _CareerApi(lang: 'en');
    await tester.pumpWidget(_app(const CvExportScreen(recordId: 1), api));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('crr-lang-bn')));
    await tester.tap(find.byKey(const ValueKey('crr-lang-bn')));
    await _settle(tester);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('crr-pdf')), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(en.crrPdfHelp2), findsOneWidget);
    expect(find.text(en.crrPrintHelp), findsNothing); // the old "Bangla = print page" line is gone
    await tester.tap(find.byKey(const ValueKey('crr-pdf')));
    await _settle(tester, 20);
    expect(api.gets, contains('/career/cv/pdf?lang=bn'));
  });

  testWidgets('interview: charge-once line, stale AI cleared, end here -> per-question summary', (tester) async {
    _phone(tester);
    final api = _CareerApi(lang: 'en');
    await tester.pumpWidget(_app(const InterviewRoleScreen(), api));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('crr-role-bank')));
    await _settle(tester);
    const a1 = 'I listen first, stay calm and give a clear solution with a timeline.';
    await tester.enterText(find.byKey(const ValueKey('crr-answer')), a1);
    await tester.tap(find.byKey(const ValueKey('crr-submit')));
    await _settle(tester);
    expect(find.text(en.crrScore('80')), findsOneWidget);
    // first AI feedback: charged once, says so
    await tester.ensureVisible(find.byKey(const ValueKey('crr-ai')));
    await tester.tap(find.byKey(const ValueKey('crr-ai')));
    await _settle(tester);
    expect(find.text('AI-FEEDBACK $a1'), findsOneWidget);
    expect(find.text(en.crrAiCharged('1')), findsOneWidget);
    // edit the answer + re-check: the OLD AI feedback must disappear
    await tester.enterText(find.byKey(const ValueKey('crr-answer')), 'Short one.');
    await tester.ensureVisible(find.byKey(const ValueKey('crr-submit')));
    await tester.tap(find.byKey(const ValueKey('crr-submit')));
    await _settle(tester);
    expect(find.text('AI-FEEDBACK $a1'), findsNothing);
    expect(find.text(en.crrScore('40')), findsOneWidget);
    // back to the first answer: AI again = the saved feedback, no new charge
    await tester.enterText(find.byKey(const ValueKey('crr-answer')), a1);
    await tester.tap(find.byKey(const ValueKey('crr-submit')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('crr-ai')));
    await tester.tap(find.byKey(const ValueKey('crr-ai')));
    await _settle(tester);
    expect(find.text(en.crrAiCachedFree), findsOneWidget);
    expect(api.charged, 1);
    // end after one question -> summary lists it with its score
    await tester.ensureVisible(find.byKey(const ValueKey('crr-end')));
    await tester.tap(find.byKey(const ValueKey('crr-end')));
    await _settle(tester);
    expect(find.text(en.crrDoneTitle), findsOneWidget);
    expect(find.text(en.crrDoneAvg('80')), findsOneWidget);
    expect(find.text(en.crrDoneQ('1', '80')), findsOneWidget);
    expect(find.text('How would you handle an angry customer?'), findsOneWidget);
  });

  testWidgets('interview Bangla: 200% font + dark, Bangla digits in the summary', (tester) async {
    _phone(tester, height: 1600);
    final api = _CareerApi(lang: 'bn');
    await tester.pumpWidget(_app(const InterviewRoleScreen(), api, lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('crr-role-bank')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('crr-answer')), 'আমি মন দিয়ে শুনি, শান্ত থাকি আর সমাধান দিই।');
    await tester.ensureVisible(find.byKey(const ValueKey('crr-submit')));
    await tester.tap(find.byKey(const ValueKey('crr-submit')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('crr-ai')));
    await tester.tap(find.byKey(const ValueKey('crr-ai')));
    await _settle(tester);
    expect(find.text(bn.crrAiCharged('১')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('crr-end')));
    await tester.tap(find.byKey(const ValueKey('crr-end')));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(bn.crrDoneQ('১', '৮০')), findsOneWidget);
    _noAsciiDigits(tester);
  });
}
