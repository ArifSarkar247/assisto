// ai-report (Google Play AI-generated content policy): every AI answer in the
// home chat and the Assisto AI chat can be reported — a 48dp flag next to it
// and "Report this answer" in the long-press menu — through a sheet with
// reasons (offensive / harmful / wrong / other) + an optional note, POSTed to
// /chat/report. bn + en, 200% font, dark mode.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/ai_report.dart';

import 'fake_api.dart';

class _ReportApi extends FakeApi {
  _ReportApi() : super(lang: 'en');
  final reports = <Map<String, dynamic>>[];
  int failWith = 0;

  @override
  Future<Map<String, dynamic>> agent(String text, {String? sessionId}) async =>
      {'reply': 'Here is a rude AI answer.', 'cards': [], 'session_id': '5',
       'message_id': 77};

  @override
  Future<List<Map<String, dynamic>>> chatMessages(String sessionId) async => [
        {'id': 10, 'role': 'user', 'text': 'tell me a joke', 'meta': {}},
        {'id': 11, 'role': 'assistant', 'text': 'A saved AI answer.',
         'meta': {'source': 'ai'}},
      ];

  @override
  Future<Map<String, dynamic>> aiReport({
    required String reason,
    required String surface,
    String? messageId,
    String? sessionId,
    String? text,
    String? note,
  }) async {
    if (failWith != 0) throw ApiException('no', failWith);
    reports.add({'reason': reason, 'surface': surface, 'message_id': messageId,
      'session_id': sessionId, 'text': text, 'note': note});
    return {'ok': true, 'id': reports.length};
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

Widget _app(AppState s, Widget child,
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
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: w!),
        home: Scaffold(body: child),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

Future<void> _sendHome(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'say something');
  await tester.pump();
  await tester.tap(find.byTooltip(_t(tester).send));
  await _settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AiReport.debugSubmit = null;
  });

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400 * 3, 860 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  testWidgets('home chat: flag -> sheet -> reason + note -> submits by message id',
      (tester) async {
    await phone(tester);
    final api = _ReportApi();
    await tester.pumpWidget(_app(_stub(api, 'en'), const AgentThreadScreen(debugSeed: [])));
    await _settle(tester);
    await _sendHome(tester);
    expect(find.text('Here is a rude AI answer.'), findsOneWidget);

    final flag = find.byKey(const ValueKey('ai_report_flag'));
    expect(flag, findsOneWidget);
    expect(tester.getSize(flag).height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('Report this answer'), findsOneWidget);

    await tester.tap(flag);
    await _settle(tester);
    expect(find.byKey(const ValueKey('ai_report_sheet')), findsOneWidget);
    for (final s in ['Offensive', 'Harmful or dangerous', 'Wrong or misleading',
      'Something else']) {
      expect(find.text(s), findsOneWidget);
    }
    // no reason picked -> an honest prompt, nothing sent
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(find.text('Choose a reason'), findsOneWidget);
    expect(api.reports, isEmpty);

    await tester.tap(find.byKey(const ValueKey('ai_report_reason_offensive')));
    await tester.enterText(find.byKey(const ValueKey('ai_report_note')), 'rude words');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(api.reports, [
      {'reason': 'offensive', 'surface': 'home', 'message_id': '77',
       'session_id': '5', 'text': null, 'note': 'rude words'}
    ]);
    expect(find.byKey(const ValueKey('ai_report_sheet')), findsNothing);
    expect(find.text('Thank you. We will review this answer.'), findsOneWidget);
  });

  testWidgets('home chat: long-press menu has Copy + Report this answer',
      (tester) async {
    await phone(tester);
    final api = _ReportApi();
    await tester.pumpWidget(_app(_stub(api, 'en'), const AgentThreadScreen(debugSeed: [])));
    await _settle(tester);
    await _sendHome(tester);
    await tester.longPress(find.text('Here is a rude AI answer.'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ai_answer_copy')), findsOneWidget);
    final item = find.byKey(const ValueKey('ai_answer_report'));
    expect(item, findsOneWidget);
    expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
    await tester.tap(item);
    await _settle(tester);
    expect(find.byKey(const ValueKey('ai_report_sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai_report_reason_wrong')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(api.reports.single['reason'], 'wrong');
  });

  testWidgets('TalkBack: the answer carries a "Report this answer" action',
      (tester) async {
    await phone(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(_stub(_ReportApi(), 'en'),
        const AgentThreadScreen(debugSeed: [])));
    await _settle(tester);
    await _sendHome(tester);
    final node = tester.getSemantics(find.byType(AiAnswerLongPress));
    expect(
        node.getSemanticsData().customSemanticsActionIds,
        isNotEmpty);
    expect(find.bySemanticsLabel('Report this answer'), findsWidgets);
    handle.dispose();
  });

  testWidgets('local notices (greeting / send failed) have no report action',
      (tester) async {
    await phone(tester);
    await tester.pumpWidget(_app(_stub(_ReportApi(), 'en'),
        const AgentThreadScreen(debugSeed: [], greeting: 'Hello!')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ai_report_flag')), findsNothing);
  });

  testWidgets('rate-limited -> honest message, sheet stays open', (tester) async {
    await phone(tester);
    final api = _ReportApi()..failWith = 429;
    await tester.pumpWidget(_app(_stub(api, 'en'), const AgentThreadScreen(debugSeed: [])));
    await _settle(tester);
    await _sendHome(tester);
    await tester.tap(find.byKey(const ValueKey('ai_report_flag')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai_report_reason_harmful')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(find.text('Too many reports. Please try again later.'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai_report_sheet')), findsOneWidget);
    api.failWith = 500;
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(find.text('Could not send the report. Please try again.'), findsOneWidget);
  });

  testWidgets('Assisto AI chat: saved answers have the flag + long-press report',
      (tester) async {
    await phone(tester);
    final api = _ReportApi();
    await tester.pumpWidget(_app(_stub(api, 'en'),
        const AiChatScreen(initialSession: {'id': 9, 'title': 'Jokes'})));
    await _settle(tester);
    expect(find.text('A saved AI answer.'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai_report_flag')), findsOneWidget);
    await tester.longPress(find.text('A saved AI answer.'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai_answer_report')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai_report_reason_other')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(api.reports.single,
        {'reason': 'other', 'surface': 'chat', 'message_id': '11',
         'session_id': '9', 'text': null, 'note': ''});
  });

  testWidgets('Bangla + 200% font + dark: sheet is Bangla and nothing overflows',
      (tester) async {
    await phone(tester);
    final api = _ReportApi();
    await tester.pumpWidget(_app(_stub(api, 'bn'),
        const AgentThreadScreen(debugSeed: []),
        lang: 'bn', scale: 2, dark: true));
    await _settle(tester);
    await _sendHome(tester);
    expect(find.byTooltip('উত্তরটি রিপোর্ট করুন'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai_report_flag')));
    await _settle(tester);
    for (final s in ['আপত্তিকর', 'ক্ষতিকর বা বিপজ্জনক', 'ভুল বা বিভ্রান্তিকর',
      'অন্য কিছু', 'রিপোর্ট পাঠান']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('Offensive'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai_report_reason_wrong')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('ai_report_send')));
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(api.reports.single['reason'], 'wrong');
    expect(find.text('ধন্যবাদ। আমরা উত্তরটি পর্যালোচনা করব।'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text-only targets (photo / business) send the shown text',
      (tester) async {
    await phone(tester);
    final api = _ReportApi();
    await tester.pumpWidget(_app(_stub(api, 'en'), const Center(
        child: AiReportButton(
            target: AiReportTarget(surface: 'photo', text: 'This is paracetamol.')))));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai_report_flag')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai_report_reason_harmful')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai_report_send')));
    await _settle(tester);
    expect(api.reports.single['surface'], 'photo');
    expect(api.reports.single['text'], 'This is paracetamol.');
    expect(api.reports.single['message_id'], isNull);
  });
}
