// agentmem (WP-MEMORY): the agent's life-graph memory screen (fake server,
// no network): loading, flag off, error + retry, honest empty state, browse
// by type, add / edit / delete one, delete all (cancel + confirm), export to
// the share path, suggestions Keep / Don't keep, "still right?", pause
// learning + retention; entry card only with the flag; strict bn text and
// digits; 48 dp; dark + 200% text without overflow; TalkBack labels.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/agent_core/life_graph_screen.dart';
import 'package:assisto/screens/agent_core/life_graph_source.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

/// TEST fixtures only (never shown in the real app).
class FakeLifeGraph implements LifeGraphSource {
  final List<Map<String, dynamic>> facts;
  final List<Map<String, dynamic>> sugg;
  Map<String, dynamic> prefs = {
    'learning_paused': false,
    'retention_months': 18,
    'retention_choices': [6, 12, 18, 24]
  };
  final List<String> calls = [];
  Object? failWith;
  Completer<void>? gate;
  int _next = 100;

  FakeLifeGraph({List<Map<String, dynamic>>? facts, List<Map<String, dynamic>>? sugg})
      : facts = facts ?? [],
        sugg = sugg ?? [];

  static Map<String, dynamic> fact(int id, String type, String label, String value,
          {String relation = '',
          String origin = 'user',
          bool sensitive = false,
          bool stillRight = false,
          String status = 'active',
          int? replaces}) =>
      {
        'id': id,
        'type': type,
        'label': label,
        'value': value,
        'relation': relation,
        'when': '',
        'status': status,
        'origin': origin,
        'sensitive': sensitive,
        'use_in_ai': !sensitive,
        'still_right': stillRight,
        'replaces': replaces,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  @override
  Future<Map<String, dynamic>> list({String type = '', String status = 'active'}) async {
    calls.add('list:$status:$type');
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    final counts = <String, int>{for (final k in kLgTypes) k: 0};
    for (final f in facts) {
      counts[f['type'] as String] = (counts[f['type']] ?? 0) + 1;
    }
    final src = status == 'suggested' ? sugg : facts;
    return {
      'facts': [for (final f in src) if (type.isEmpty || f['type'] == type) f],
      'counts': counts,
      'total': facts.length,
      'suggestions': sugg.length,
      'prefs': prefs,
    };
  }

  @override
  Future<Map<String, dynamic>> create(Map<String, dynamic> f) async {
    calls.add('create:${f['type']}:${f['label']}:${f['value']}');
    final row = fact(_next++, f['type'] as String, f['label'] as String, f['value'] as String);
    facts.add(row);
    return row;
  }

  @override
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> fields) async {
    calls.add('update:$id:${fields['value']}');
    final f = facts.firstWhere((e) => e['id'] == id);
    f.addAll({'value': fields['value'], 'label': fields['label']});
    return f;
  }

  @override
  Future<void> delete(int id) async {
    calls.add('delete:$id');
    facts.removeWhere((e) => e['id'] == id);
  }

  @override
  Future<Map<String, dynamic>> approve(int id) async {
    calls.add('approve:$id');
    final s = sugg.firstWhere((e) => e['id'] == id);
    sugg.remove(s);
    facts.add({...s, 'status': 'active'});
    return s;
  }

  @override
  Future<void> reject(int id) async {
    calls.add('reject:$id');
    sugg.removeWhere((e) => e['id'] == id);
  }

  @override
  Future<Map<String, dynamic>> confirm(int id) async {
    calls.add('confirm:$id');
    final f = facts.firstWhere((e) => e['id'] == id);
    f['still_right'] = false;
    return f;
  }

  @override
  Future<int> deleteAll() async {
    calls.add('delete_all');
    final n = facts.length + sugg.length;
    facts.clear();
    sugg.clear();
    return n;
  }

  @override
  Future<List<int>> exportBytes() async {
    calls.add('export');
    return utf8.encode(jsonEncode({'format': 'assisto-life-graph', 'facts': facts}));
  }

  @override
  Future<Map<String, dynamic>> setPrefs(Map<String, dynamic> p) async {
    calls.add('prefs:${jsonEncode(p)}');
    prefs = {...prefs, ...p};
    return prefs;
  }
}

FakeLifeGraph _seeded({bool bn = false}) => FakeLifeGraph(facts: [
      FakeLifeGraph.fact(1, 'person', bn ? 'আম্মু' : 'Ammu', bn ? 'জন্মদিন ১২ মার্চ' : 'birthday 12 March',
          relation: bn ? 'মা' : 'mother'),
      FakeLifeGraph.fact(2, 'place', 'Office', 'Gulshan 2'),
      FakeLifeGraph.fact(3, 'routine', 'Blood pressure', 'checkup monthly', sensitive: true),
      FakeLifeGraph.fact(4, 'date', 'Anniversary', '20 January', stillRight: true),
    ], sugg: [
      FakeLifeGraph.fact(50, 'routine', 'House rent', 'every month ~day 5, about ৳12,000',
          origin: 'learn', status: 'suggested'),
      FakeLifeGraph.fact(51, 'place', 'Office', 'Banani', origin: 'run', status: 'suggested',
          replaces: 2),
    ]);

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
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

void _phone(WidgetTester tester, {double height = 2400}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _reveal(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 300,
      scrollable: find.byType(Scrollable).first);
  await tester.pump();
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
    FeatureFlags.instance.debugOverride = {'agent_core': true};
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  testWidgets('loading, then the list with privacy note, types and badges', (tester) async {
    _phone(tester);
    final src = _seeded()..gate = Completer<void>();
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel(en.lgLoading), findsOneWidget);
    src.gate!.complete();
    await _settle(tester);
    expect(find.text(en.lgPrivacyNote), findsOneWidget);
    expect(find.text('Ammu (mother)'), findsOneWidget);
    expect(find.text(en.lgSensitive), findsOneWidget);
    expect(find.text('${en.lgTypePerson} · 1'), findsOneWidget);
    expect(find.text('${en.lgAll} · 4'), findsOneWidget);
    expect(find.text(en.lgSuggestionsTitle('2')), findsOneWidget);
    expect(find.text(en.lgChangeTo('Banani')), findsOneWidget); // update suggestion
    expect(find.text('${en.lgTypeRoutine} · ${en.lgOriginLearn}'), findsOneWidget);
    expect(find.text(en.lgStillRight), findsOneWidget);
    // TalkBack: the edit affordance is labelled
    expect(find.bySemanticsLabel(RegExp(en.lgEdit)), findsWidgets);
  });

  testWidgets('browse by type filters on the server', (tester) async {
    _phone(tester);
    final src = _seeded();
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('lg_chip_place')));
    await _settle(tester);
    expect(src.calls, contains('list:active:place'));
    expect(find.byKey(const ValueKey('lg_fact_2')), findsOneWidget);
    expect(find.byKey(const ValueKey('lg_fact_1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lg_chip_business')));
    await _settle(tester);
    expect(find.text(en.lgFilterEmpty), findsOneWidget);
  });

  testWidgets('suggestions: Keep approves, Don\'t keep rejects — nothing saved by itself',
      (tester) async {
    _phone(tester);
    final src = _seeded();
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await _settle(tester);
    expect(src.calls.where((c) => c.startsWith('approve')), isEmpty);
    await tester.tap(find.byKey(const ValueKey('lg_keep_50')));
    await _settle(tester);
    expect(src.calls, contains('approve:50'));
    expect(find.text(en.lgKept), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg_reject_51')));
    await _settle(tester);
    expect(src.calls, contains('reject:51'));
    expect(find.byKey(const ValueKey('lg_sugg_51')), findsNothing);
    expect(find.text(en.lgSuggestionsTitle('1')), findsNothing);
  });

  testWidgets('add, edit and delete one fact', (tester) async {
    _phone(tester);
    final src = _seeded();
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('lg_add')));
    await _settle(tester);
    expect(find.text(en.lgAddTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg_save')));
    await tester.pump();
    expect(find.text(en.lgNeedText), findsOneWidget); // honest validation
    await tester.enterText(find.byKey(const ValueKey('lg_field_label')), 'Gym');
    await tester.enterText(find.byKey(const ValueKey('lg_field_value')), 'Tuesdays');
    await tester.tap(find.byKey(const ValueKey('lg_save')));
    await _settle(tester);
    expect(src.calls, contains('create:person:Gym:Tuesdays'));
    await tester.tap(find.byKey(const ValueKey('lg_fact_2')));
    await _settle(tester);
    expect(find.text(en.lgEditTitle), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('lg_field_value')), 'Banani 11');
    await tester.tap(find.byKey(const ValueKey('lg_save')));
    await _settle(tester);
    expect(src.calls, contains('update:2:Banani 11'));
    await tester.tap(find.byKey(const ValueKey('lg_fact_2')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('lg_delete_one')));
    await _settle(tester);
    expect(src.calls, contains('delete:2'));
    expect(find.byKey(const ValueKey('lg_fact_2')), findsNothing);
  });

  testWidgets('delete all needs a confirm; cancel keeps everything', (tester) async {
    _phone(tester);
    final src = _seeded();
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await _settle(tester);
    await _reveal(tester, 'lg_delete_all_button');
    await tester.tap(find.byKey(const ValueKey('lg_delete_all_button')));
    await _settle(tester);
    expect(find.text(en.lgDeleteAllTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg_delete_all_cancel')));
    await _settle(tester);
    expect(src.calls.contains('delete_all'), isFalse);
    await _reveal(tester, 'lg_delete_all_button');
    await tester.tap(find.byKey(const ValueKey('lg_delete_all_button')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('lg_delete_all_confirm')));
    await _settle(tester);
    expect(src.calls, contains('delete_all'));
    expect(find.text(en.lgDeleteAllDone('6')), findsOneWidget);
    expect(find.byKey(const ValueKey('lg_empty')), findsOneWidget);
  });

  testWidgets('export hands the JSON to the share path (never e-mailed)', (tester) async {
    _phone(tester);
    final src = _seeded();
    List<int>? got;
    await tester.pumpWidget(_app(LifeGraphScreen(source: src, onExportBytes: (b) async => got = b)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('lg_export')));
    await _settle(tester);
    expect(src.calls, contains('export'));
    expect(jsonDecode(utf8.decode(got!))['format'], 'assisto-life-graph');
    expect(find.text(en.lgExportDone), findsOneWidget);
  });

  testWidgets('still right? -> yes; pause learning; retention', (tester) async {
    _phone(tester);
    final src = _seeded();
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('lg_confirm_4')));
    await _settle(tester);
    expect(src.calls, contains('confirm:4'));
    expect(find.text(en.lgStillRight), findsNothing);
    expect(find.text(en.lgLearningOn), findsOneWidget);
    await _reveal(tester, 'lg_pause');
    await tester.tap(find.byKey(const ValueKey('lg_pause')));
    await _settle(tester);
    expect(src.calls, contains('prefs:{"learning_paused":true}'));
    expect(find.text(en.lgLearningPaused), findsOneWidget);
    await _reveal(tester, 'lg_ret_6');
    await tester.tap(find.byKey(const ValueKey('lg_ret_6')));
    await _settle(tester);
    expect(src.calls, contains('prefs:{"retention_months":6}'));
  });

  testWidgets('honest empty state', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(LifeGraphScreen(source: FakeLifeGraph())));
    await _settle(tester);
    expect(find.text(en.lgEmptyTitle), findsOneWidget);
    expect(find.text(en.lgEmptyBody), findsOneWidget);
    expect(find.byKey(const ValueKey('lg_fact_1')), findsNothing);
  });

  testWidgets('flag off on the server -> honest "not switched on", no actions', (tester) async {
    _phone(tester);
    final src = FakeLifeGraph()..failWith = ApiException('', 403);
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await _settle(tester);
    expect(find.text(en.lgFeatureOff), findsOneWidget);
    expect(find.byKey(const ValueKey('lg_add')), findsNothing);
    expect(find.byKey(const ValueKey('lg_export')), findsNothing);
  });

  testWidgets('network error -> message + retry recovers', (tester) async {
    _phone(tester);
    final src = _seeded()..failWith = ApiException('', 500);
    await tester.pumpWidget(_app(LifeGraphScreen(source: src)));
    await _settle(tester);
    expect(find.text(en.lgErrorLoad), findsOneWidget);
    src.failWith = null;
    await tester.tap(find.text(en.lgRetry));
    await _settle(tester);
    expect(find.text('Ammu (mother)'), findsOneWidget);
  });

  testWidgets('Bangla: strict bn labels and Bangla digits', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(LifeGraphScreen(source: _seeded(bn: true)), lang: 'bn'));
    await _settle(tester);
    expect(find.text(bn.lgTitle), findsOneWidget);
    expect(find.text(bn.lgSuggestionsTitle('২')), findsOneWidget);
    expect(find.text('${bn.lgAll} · ৪'), findsOneWidget);
    expect(find.text('আম্মু (মা)'), findsOneWidget);
    expect(find.text(en.lgTitle), findsNothing);
    expect(find.text(en.lgPrivacyNote), findsNothing);
  });

  testWidgets('48 dp targets; dark + 200% text without overflow', (tester) async {
    _phone(tester, height: 5200);
    await tester.pumpWidget(_app(LifeGraphScreen(source: _seeded()), dark: true, scale: 2.0));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    for (final k in ['lg_keep_50', 'lg_reject_50', 'lg_confirm_4', 'lg_delete_all_button']) {
      await _reveal(tester, k);
      final sz = tester.getSize(find.byKey(ValueKey(k)));
      expect(sz.height >= 48 && sz.width >= 48, isTrue, reason: '$k $sz');
    }
    await tester.pumpWidget(_app(LifeGraphScreen(source: _seeded(bn: true)),
        lang: 'bn', dark: true, scale: 2.0));
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('entry card on the AI knows page only with the flag', (tester) async {
    _phone(tester);
    expect(LifeGraphEntryCard.visible, isTrue);
    FeatureFlags.instance.debugOverride = {'agent_core': false};
    expect(LifeGraphEntryCard.visible, isFalse);
    FeatureFlags.instance.debugOverride = {'agent_core': true};
    await tester.pumpWidget(_app(const Scaffold(body: LifeGraphEntryCard())));
    await _settle(tester);
    expect(find.text(en.lgEntryTitle), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('lg_entry'))).height >= 48, isTrue);
  });
}
