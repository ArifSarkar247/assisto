// bizops: the morning BUSINESS card (Agent Core "business" topic) — lines
// from the server shown as-is, one-tap actions start a run that stops at the
// approval card, after approval WhatsApp opens with the ready message,
// supplier picker (and its empty state with a way out), honest states
// (feature off / no shop / empty / offline), 200% text, dark, Bangla, 48 dp.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/agent_core/agent_core_screen.dart';
import 'package:assisto/screens/agent_core/agent_core_source.dart';
import 'package:assisto/screens/agent_core/biz_brief_screen.dart';
import 'package:assisto/screens/agent_core/biz_brief_source.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';

import 'agent_core_fakes.dart';
import 'bizops_fakes.dart';
import 'fake_api.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  s.online = true;
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
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 1800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.debugOverride = {'agent_core': true, 'business': true};
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  testWidgets('card shows the server lines, actions, questions and the cost math', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(BizBriefScreen(source: FakeBizBrief('data'), agentSource: BoAgentFake())));
    await _settle(tester);
    expect(find.text(en.boTitle), findsOneWidget);
    for (final k in ['sales', 'dues', 'stock', 'followups', 'cash']) {
      expect(find.byKey(ValueKey('bo_line_$k')), findsOneWidget, reason: k);
    }
    expect(find.textContaining('profit ৳2,180'), findsOneWidget);
    expect(find.byKey(const ValueKey('bo_act_tagada_Karim')), findsOneWidget);
    expect(find.byKey(const ValueKey('bo_act_reorder_')), findsOneWidget);
    expect(find.byKey(const ValueKey('bo_act_followup_Nasir Traders')), findsOneWidget);
    expect(find.text(en.boNeedsOk), findsOneWidget);
    expect(find.byKey(const ValueKey('bo_q_profit_today')), findsOneWidget);
    expect(find.text(en.boNoAiNote), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('bo_cost')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text(en.boCost));
    await _settle(tester);
    expect(find.textContaining('margin 62%'), findsOneWidget);
    expect(find.textContaining('0 credits'), findsOneWidget);
  });

  testWidgets('tagada tap -> approval card -> approve -> WhatsApp button', (tester) async {
    _phone(tester);
    final src = FakeBizBrief('data');
    final ac = BoAgentFake();
    await tester.pumpWidget(_app(BizBriefScreen(source: src, agentSource: ac)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bo_act_tagada_Karim')));
    await _settle(tester);
    expect(src.acts.single['kind'], 'tagada');
    expect(src.acts.single['customer'], 'Karim');
    expect((src.acts.single['client_id'] as String).startsWith('bo-'), isTrue);
    expect(find.byType(BizRunScreen), findsOneWidget);
    expect(find.textContaining('Karim a due reminder'), findsOneWidget);
    expect(find.byKey(const ValueKey('ac_share_wa_khata.tagada')), findsNothing); // nothing before OK
    await tester.tap(find.text(en.acApprove).first);
    await _settle(tester, 20);
    expect(ac.calls, contains('decide:31:approve'));
    expect(find.byKey(const ValueKey('ac_share_wa_khata.tagada')), findsOneWidget);
    expect(find.byKey(const ValueKey('ac_share_other_khata.tagada')), findsOneWidget);
    expect(find.text(en.boOpenWhatsApp), findsOneWidget);
  });

  testWidgets('reorder asks which supplier first, then starts with the items', (tester) async {
    _phone(tester);
    final src = FakeBizBrief('data', bn: true);
    await tester.pumpWidget(
        _app(BizBriefScreen(source: src, agentSource: BoAgentFake(bn: true)), lang: 'bn'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bo_act_reorder_')));
    await _settle(tester);
    expect(find.text(bn.boPickSupplier), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bo_supplier_Mondol Traders')));
    await _settle(tester);
    final b = src.acts.single;
    expect(b['kind'], 'reorder');
    expect(b['supplier'], 'Mondol Traders');
    expect((b['items'] as List).length, 2);
  });

  testWidgets('no supplier: honest how-to + a way to the ledger, nothing started', (tester) async {
    _phone(tester);
    final src = FakeBizBrief('no_supplier');
    await tester.pumpWidget(_app(BizBriefScreen(source: src, agentSource: BoAgentFake())));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bo_act_reorder_')));
    await _settle(tester);
    expect(find.text(en.boNoSupplier), findsOneWidget);
    expect(find.byKey(const ValueKey('bo_open_khata')), findsOneWidget);
    expect(src.acts, isEmpty);
  });

  testWidgets('question chip answers from the data (no approval)', (tester) async {
    _phone(tester);
    final src = FakeBizBrief('data');
    await tester.pumpWidget(_app(BizBriefScreen(source: src, agentSource: BoAgentFake())));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bo_q_top_due')));
    await _settle(tester);
    expect(src.acts.single, containsPair('key', 'top_due'));
    expect(find.byType(BizRunScreen), findsOneWidget);
  });

  testWidgets('honest states: off, no shop, empty, offline', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(BizBriefScreen(source: FakeBizBrief('off'), agentSource: BoAgentFake())));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bo_off')), findsOneWidget);
    await tester.pumpWidget(
        _app(BizBriefScreen(source: FakeBizBrief('no_business'), agentSource: BoAgentFake())));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bo_no_business')), findsOneWidget);
    expect(find.text(en.boSetupShop), findsOneWidget);
    await tester.pumpWidget(_app(BizBriefScreen(source: FakeBizBrief('empty'), agentSource: BoAgentFake())));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bo_empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('bo_open_shop')), findsOneWidget);
    expect(find.byKey(const ValueKey('bo_q_profit_today')), findsOneWidget);
    await tester.pumpWidget(
        _app(BizBriefScreen(source: FakeBizBrief('offline'), agentSource: BoAgentFake())));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bo_failed')), findsOneWidget);
    expect(find.text(en.boOffline), findsOneWidget);
    expect(find.text(en.boRetry), findsOneWidget);
  });

  testWidgets('agent screen entry shows only with the business flag', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(AgentCoreScreen(source: FakeAgentCore('data'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ac_open_biz_brief')), findsOneWidget);
    FeatureFlags.instance.debugOverride = {'agent_core': true, 'business': false};
    await tester.pumpWidget(_app(AgentCoreScreen(source: FakeAgentCore('data'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ac_open_biz_brief')), findsNothing);
    expect(ChatNav.builderFor('biz_brief'), isNotNull);
  });

  test('card parsing tolerates missing fields', () {
    final c = BoCard.fromJson({'has_business': true});
    expect(c.lines, isEmpty);
    expect(c.actions, isEmpty);
    final r = AcRun.fromJson({'id': 1, 'state': 'done', 'shares': [{'tool': 'x', 'text': ''}]});
    expect(r.shares, isEmpty);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('200% text + dark ($lang): no overflow', (tester) async {
      _phone(tester, height: 4200);
      await tester.pumpWidget(_app(
          BizBriefScreen(source: FakeBizBrief('data', bn: lang == 'bn'), agentSource: BoAgentFake()),
          lang: lang,
          scale: 2.0,
          dark: true));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_app(
          BizRunScreen(
              source: BoAgentFake(bn: lang == 'bn'),
              run: AcRun.fromJson(boRunJson('done', bn: lang == 'bn')),
              pollSchedule: const []),
          lang: lang,
          scale: 2.0,
          dark: true));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tap targets >= 48 dp and labelled', (tester) async {
    _phone(tester, height: 2400);
    final h = tester.ensureSemantics();
    await tester.pumpWidget(_app(BizBriefScreen(source: FakeBizBrief('data'), agentSource: BoAgentFake())));
    await _settle(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    h.dispose();
  });
}
