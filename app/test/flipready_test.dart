// flipready (owner 2 Nov — launch ALL features 8 Nov): the 11 flags the owner
// still has OFF must be safe to switch ON. For each flag, with ONLY that flag
// turned on (the way a flip reaches a phone):
//  1 every ChatNav route it owns opens (chat, push, deep link, sidebar);
//  2 its menu entry appears (accounting_v2 lives in the Business hub, fall
//    detection under Safety);
//  3 with the flag OFF the same routes are absent and a stale push opens the
//    friendly "not available" page — never a blank screen;
//  4 each gated screen builds on a 360 dp Bangla phone at 200% text with NO
//    server data (a fresh user / server trouble): no layout error, a real
//    screen (Scaffold + text), never blank.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/feature_unavailable.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

const kFlipFlags = [
  'blood_donors',
  'train_tracker',
  'dest_alarm',
  'missing_alert',
  'retention_auto',
  'accounting_v2',
  'child_emergency_audio',
  'kids_watch',
  'agent_core',
  'fall_detect',
  'pa_secretary',
];

final ff = FeatureFlags.instance;

void _only(String? on) {
  ff.debugOverride = {for (final k in kFlipFlags) k: k == on};
}

List<String> _routesOf(String flag) =>
    [for (final e in kRouteFeature.entries) if (e.value == flag) e.key];

Set<String> _sidebarFeatures() => {
      for (final s in SidebarSections.allModes)
        for (final i in s.items)
          if (i.feature != null && i.visible) i.feature!,
    };

bool _benign(Object e) =>
    e is MissingPluginException ||
    e is PlatformException ||
    e.toString().contains('HttpException') ||
    e.toString().contains('SocketException') ||
    e.toString().contains('ApiException');

Future<void> _pumpRoute(WidgetTester t, WidgetBuilder b) async {
  final app = AppState()
    ..api = ApiClient(token: 't')
    ..user = AppUser(
        id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'bn')
    ..locale = const Locale('bn')
    ..loading = false;
  await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('bn'),
      theme: AssistoTheme.light,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (ctx, w) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: const TextScaler.linear(2)),
          child: w!),
      home: Builder(builder: b),
    ),
  ));
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    Settings.resetForTest();
    ff.resetForTest();
  });
  tearDown(() => ff.resetForTest());

  test('every flip flag is a known registry key that starts hidden or is owner-off', () {
    for (final k in kFlipFlags) {
      expect(kFeatureDefaults.containsKey(k), isTrue, reason: k);
    }
  });

  for (final flag in kFlipFlags) {
    test('$flag ON: its routes open and its menu entry shows; OFF: friendly not-available',
        () {
      final routes = _routesOf(flag);
      _only(flag);
      for (final r in routes) {
        expect(ChatNav.routes.containsKey(r), isTrue, reason: '$flag ON: route $r missing');
        expect(ChatNav.builderFor(r), isNotNull, reason: r);
      }
      if (flag != 'accounting_v2') {
        // accounting_v2 is reached from the Business hub (isOn check there)
        expect(_sidebarFeatures(), contains(flag), reason: '$flag ON: no menu entry');
      }
      _only(null);
      for (final r in routes) {
        expect(ChatNav.routes.containsKey(r), isFalse, reason: '$flag OFF: route $r still open');
        final b = ChatNav.builderFor(r);
        expect(b, isNotNull, reason: '$flag OFF: stale push to $r opens nothing');
      }
      expect(_sidebarFeatures().contains(flag), isFalse, reason: '$flag OFF: menu entry shown');
    });
  }

  testWidgets('a stale push to a hidden route opens the not-available page', (t) async {
    _only(null);
    final b = ChatNav.builderFor('blood_panel')!;
    await _pumpRoute(t, b);
    expect(find.byType(FeatureUnavailableScreen), findsOneWidget);
  });

  for (final flag in kFlipFlags) {
    testWidgets('$flag ON: every gated screen (routes + menu) at 360 dp, Bangla 200%, no server data → real screen, no layout error',
        (t) async {
      t.view.physicalSize = const Size(360 * 3, 760 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      _only(flag);
      final screens = <String, WidgetBuilder>{
        for (final r in _routesOf(flag)) 'route $r': ChatNav.routes[r]!,
        for (final s in SidebarSections.allModes)
          for (final i in s.items)
            if (i.feature == flag) 'menu ${s.id}/${s.items.indexOf(i)}': i.builder,
      };
      expect(screens, isNotEmpty, reason: '$flag: nothing to open when ON');
      final errors = <String>[];
      for (final e in screens.entries) {
        final caught = <FlutterErrorDetails>[];
        final orig = FlutterError.onError;
        FlutterError.onError = (d) {
          if (!_benign(d.exception)) caught.add(d);
        };
        try {
          await _pumpRoute(t, e.value);
          if (find.byType(Scaffold).evaluate().isEmpty) errors.add('${e.key}: no screen');
          if (find.byType(Text).evaluate().isEmpty) errors.add('${e.key}: blank screen');
          if (find.byType(FeatureUnavailableScreen).evaluate().isNotEmpty) {
            errors.add('${e.key}: not-available while ON');
          }
        } finally {
          await t.pumpWidget(const SizedBox());
          await t.pump(const Duration(seconds: 1));
          FlutterError.onError = orig;
        }
        final x = t.takeException();
        if (x != null && !_benign(x)) caught.add(FlutterErrorDetails(exception: x));
        for (final d in caught) {
          errors.add('${e.key}: ${d.exceptionAsString().split('\n').first}');
        }
      }
      if (errors.isNotEmpty) fail('$flag: ${errors.join(' | ')}');
    });
  }
}
