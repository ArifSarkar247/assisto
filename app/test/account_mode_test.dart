// acctmode (owner 2 Nov, PART 1 e): accounts mode personal / business / both.
//
// Every direction of switching with entries present: the menu follows the
// mode, search still finds every module, the only server call is the
// preference itself (no entry is ever deleted / moved), switching back shows
// everything again, offline choices sync later, and existing users who never
// chose see the full menu.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/account_mode.dart';
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/onboarding_screen.dart' show onboardingSteps, OnbStep;
import 'package:assisto/state.dart';
import 'package:assisto/widgets/account_mode_ui.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

final ctl = AccountModeController.instance;
final ff = FeatureFlags.instance;

/// A fake server holding the preference AND both books. Records every call,
/// so a test can prove a switch touched nothing but /account-mode.
class _Server extends ApiClient {
  _Server({this.chosen, this.offline = false}) {
    token = 't';
  }
  String? chosen; // null = never chose
  bool offline;
  final calls = <String>[];
  final posts = <Map<String, dynamic>>[];
  // Entries in both books (never changed by any account-mode call).
  final personalEntries = <int>[1, 2, 3, 4];
  final customers = <String>['Rahim', 'Karim', 'Salma'];

  Map<String, dynamic> _payload() {
    final mode = chosen ?? 'both';
    final usage = {
      'personal': {'used': personalEntries.isNotEmpty, 'entries': personalEntries.length},
      'business': {'used': customers.isNotEmpty, 'parties': customers.length, 'products': 2},
    };
    return {
      'mode': mode,
      'chosen': chosen != null,
      'suggested': 'both',
      'usage': usage,
      'modes': ['personal', 'business', 'both'],
    };
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add('GET $path');
    if (offline) throw ApiException('offline', 0);
    if (path == '/account-mode') return _payload();
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add('POST $path');
    if (offline) throw ApiException('offline', 0);
    if (path == '/account-mode') {
      posts.add(Map<String, dynamic>.from(body));
      chosen = body['mode'] as String;
      return _payload();
    }
    return {};
  }
}

const _personalScreens = ['money', 'budget', 'money_wrapped', 'money_voice',
  'subscriptions', 'savings_challenge', 'spending_advice'];
const _businessScreens = ['business', 'crm', 'booking_bot', 'retention_auto'];

Set<AcctArea?> _menuAreas() => {
      for (final s in SidebarSections.all)
        for (final i in s.items) i.area,
    };

bool _menuHas(AcctArea a) => _menuAreas().contains(a);

AppLocalizations get _en => lookupAppLocalizations(const Locale('en'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    ff.resetForTest();
    ff.debugOverride = {
      for (final k in [..._personalScreens, ..._businessScreens]) k: true,
    };
    ctl.resetForTest();
  });
  tearDown(() {
    ff.resetForTest();
    ctl.resetForTest();
  });

  group('pure rules', () {
    test('shows', () {
      for (final a in AcctArea.values) {
        expect(accountModeShows(AccountMode.both, a), isTrue);
      }
      expect(accountModeShows(AccountMode.personal, AcctArea.personal), isTrue);
      expect(accountModeShows(AccountMode.personal, AcctArea.business), isFalse);
      expect(accountModeShows(AccountMode.business, AcctArea.business), isTrue);
      expect(accountModeShows(AccountMode.business, AcctArea.personal), isFalse);
      expect(accountModeFromCode('shop'), isNull);
    });
    test('hidden areas that still hold entries', () {
      final usage = {
        'personal': {'used': true},
        'business': {'used': true},
      };
      expect(accountModeHiddenWithData(AccountMode.personal, usage),
          [AcctArea.business]);
      expect(accountModeHiddenWithData(AccountMode.business, usage),
          [AcctArea.personal]);
      expect(accountModeHiddenWithData(AccountMode.both, usage), isEmpty);
      expect(
          accountModeHiddenWithData(AccountMode.personal,
              {'personal': {'used': true}, 'business': {'used': false}}),
          isEmpty);
    });
  });

  group('migration of existing users', () {
    test('never chose -> both: the full menu, exactly as before', () async {
      final api = _Server();
      await ctl.refresh(api);
      expect(ctl.mode, AccountMode.both);
      expect(ctl.chosen, isFalse);
      expect(_menuHas(AcctArea.personal), isTrue);
      expect(_menuHas(AcctArea.business), isTrue);
    });
    test('a choice saved on another phone comes down from the server', () async {
      final api = _Server(chosen: 'business');
      await ctl.refresh(api);
      expect(ctl.mode, AccountMode.business);
      expect(_menuHas(AcctArea.personal), isFalse);
    });
    test('no cache, no network -> both (nothing hidden)', () async {
      await ctl.refresh(_Server(offline: true));
      expect(ctl.mode, AccountMode.both);
      expect(_menuHas(AcctArea.business), isTrue);
    });
  });

  group('switching in every direction with entries present', () {
    for (final from in AccountMode.values) {
      for (final to in AccountMode.values) {
        if (from == to) continue;
        test('${from.name} -> ${to.name}', () async {
          final api = _Server();
          final entriesBefore = [...api.personalEntries];
          final customersBefore = [...api.customers];
          expect(await ctl.set(from, api: api), isTrue);
          expect(await ctl.set(to, api: api), isTrue);

          // menu follows the mode
          expect(_menuHas(AcctArea.personal), to != AccountMode.business);
          expect(_menuHas(AcctArea.business), to != AccountMode.personal);
          // non-finance modules are never touched by the mode
          expect(_menuAreas(), contains(null));

          // search still finds BOTH areas in every mode (no closed door)
          final money = SidebarSections.filter(_en, 'expense')
              .expand((s) => s.items)
              .any((i) => i.area == AcctArea.personal);
          final shop = SidebarSections.filter(_en, 'shop')
              .expand((s) => s.items)
              .any((i) => i.area == AcctArea.business);
          expect(money, isTrue);
          expect(shop, isTrue);

          // nothing but the preference was sent; no entry changed
          expect(api.calls.every((c) => c.endsWith('/account-mode')), isTrue,
              reason: api.calls.join(', '));
          expect(api.posts.map((p) => p['mode']), [from.name, to.name]);
          expect(api.personalEntries, entriesBefore);
          expect(api.customers, customersBefore);
          expect(ctl.personalEntries, 4);
          expect(ctl.businessParties, 3);
        });
      }
    }

    test('round trip personal -> business -> both shows everything again',
        () async {
      final api = _Server();
      final full = SidebarSections.all.expand((s) => s.items).length;
      await ctl.set(AccountMode.personal, api: api);
      await ctl.set(AccountMode.business, api: api);
      await ctl.set(AccountMode.both, api: api);
      expect(SidebarSections.all.expand((s) => s.items).length, full);
    });
  });

  group('offline + persistence', () {
    test('offline choice applies at once, then syncs on the next refresh',
        () async {
      final api = _Server(offline: true);
      expect(await ctl.set(AccountMode.business, api: api), isFalse);
      expect(ctl.mode, AccountMode.business);
      expect(ctl.pendingSync, isTrue);
      expect(_menuHas(AcctArea.personal), isFalse);

      api.offline = false;
      await ctl.refresh(api);
      expect(api.posts.last['mode'], 'business');
      expect(api.posts.last['source'], 'resync');
      expect(ctl.pendingSync, isFalse);
      expect(ctl.mode, AccountMode.business);
    });

    test('cached choice survives an app restart (before the network answers)',
        () async {
      await ctl.set(AccountMode.personal, api: _Server());
      ctl.resetForTest(); // "restart": memory gone, prefs kept
      await ctl.refresh(_Server(offline: true));
      expect(ctl.mode, AccountMode.personal);
    });
  });

  group('onboarding', () {
    test('the accounts step sits right after "who are you"', () {
      final steps = onboardingSteps();
      expect(steps.indexOf(OnbStep.acctMode),
          steps.indexOf(OnbStep.role) + 1);
    });
    test('no accounts step while business is off (no dead choice)', () {
      ff.debugOverride = {...?ff.debugOverride, 'business': false};
      expect(onboardingSteps(), isNot(contains(OnbStep.acctMode)));
    });
    testWidgets('three choices, tap picks', (tester) async {
      AccountMode? picked;
      await _pump(tester, _Server(),
          Scaffold(body: OnbAccountModeStep(
              selected: AccountMode.personal, onPick: (m) => picked = m)));
      expect(find.text(_en.acmPersonal), findsOneWidget);
      expect(find.text(_en.acmBusiness), findsOneWidget);
      expect(find.text(_en.acmBoth), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('acm-both')));
      expect(picked, AccountMode.both);
    });
  });

  group('Settings sheet', () {
    testWidgets('warns which entries are kept, saves, entries unchanged',
        (tester) async {
      final api = _Server();
      await _pump(tester, api,
          Scaffold(body: Builder(builder: (c) => Center(
              child: TextButton(
                  onPressed: () => showAccountModeSheet(c),
                  child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('acm-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('acm-warn')), findsNothing); // both

      await tester.tap(find.byKey(const ValueKey('acm-personal')));
      await tester.pump();
      expect(find.byKey(const ValueKey('acm-warn')), findsOneWidget);
      expect(find.textContaining('3 customers/suppliers, 2 products'),
          findsWidgets);

      await tester.ensureVisible(find.byKey(const ValueKey('acm-save')));
      await tester.tap(find.byKey(const ValueKey('acm-save')));
      await tester.pumpAndSettle();
      expect(find.text(_en.acmSaved), findsOneWidget);
      expect(ctl.mode, AccountMode.personal);
      expect(api.customers.length, 3);
      expect(api.calls.every((c) => c.endsWith('/account-mode')), isTrue);
    });

    testWidgets('Settings row shows the mode and opens the sheet',
        (tester) async {
      final api = _Server(chosen: 'business');
      await _pump(tester, api, const Scaffold(body: AccountModeSettingsTile()));
      await tester.pumpAndSettle();
      expect(find.textContaining(_en.acmBusiness), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-acct-mode')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('acm-sheet')), findsOneWidget);
    });

    testWidgets('200% font: sheet scrolls, nothing overflows', (tester) async {
      final api = _Server();
      await _pump(tester, api,
          Scaffold(body: Builder(builder: (c) => Center(
              child: TextButton(
                  onPressed: () => showAccountModeSheet(c),
                  child: const Text('open'))))),
          scale: 2.0);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('acm-business')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('acm-save')));
      expect(tester.takeException(), isNull);
    });
  });

  group('hidden-area card (reached by search / chat)', () {
    testWidgets('Personal only: business screen card -> Show in menu again',
        (tester) async {
      final api = _Server(chosen: 'personal');
      await ctl.refresh(api);
      await _pump(tester, api,
          const Scaffold(body: AccountModeHiddenCard(area: AcctArea.business)));
      expect(find.text(_en.acmHiddenBusiness), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('acm-show-again')));
      await tester.pumpAndSettle();
      expect(ctl.mode, AccountMode.both);
      expect(find.text(_en.acmHiddenBusiness), findsNothing);
      expect(_menuHas(AcctArea.business), isTrue);
    });

    testWidgets('no card when the area is shown', (tester) async {
      final api = _Server(chosen: 'business');
      await ctl.refresh(api);
      await _pump(tester, api,
          const Scaffold(body: AccountModeHiddenCard(area: AcctArea.business)));
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('Bangla: strict language + Bangla digits in the warning',
        (tester) async {
      final api = _Server();
      await ctl.refresh(api);
      await _pump(tester, api,
          Scaffold(body: Builder(builder: (c) => Center(
              child: TextButton(
                  onPressed: () => showAccountModeSheet(c),
                  child: const Text('open'))))),
          locale: const Locale('bn'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('acm-personal')));
      await tester.pump();
      final warn = tester.widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('acm-warn')), matching: find.byType(Text)));
      expect(warn.data, isNot(matches(RegExp('[0-9A-Za-z]'))));
      expect(warn.data, contains('৩')); // Bangla 3
    });
  });
}

Future<void> _pump(WidgetTester tester, ApiClient api, Widget home,
    {double scale = 1.0, Locale locale = const Locale('en')}) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final app = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en')
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    ),
  ));
  await tester.pump();
}
