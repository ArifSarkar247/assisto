// feature-flags — one server switch per feature (owner rule 26 Oct). A hidden
// feature has no entry anywhere (drawer, search, ChatNav routes, quick-button
// picker, My Circle link, business-hub agent card), a stale link / push to it
// shows the friendly "not available" notice, offline keeps the last known set,
// a first run with no network uses today's defaults, and the owner / testers
// (server "preview") see hidden features.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/app_drawer.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/feature_unavailable.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

final ff = FeatureFlags.instance;

Map<String, dynamic> _answer(Map<String, bool> off, {List<String> preview = const []}) => {
      'v': 1,
      'flavour': 'play',
      'features': {
        for (final k in kFeatureDefaults.keys)
          k: preview.contains(k) || (off.containsKey(k) ? off[k]! : kFeatureDefaults[k]!),
      },
      'preview': preview,
    };

FeaturesFetch _serve(Map<String, dynamic> body, {String etag = '"e1"'}) =>
    (String? sent) async => sent == etag
        ? (status: 304, body: null, etag: etag)
        : (status: 200, body: body, etag: etag);

Future<({int status, Map<String, dynamic>? body, String? etag})> _offline(
        String? _) =>
    Future.error(Exception('offline'));

Set<String> _sidebarFeatures() => {
      for (final s in SidebarSections.all)
        for (final i in s.items)
          if (i.feature != null) i.feature!,
    };

Future<AppLocalizations> _pump(WidgetTester tester, Widget home) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final app = AppState()
    ..api = ApiClient(token: 't')
    ..user = AppUser(
        id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en')
    ..loading = false;
  late AppLocalizations t;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (ctx) {
        t = AppLocalizations.of(ctx);
        return home;
      }),
    ),
  ));
  await tester.pump();
  return t;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    ff.resetForTest();
  });
  tearDown(() => ff.resetForTest());

  test('first run, no network: registry defaults = today (nothing visible disappears)',
      () async {
    await ff.load();
    expect(await ff.refresh(_offline), isFalse);
    for (final e in kFeatureDefaults.entries) {
      // truth: a feature without its data source stays hidden until the
      // server answers (backend feature_flags.SOURCE_REQUIRED).
      final want = kFeatureNeedsSource.contains(e.key) ? false : e.value;
      expect(ff.isOn(e.key), want, reason: e.key);
    }
    expect(ff.isOn('dictionary'), isFalse);
    expect(ff.isOn('ai_inbox'), isFalse);
    expect(ff.isOn(null), isTrue); // core entries
    expect(ff.isOn('typo_key'), isTrue); // a typo never hides a feature
    expect(ChatNav.routes.containsKey('crm'), isTrue);
    expect(ChatNav.routes.containsKey('shop_box'), isTrue);
    expect(_sidebarFeatures(), containsAll(['crm', 'cctv_watchman', 'anti_theft']));
    // code-gated today -> hidden by default too
    expect(ff.isOn('agent_studio'), isFalse);
    expect(ff.isOn('remote_support'), isFalse);
  });

  test('every ChatNav route mapped to a flag exists, every sidebar flag is known',
      () {
    for (final r in kRouteFeature.keys) {
      expect(ChatNav.builderFor(r) != null || r == 'agent_studio' || r == 'fall_detect',
          isTrue, reason: r);
    }
    for (final s in SidebarSections.all) {
      for (final i in s.items) {
        if (i.feature != null) {
          expect(kFeatureDefaults.containsKey(i.feature), isTrue, reason: i.feature);
        }
      }
    }
  });

  test('hidden feature: no drawer entry, no search hit, no route, no quick button',
      () async {
    await ff.refresh(_serve(_answer({'crm': false, 'cctv_watchman': false})));
    expect(ff.isOn('crm'), isFalse);
    expect(_sidebarFeatures().contains('crm'), isFalse);
    expect(_sidebarFeatures().contains('cctv_watchman'), isFalse);
    expect(_sidebarFeatures().contains('business'), isTrue);
    expect(ChatNav.routes.containsKey('crm'), isFalse);
    expect(ChatNav.routes.containsKey('shop_box'), isFalse);
    expect(ChatNav.routes.containsKey('business'), isTrue);
    expect(HomeQuickButtons.catalog.map((s) => s.route), isNot(contains('crm')));
    expect(HomeQuickButtons.sanitize(['crm', 'shop_box', 'money']),
        isNot(anyOf(contains('crm'), contains('shop_box'))));
    expect(ChatNav.detectRoute('open crm'), 'crm'); // -> push shows the notice
  });

  test('offline keeps the last known set; it survives a restart (prefs)', () async {
    await ff.refresh(_serve(_answer({'crm': false})));
    expect(ff.isOn('crm'), isFalse);
    expect(await ff.refresh(_offline, force: true), isFalse);
    expect(ff.isOn('crm'), isFalse);
    await Future<void>.delayed(Duration.zero);
    ff.resetForTest(); // "restart"
    expect(ff.isOn('crm'), isTrue);
    await ff.load();
    expect(ff.isOn('crm'), isFalse);
  });

  test('304 keeps the cached set; throttled unless forced', () async {
    await ff.refresh(_serve(_answer({'crm': false})));
    var calls = 0;
    Future<({int status, Map<String, dynamic>? body, String? etag})> f(
        String? etag) async {
      calls++;
      expect(etag, '"e1"');
      return (status: 304, body: null, etag: etag);
    }

    expect(await ff.refresh(f), isFalse);
    expect(calls, 0); // within the 60 s gap
    expect(await ff.refresh(f, force: true), isFalse);
    expect(calls, 1);
    expect(ff.isOn('crm'), isFalse);
  });

  test('owner / tester preview sees a hidden feature; sign-out drops it', () async {
    await ff.refresh(_serve(_answer({'remote_support': false, 'crm': false},
        preview: ['crm'])));
    expect(ff.isOn('crm'), isTrue);
    expect(ff.isPreview('crm'), isTrue);
    expect(ChatNav.routes.containsKey('crm'), isTrue);
    ff.forgetUser();
    expect(ff.isOn('crm'), isFalse);
    expect(ff.isPreview('crm'), isFalse);
  });

  testWidgets('route / deep link to a hidden feature: friendly notice, no crash',
      (tester) async {
    ff.debugOverride = {'crm': false};
    late BuildContext ctx;
    final t = await _pump(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    expect(ChatNav.push(ctx, 'crm'), isTrue);
    await tester.pump();
    expect(find.byKey(const ValueKey('feature_unavailable_snack')), findsOneWidget);
    expect(find.text(t.ffUnavailableBody), findsOneWidget);
    // an unknown route is still "not handled"
    expect(ChatNav.push(ctx, 'no_such_route'), isFalse);
    // push / notification deep link -> the full page, one tap back
    final b = ChatNav.builderFor('crm')!;
    Navigator.of(ctx).push(MaterialPageRoute<void>(builder: b));
    await tester.pumpAndSettle();
    expect(find.byType(FeatureUnavailableScreen), findsOneWidget);
    expect(find.text(t.ffUnavailableTitle), findsOneWidget);
    await tester.tap(find.text(t.ffUnavailableBack));
    await tester.pumpAndSettle();
    expect(find.byType(FeatureUnavailableScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('drawer: hidden My Circle / CRM have no entry', (tester) async {
    ff.debugOverride = {'my_circle': false, 'crm': false};
    final key = GlobalKey<ScaffoldState>();
    final t = await _pump(
        tester, Scaffold(key: key, drawer: const AppDrawer(), body: const SizedBox()));
    key.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tl_drawer_my_circle')), findsNothing);
    expect(find.text(t.sidebarMyCircle), findsNothing);
    final search = find.descendant(
        of: find.byType(Drawer), matching: find.byType(TextField));
    await tester.enterText(search, 'crm');
    await tester.pumpAndSettle();
    expect(find.text(t.crmTitle), findsNothing);
    await tester.enterText(search, 'circle');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drawer_search_my_circle')), findsNothing);
    ff.debugOverride = null;
    await tester.enterText(search, 'crm');
    await tester.pumpAndSettle();
    expect(find.text(t.crmTitle), findsWidgets);
  });
}
