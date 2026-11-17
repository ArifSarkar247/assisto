// messv2 — Mess and bachelor V2 (owner order 10 Nov 01:20, Part 2 A–L).
// Every Save really sends (no dead button), errors are clear, offline writes
// queue and sync, Bangla digits, 200 % font, dark, the group card.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/mess/mess_detail_screen.dart';
import 'package:assisto/screens/mess/mess_store.dart';
import 'package:assisto/screens/mess_accounting_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/mess_group_card.dart';

import 'fake_api.dart';

class _RecApi extends FakeApi {
  _RecApi({super.mode, super.lang});
  final posts = <MapEntry<String, Map<String, dynamic>>>[];
  bool offline = false;
  bool plainGroup = false;
  bool mealCutoff = false; // gatefix: the server's 409 "cutoff" (race at 21:59:59)

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (offline) throw const SocketException('offline');
    if (mealCutoff && path.endsWith('/meals')) {
      throw ApiException('Changes for this day closed at 22:00. Ask the manager.', 409, null, 'cutoff');
    }
    posts.add(MapEntry(path, body));
    return super.postJson(path, body);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (plainGroup && path.startsWith('/mess/v2/by-group/')) return {'card': null};
    return super.getJson(path);
  }
}

AppState _state(_RecApi api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  s.online = true;
  return s;
}

Widget _app(Widget home, _RecApi api,
        {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api, lang),
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
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('number parser (shared contract with savesweep)', () {
    test('Bangla, Latin, commas, taka sign', () {
      expect(messTakaToPoisha('৫০০'), 50000);
      expect(messTakaToPoisha('1,500.50'), 150050);
      expect(messTakaToPoisha('৳ ৭০০'), 70000);
      expect(messTakaToPoisha('Tk 12'), 1200);
      expect(messTakaToPoisha(''), isNull);
      expect(messTakaToPoisha('abc'), isNull);
      expect(messTakaToPoisha('0'), isNull);
      expect(messTakaToPoisha('1.234'), isNull);
    });
  });

  testWidgets('create mess: name required, then Save really sends', (tester) async {
    final api = _RecApi(mode: FakeMode.empty, lang: 'en');
    await tester.pumpWidget(_app(const MessAccountingScreen(), api));
    await _settle(tester);
    expect(find.text('Run your mess together'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mess-create')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mess-settings-save')));
    await _settle(tester);
    expect(find.text('Enter the mess name'), findsOneWidget); // never a silent no-op
    expect(api.posts, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('mess-name')), 'Rampura Mess');
    await tester.tap(find.byKey(const ValueKey('mess-settings-save')));
    await _settle(tester);
    final p = api.posts.firstWhere((e) => e.key == '/mess/v2');
    expect(p.value['name'], 'Rampura Mess');
    expect('${p.value['client_id']}', isNotEmpty);
  });

  testWidgets('add bazar with Bangla digits sends integer poisha', (tester) async {
    final api = _RecApi(lang: 'bn');
    await tester.pumpWidget(_app(const MessDetailScreen(messId: 1, initialTab: 1), api, lang: 'bn'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mess-add-bazar')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('entry-amount')), '৫০০');
    await tester.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(tester);
    final p = api.posts.firstWhere((e) => e.key == '/mess/v2/1/entries');
    expect(p.value['kind'], 'bazar');
    expect(p.value['amount'], 50000);
    expect('${p.value['client_id']}', isNotEmpty);
  });

  testWidgets('a bad amount shows a clear error and sends nothing', (tester) async {
    final api = _RecApi(lang: 'en');
    await tester.pumpWidget(_app(const MessDetailScreen(messId: 1, initialTab: 2), api));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mess-add-deposit')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('entry-amount')), 'abc');
    await tester.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(tester);
    expect(find.text('Enter the amount in taka, for example 500'), findsOneWidget);
    expect(api.posts.where((e) => e.key.endsWith('/entries')), isEmpty);
  });

  // gatefix (release gate 44133650344): after the cut-off the server refuses
  // a member's meal change with 409 "cutoff". The screen must SAY so (the
  // server's text), never crash and never keep it as a silent offline write.
  testWidgets('meal change refused at the cut-off: clear message, not queued', (tester) async {
    final api = _RecApi(lang: 'en')..mealCutoff = true;
    await tester.pumpWidget(_app(const MessDetailScreen(messId: 1), api));
    await _settle(tester);
    final now = DateTime.now().add(const Duration(days: 1));
    final iso = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final day = find.byKey(ValueKey('mess-day-$iso'));
    await tester.scrollUntilVisible(day, 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(day);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('meal-save')));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('closed at 22:00'), findsOneWidget);
    expect(find.textContaining('Saved on this phone'), findsNothing);
    expect(await MessOutbox.pending(1), 0);
  });

  testWidgets('offline: the write is kept on the phone, then syncs', (tester) async {
    final api = _RecApi(lang: 'en');
    await tester.pumpWidget(_app(const MessDetailScreen(messId: 1, initialTab: 2), api));
    await _settle(tester);
    api.offline = true;
    await tester.tap(find.byKey(const ValueKey('mess-add-charge')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('charge-wifi')));
    await tester.ensureVisible(find.byKey(const ValueKey('entry-amount')));
    await tester.enterText(find.byKey(const ValueKey('entry-amount')), '700');
    await tester.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(tester);
    expect(find.textContaining('Saved on this phone'), findsOneWidget);
    expect(await MessOutbox.pending(1), 1);
    api.offline = false;
    final r = await MessOutbox.flush(api);
    expect(r.sent, 1);
    expect(await MessOutbox.pending(1), 0);
    final p = api.posts.firstWhere((e) => e.key == '/mess/v2/1/entries');
    expect(p.value['amount'], 70000);
    expect((p.value['data'] as Map)['kind'], 'wifi');
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('meals + month tabs: no overflow at 200 % ($lang, dark=$dark)', (tester) async {
        tester.view.physicalSize = const Size(360 * 3, 780 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final api = _RecApi(lang: lang);
        for (final tab in [0, 1, 2, 3, 4]) {
          await tester.pumpWidget(_app(
              MessDetailScreen(key: ValueKey('tab$tab'), messId: 1, initialTab: tab), api,
              lang: lang, scale: 2.0, dark: dark));
          await _settle(tester);
          expect(tester.takeException(), isNull, reason: 'tab $tab');
        }
      });
    }
    testWidgets('today + month numbers in the right digits ($lang)', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final api = _RecApi(lang: lang);
      await tester.pumpWidget(_app(const MessDetailScreen(messId: 1), api, lang: lang));
      await _settle(tester);
      expect(find.textContaining(lang == 'bn' ? 'আজ মোট মিল: ১০' : 'Meals today: 10'),
          findsOneWidget);
      await tester.pumpWidget(
          _app(const MessDetailScreen(key: ValueKey('month'), messId: 1, initialTab: 3), api,
              lang: lang));
      await _settle(tester);
      expect(find.textContaining(lang == 'bn' ? 'দেবেন ৳৪,৭৭১.৪৫' : 'Will pay ৳4,771.45'),
          findsOneWidget);
    });
  }

  testWidgets('group card: shows on a mess group, nothing on a normal group', (tester) async {
    final api = _RecApi(lang: 'en');
    await tester.pumpWidget(_app(const Scaffold(body: MessGroupCard(groupId: 41)), api));
    await _settle(tester);
    expect(find.byKey(const ValueKey('mess-group-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('mess-group-open')), findsOneWidget);
    expect(find.textContaining('Not set tomorrow yet: Dipu'), findsOneWidget);
    final plain = _RecApi(lang: 'en')..plainGroup = true;
    await tester.pumpWidget(_app(const Scaffold(body: MessGroupCard(groupId: 9)), plain));
    await _settle(tester);
    expect(find.byKey(const ValueKey('mess-group-card')), findsNothing);
  });
}
