// gap-lp (owner order 17 Nov 10:10, feature gap sweep) — Language Partner:
// Submit asks first (no mis-tap ends a section), unfinished answers survive an
// app kill, a retry after a network failure never scores (charges) a part
// twice, the practice certificate button, downloaded mocks open with no
// internet, vocabulary progress survives no internet, and the
// 10-new-words-a-day goal really ends. Sample data only.
import 'dart:convert';
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
import 'package:assisto/screens/ielts_engine.dart' show ieltsToday;
import 'package:assisto/screens/lp2/lp_data.dart';
import 'package:assisto/screens/lp2/lp_engine.dart';
import 'package:assisto/screens/lp2/lp_mock.dart';
import 'package:assisto/screens/lp2/lp_vocab.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_lp2.dart';

Widget _app(Widget child, ApiClient api, {String lang = 'en'}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
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

/// Fails chosen calls once (no internet for that moment).
class _FlakyApi extends FakeApi {
  final Set<String> failOnce;
  final bool mocksOffline, vocabOffline;
  final List<(String, int)> updates = [];
  _FlakyApi({Set<String>? failOnce, this.mocksOffline = false, this.vocabOffline = false})
      : failOnce = {...?failOnce}, // mutable: a const set cannot remove()
        super(mode: FakeMode.data, lang: 'en');

  static String _p(String path) => path.startsWith('/') ? path.substring(1) : path;

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    if (failOnce.remove(_p(path))) throw const SocketException('offline');
    return super.postJson(path, body);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (mocksOffline && _p(path).startsWith('lp/mocks')) throw const SocketException('offline');
    return super.getJson(path);
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async {
    if (vocabOffline && path == kLpVocab) throw const SocketException('offline');
    return super.listItems(path);
  }

  @override
  Future<void> updateItem(String path, int id, Map<String, dynamic> body) async {
    updates.add((path, id));
    return super.updateItem(path, id, body);
  }
}

const _mock = {'id': 'ac-001', 'kind': 'academic', 'title_en': 'Academic mock 1', 'title_bn': 'x'};

Future<void> _tapSubmit(WidgetTester t) async {
  await t.tap(find.byKey(const Key('lp2-submit')));
  await t.pumpAndSettle();
}

Future<void> _confirm(WidgetTester t) async {
  await t.tap(find.byKey(const Key('lp2-submit-confirm')));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugLpAsset = (a) async => File(a).readAsStringSync();
    debugLpPlay = (_) async {};
    LpOffline.debugDisabled = true;
    LpOffline.debugList = null;
    AdBannerSlot.debugLoadConfig = () async => AdConfig.fromJson({'plan': 'premium', 'paid': true, 'ads_enabled': false});
    LpContent.debugReset();
    lp2Posts.clear();
  });

  testWidgets('Submit asks first: Keep going stays, Submit marks', (t) async {
    await t.pumpWidget(_app(const LpMockRunner(mock: _mock, sections: ['reading'], full: false), _FlakyApi()));
    await t.pumpAndSettle();
    await _tapSubmit(t);
    expect(find.text('Submit this section?'), findsOneWidget);
    expect(find.textContaining('questions are not answered yet.'), findsOneWidget);
    await t.tap(find.text('Keep going'));
    await t.pumpAndSettle();
    expect(lp2Posts.where((p) => '${p['path']}'.endsWith('/mark')), isEmpty);
    expect(find.text('Section practice'), findsOneWidget);
    await _tapSubmit(t);
    await _confirm(t);
    expect(lp2Posts.where((p) => '${p['path']}'.endsWith('/mark')).length, 1);
    expect(find.text('Your result'), findsOneWidget);
  });

  testWidgets('full mock: the no-return line is shown', (t) async {
    await t.pumpWidget(_app(const LpMockRunner(mock: _mock, sections: kLpSections, full: true), _FlakyApi()));
    await t.pumpAndSettle();
    await _tapSubmit(t);
    expect(find.textContaining('you cannot come back to this section'), findsOneWidget);
  });

  testWidgets('unfinished answers and time left come back after the app was closed', (t) async {
    SharedPreferences.setMockInitialValues({
      'lp2_draft_ac-001_reading': jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch,
        'i': 0,
        'left': {'reading': 1234},
        'ans': {'reading': {'4': 'hyacinth'}, 'listening': {}},
        'w': {},
        'sp': {},
        'spoken': {},
      }),
    });
    await t.pumpWidget(_app(const LpMockRunner(mock: _mock, sections: ['reading'], full: false), _FlakyApi()));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Your unfinished answers are back.'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^20:3[34]$')), findsOneWidget); // 1234 s, not a fresh hour
    await t.pumpAndSettle();
    await _tapSubmit(t);
    await _confirm(t);
    final mark = lp2Posts.firstWhere((p) => '${p['path']}'.endsWith('/mark'));
    expect(mark['answers'], {'4': 'hyacinth'});
    final p = await SharedPreferences.getInstance();
    expect(p.getString('lp2_draft_ac-001_reading'), isNull); // finished: the draft is gone
  });

  testWidgets('a retry after a failed score never scores (charges) the writing twice', (t) async {
    final api = _FlakyApi(failOnce: {'lp/score/speaking'});
    await t.pumpWidget(_app(const LpMockRunner(mock: _mock, sections: kLpSections, full: true), api));
    await t.pumpAndSettle();
    await _tapSubmit(t);
    await _confirm(t); // listening -> reading
    await _tapSubmit(t);
    await _confirm(t); // reading -> writing
    await t.enterText(find.byKey(const Key('lp2-w1')), 'In 2005 most people took the bus; by 2025 the metro led.');
    await _tapSubmit(t);
    await _confirm(t); // writing -> speaking
    await t.enterText(find.byKey(const Key('lp2-s1')), 'I live in Dhaka near a busy market.');
    await _tapSubmit(t);
    await _confirm(t); // finish: speaking fails (no internet)
    expect(find.text('Your result'), findsNothing);
    await _tapSubmit(t);
    await _confirm(t); // try again
    expect(find.text('Your result'), findsOneWidget);
    final paths = lp2Posts.map((p) => p['path']).toList();
    expect(paths.where((p) => p == 'lp/score/writing').length, 1);
    expect(paths.where((p) => '$p'.endsWith('/mark')).length, 2);
    expect(paths.where((p) => p == 'lp/score/speaking').length, 1);
  });

  testWidgets('practice certificate button only when the server offers one', (t) async {
    Widget result(Map<String, dynamic> fin) => LpMockResultScreen(
        title: 'Academic mock 1',
        sections: kLpSections,
        bands: const {'listening': 7.0, 'reading': 6.5, 'writing': 6.0, 'speaking': 6.0},
        overall: 6.5,
        finish: fin);
    await t.pumpWidget(_app(result(fakeLp2Finish()), _FlakyApi()));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const Key('lp2-cert')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Practice certificate (PDF)'), findsOneWidget);
    await t.pumpWidget(_app(result({...fakeLp2Finish(), 'certificate_url': null}), _FlakyApi()));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('lp2-cert')), findsNothing);
  });

  testWidgets('no internet: mocks saved on the phone still open', (t) async {
    LpOffline.debugList = () async => [
          {'id': 'ac-001', 'kind': 'academic', 'title_en': 'Academic mock 1', 'title_bn': 'x', 'beta': false,
           'sections': kLpSections},
        ];
    await t.pumpWidget(_app(const LpIeltsHub(), _FlakyApi(mocksOffline: true)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('lp2-saved-offline')), findsOneWidget);
    expect(find.byKey(const Key('lp2-mock-ac-001')), findsOneWidget);
    expect(find.text('On this phone'), findsOneWidget);
  });

  testWidgets('vocabulary: no internet shows the phone copy and says so', (t) async {
    final today = ieltsToday();
    SharedPreferences.setMockInitialValues({
      'lp2_vocab_rows': jsonEncode([
        {'id': 1, 'card_id': 'ielts_education_curriculum', 'box': 3, 'due': today + 3},
      ]),
    });
    await t.pumpWidget(_app(const LpVocabScreen(), _FlakyApi(vocabOffline: true)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('lp2-vocab-offline')), findsOneWidget);
  });

  test('vocabulary: a move saved offline is sent on the next load', () async {
    SharedPreferences.setMockInitialValues({
      'lp2_vocab_pending': jsonEncode({
        'ielts_education_compulsory': {'card_id': 'ielts_education_compulsory', 'box': 2, 'due': 5, 'last_day': 3},
      }),
    });
    await LpVocabStore.queue('x_new', {'card_id': 'x_new', 'box': 1, 'due': 4, 'first_day': 3});
    final api = _FlakyApi();
    final (rows, offline) = await LpVocabStore.load(api);
    expect(offline, isFalse);
    expect(api.updates, [(kLpVocab, 2)]); // the existing row was updated, not duplicated
    expect(rows.firstWhere((r) => r['card_id'] == 'ielts_education_compulsory')['box'], 2);
    expect(rows.any((r) => r['card_id'] == 'x_new'), isTrue); // created
    final p = await SharedPreferences.getInstance();
    expect(jsonDecode(p.getString('lp2_vocab_pending')!), isEmpty);
    // a newer move that reached the server drops the older queued one
    await LpVocabStore.queue('a', {'card_id': 'a', 'box': 1});
    await LpVocabStore.remember({'card_id': 'a', 'box': 3, 'id': 9});
    expect(jsonDecode(p.getString('lp2_vocab_pending')!), isEmpty);
  });

  test('10 new words a day: words started today count', () {
    final s = <String, VocabState>{'a': const VocabState(1, 101)};
    expect(dueWords(['a', 'b', 'c', 'd'], s, 100, newPerDay: 2), ['b', 'c']);
    expect(dueWords(['a', 'b', 'c', 'd'], s, 100, newPerDay: 2, introducedToday: 1), ['b']);
    expect(dueWords(['a', 'b', 'c', 'd'], s, 100, newPerDay: 2, introducedToday: 5), isEmpty);
  });
}
