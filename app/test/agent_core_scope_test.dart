// AF-11: a run that needs two topics shows one explicit scope line per topic
// (what the agent may / may not do) — server text in the user's language,
// no strings of the app's own; nothing shown when the server sends none;
// no overflow at 200% text in dark mode.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/agent_core/agent_core_source.dart';
import 'package:assisto/screens/agent_core/agent_run_panel.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'agent_core_fakes.dart';
import 'fake_api.dart';

Widget _app(Widget child, {String lang = 'en', double scale = 1.0, bool dark = false}) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
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
      builder: (ctx, c) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

Map<String, dynamic> _twoTopics(bool bn) => {
      ...acRunJson('done', bn: bn),
      'topic': 'business',
      'topic_label': bn ? 'ব্যবসা + পরিবার' : 'Business + Family',
      'scope_title': bn ? 'এই কাজে আমার সীমা' : 'What I may do here',
      'topics': [
        {
          'key': 'business',
          'label': bn ? 'ব্যবসা' : 'Business',
          'may_line': bn
              ? 'যা করতে পারি: বাকি, স্টক, লিড, অর্ডার ও চ্যাট দেখা'
              : 'Can: see dues, stock, leads, orders and chats',
          'not_line': bn
              ? 'যা করি না: অনুমোদন ছাড়া কোনো গ্রাহককে মেসেজ'
              : "Won't: message a customer without your approval",
        },
        {
          'key': 'family',
          'label': bn ? 'পরিবার' : 'Family',
          'may_line': bn ? 'যা করতে পারি: জন্মদিন দেখা' : 'Can: see birthdays',
          'not_line':
              bn ? 'যা করি না: কারো লোকেশন দেখানো' : "Won't: show anyone's location",
        },
      ],
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.debugOverride = {'agent_core': true};
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(360 * 3, 1800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('two topics: one scope block, both topics with may / may-not lines', (tester) async {
    phone(tester);
    final run = AcRun.fromJson(_twoTopics(false));
    expect(run.scopes.length, 2);
    await tester.pumpWidget(_app(AcRunPanel(source: FakeAgentCore('data'), run: run)));
    await tester.pump();
    expect(find.byKey(const ValueKey('ac_scope')), findsOneWidget);
    expect(find.text('What I may do here'), findsOneWidget);
    expect(find.text('Business'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text("Won't: show anyone's location"), findsOneWidget);
    expect(find.text('Can: see dues, stock, leads, orders and chats'), findsOneWidget);
  });

  testWidgets('Bangla: the server lines as sent', (tester) async {
    phone(tester);
    await tester.pumpWidget(_app(
        AcRunPanel(source: FakeAgentCore('data', bn: true), run: AcRun.fromJson(_twoTopics(true))),
        lang: 'bn'));
    await tester.pump();
    expect(find.text('এই কাজে আমার সীমা'), findsOneWidget);
    expect(find.text('যা করি না: কারো লোকেশন দেখানো'), findsOneWidget);
  });

  testWidgets('no topics from the server: no scope block', (tester) async {
    phone(tester);
    await tester.pumpWidget(
        _app(AcRunPanel(source: FakeAgentCore('data'), run: AcRun.fromJson(acRunJson('done')))));
    await tester.pump();
    expect(find.byKey(const ValueKey('ac_scope')), findsNothing);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('no overflow at 200% ($lang, dark)', (tester) async {
      phone(tester);
      await tester.pumpWidget(_app(
          AcRunPanel(
              source: FakeAgentCore('data', bn: lang == 'bn'),
              run: AcRun.fromJson(_twoTopics(lang == 'bn'))),
          lang: lang,
          scale: 2.0,
          dark: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('ac_scope')), findsOneWidget);
    });
  }
}
