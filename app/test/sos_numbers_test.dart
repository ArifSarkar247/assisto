// sos-numbers (SAFETY P0): a new / reinstalled phone must have the family's
// saved emergency numbers for SOS call + SMS without the user ever opening the
// emergency card screen; offline with nothing saved = an honest line + 999;
// sign-out removes them; offline edits on this phone are never overwritten.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/family_sos/sos_numbers_sync.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/emergency_hub_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';

class _CardApi extends ApiClient {
  _CardApi({this.offline = false}) {
    token = 't';
  }
  bool offline;
  int gets = 0;
  final puts = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getEmergency() async {
    gets++;
    if (offline) throw Exception('offline');
    return {
      'blood_group': 'B+',
      'contacts': [
        {'name': 'Ammu', 'phone': '01700000011', 'relation': 'mother'},
        {'name': 'Abbu', 'phone': '০১৭০০০০০০১২', 'relation': 'father'},
      ],
    };
  }

  @override
  Future<void> putEmergency(Map<String, dynamic> body) async {
    if (offline) throw Exception('offline');
    puts.add(body);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/crisis/helplines') return {'helplines': const []};
    return {};
  }
}

Widget _app(Widget child, ApiClient api, {String lang = 'en', double scale = 1}) {
  final app = AppState()
    ..api = api
    ..locale = Locale(lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: app,
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
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    ),
  );
}

EmergencyHubScreen _hub() => EmergencyHubScreen(
      famCard: () async => const {},
      smsPeople: () async => const [],
      locate: () async => (23.75, 90.39),
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

List<String> _panelPhones(WidgetTester t) => [
      for (final c in t.widget<EmergencySosPanel>(find.byType(EmergencySosPanel)).contacts)
        '${c['phone']}'
    ];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    SosNumbersSync.resetForTest();
  });

  group('sync', () {
    test('fresh phone: the server card lands on the phone', () async {
      final api = _CardApi();
      await SosNumbersSync.sync(api);
      expect(SosNumbersSync.state.value, SosNumbersState.ok);
      final got = await SosNumbersSync.cachedContacts();
      expect(got.map((c) => c['phone']), ['01700000011', '০১৭০০০০০০১২']);
      expect(got.first['name'], 'Ammu');
    });

    test('offline edits on this phone go up first and are never overwritten', () async {
      await Settings.setString(SosNumbersSync.cacheKey,
          jsonEncode({'contacts': [{'name': 'Nanu', 'phone': '01800000000'}]}));
      await Settings.setString(SosNumbersSync.dirtyKey, '1');
      final api = _CardApi();
      await SosNumbersSync.sync(api);
      expect(api.puts.single['contacts'].first['phone'], '01800000000');
      expect(await Settings.getString(SosNumbersSync.dirtyKey), '');

      // still offline: the phone copy stays, dirty stays, state says failed
      await Settings.setString(SosNumbersSync.cacheKey,
          jsonEncode({'contacts': [{'name': 'Nanu', 'phone': '01800000001'}]}));
      await Settings.setString(SosNumbersSync.dirtyKey, '1');
      await SosNumbersSync.sync(_CardApi(offline: true));
      expect(SosNumbersSync.state.value, SosNumbersState.failed);
      expect((await SosNumbersSync.cachedContacts()).single['phone'], '01800000001');
      expect(await Settings.getString(SosNumbersSync.dirtyKey), '1');
    });

    test('sign-out clears the numbers (the next account never texts them)', () async {
      await SosNumbersSync.sync(_CardApi());
      await SosNumbersSync.clear();
      expect(await SosNumbersSync.cachedContacts(), isEmpty);
    });

    test('no token: nothing is fetched', () async {
      final api = _CardApi()..token = null;
      await SosNumbersSync.sync(api);
      expect(api.gets, 0);
    });
  });

  group('Emergency page', () {
    testWidgets('fresh phone, card never opened: SOS has the saved numbers', (t) async {
      final api = _CardApi();
      await SosNumbersSync.sync(api); // what sign-in does
      await t.pumpWidget(_app(_hub(), api));
      await _settle(t);
      expect(api.gets, 1); // the page itself fetched nothing more
      expect(_panelPhones(t), containsAll(['01700000011', '০১৭০০০০০০১২']));
      expect(find.byKey(const ValueKey('sos-numbers-unavailable')), findsNothing);
    });

    testWidgets('offline + nothing saved: honest line, 999 still there, retry works',
        (t) async {
      final api = _CardApi(offline: true);
      await SosNumbersSync.sync(api); // sign-in without internet
      await t.pumpWidget(_app(_hub(), api));
      await _settle(t);
      expect(api.gets, 2); // opening the page tried once more
      final t10n = AppLocalizations.of(t.element(find.byType(EmergencyHubScreen)));
      expect(find.byKey(const ValueKey('sos-numbers-unavailable')), findsOneWidget);
      expect(find.text(t10n.sosNumbersUnavailable), findsOneWidget);
      expect(find.textContaining('999'), findsWidgets);
      expect(_panelPhones(t), isEmpty);
      api.offline = false;
      await t.ensureVisible(find.byKey(const ValueKey('sos-numbers-retry')));
      await t.tap(find.byKey(const ValueKey('sos-numbers-retry')));
      await _settle(t);
      expect(find.byKey(const ValueKey('sos-numbers-unavailable')), findsNothing);
      // back to the top of the lazy list, where the SOS panel lives
      await t.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await _settle(t);
      expect(_panelPhones(t), contains('01700000011'));
    });

    testWidgets('app started offline, internet back: opening the page fetches them',
        (t) async {
      SosNumbersSync.noteOffline();
      final api = _CardApi();
      await t.pumpWidget(_app(_hub(), api));
      await _settle(t);
      expect(api.gets, 1);
      expect(_panelPhones(t), contains('01700000011'));
      expect(find.byKey(const ValueKey('sos-numbers-unavailable')), findsNothing);
    });

    testWidgets('offline but numbers already on the phone: no warning, numbers used',
        (t) async {
      await Settings.setString(SosNumbersSync.cacheKey,
          jsonEncode({'contacts': [{'name': 'Ammu', 'phone': '01700000011'}]}));
      final api = _CardApi(offline: true);
      await t.pumpWidget(_app(_hub(), api));
      await _settle(t);
      expect(api.gets, 0); // nothing to fetch: the phone copy is used at once
      expect(_panelPhones(t), ['01700000011']);
      expect(find.byKey(const ValueKey('sos-numbers-unavailable')), findsNothing);
    });

    testWidgets('bn, 200% font: the offline line fits, Bangla digits', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      final api = _CardApi(offline: true);
      await SosNumbersSync.sync(api);
      await t.pumpWidget(_app(_hub(), api, lang: 'bn', scale: 2));
      await _settle(t);
      final t10n = AppLocalizations.of(t.element(find.byType(EmergencyHubScreen)));
      expect(find.text(t10n.sosNumbersUnavailable), findsOneWidget);
      expect(RegExp(r'[0-9]').hasMatch(t10n.sosNumbersUnavailable), isFalse);
      expect(t.takeException(), isNull);
    });
  });
}
