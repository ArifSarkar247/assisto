// kidswatch (owner idea 2, 28 Oct) — Kids watch + School Mode screens:
//  1 the parent hub always shows the honest card (watch automatic, phone =
//    button, free safety, NO listening) and the safety-only state;
//  2 the only watch commands the app can send are locate / ring — never a
//    listen command;
//  3 adding a watch validates the code and then shows the SMS steps, which
//    never contain a listen command;
//  4 the child's screen shows who sees it, the big button sends the
//    location of that moment, "I'm OK" answers, stop is one tap + confirm;
//  5 200% text, Bangla, dark: no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/kids_watch/kids_watch_screen.dart';
import 'package:assisto/screens/kids_watch/school_mode_child_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_kidswatch.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.bn = false}) {
    token = 't';
  }

  final bool empty;
  final bool bn;
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      fakeKidsWatchGet(path, bn: bn, empty: empty) ?? <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    if (path == '/kids-watch/watches') {
      return {'ok': true, 'watch': {'id': 3, 'state': 'pending'}};
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> patchJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async => {'ok': true};
}

Widget _app(Widget child, ApiClient api,
    {String lang = 'en', bool dark = false, double scale = 1}) {
  final s = AppState();
  s.api = api;
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
      builder: scale == 1
          ? null
          : (ctx, w) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
              child: w!),
      home: child,
    ),
  );
}

bool _listenFree(_Fake f) => f.posts.every((p) =>
    !p.$1.toLowerCase().contains('monitor') &&
    !p.$2.values.any((v) => '$v'.toLowerCase().contains('monitor')));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('parent hub: honest card, safety-only watch, locate = the only command kind',
      (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(const KidsWatchScreen(), api));
    await t.pumpAndSettle();
    expect(find.text(l.kwNoListening), findsOneWidget);
    expect(find.text(l.kwHonestPhone), findsOneWidget);
    expect(find.text('Rina'), findsWidgets);
    expect(find.text(l.kwModeSafety), findsOneWidget);
    expect(find.text(l.kwModeFull), findsOneWidget);
    await t.ensureVisible(find.text(l.kwLocateNow).first);
    await t.tap(find.text(l.kwLocateNow).first);
    await t.pumpAndSettle();
    expect(api.posts.map((p) => p.$1), contains('/kids-watch/watches/1/command'));
    expect(api.posts.firstWhere((p) => p.$1.endsWith('/command')).$2['kind'], 'locate_now');
    await t.ensureVisible(find.text(l.kwRingWatch).first);
    await t.tap(find.text(l.kwRingWatch).first);
    await t.pumpAndSettle();
    expect(api.posts.last.$2['kind'], 'find_watch');
    expect(_listenFree(api), isTrue);
  });

  testWidgets('empty: benefit + add watch validates the code, then SMS steps (no listen)',
      (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake(empty: true);
    await t.pumpWidget(_app(const KidsWatchScreen(), api));
    await t.pumpAndSettle();
    expect(find.text(l.kwEmptyTitle), findsOneWidget);
    expect(find.text(l.kwNoListening), findsOneWidget);
    await t.tap(find.text(l.kwAddWatch).first);
    await t.pumpAndSettle();
    final fields = find.byType(TextField);
    await t.enterText(fields.at(0), 'Rina');
    await t.enterText(fields.at(1), '1234');
    await t.ensureVisible(find.text(l.kwPairNext));
    await t.tap(find.text(l.kwPairNext));
    await t.pumpAndSettle();
    expect(find.text(l.kwCodeInvalid), findsOneWidget);
    expect(api.posts, isEmpty);
    await t.enterText(fields.at(1), '8800000015');
    await t.ensureVisible(find.text(l.kwPairNext));
    await t.tap(find.text(l.kwPairNext));
    await t.pumpAndSettle();
    expect(api.posts.single.$1, '/kids-watch/watches');
    expect(api.posts.single.$2['code'], '8800000015');
    expect(find.text(l.kwSmsTitle), findsOneWidget);
    expect(find.textContaining('pw,123456,ip,'), findsOneWidget);
    expect(find.textContaining(RegExp('monitor', caseSensitive: false)), findsNothing);
  });

  testWidgets('child: who sees it, big button sends the moment location, I am OK, stop',
      (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(
        SchoolModeChildScreen(locate: () async => (lat: 23.79, lng: 90.43)), api));
    await t.pumpAndSettle();
    expect(find.text(l.kwChildOnSeenBy('Dad, Mum')), findsOneWidget);
    expect(find.text(l.kwChildWhatPhone), findsOneWidget);
    // on the way to school -> the big button is "Reached"
    await t.tap(find.byKey(const ValueKey('kw-big-button')));
    await t.pumpAndSettle();
    final c = api.posts.firstWhere((p) => p.$1.endsWith('/checkin'));
    expect(c.$1, '/school-mode/plans/6/checkin');
    expect(c.$2['kind'], 'arrived');
    expect(c.$2['lat'], 23.79);
    // "are you OK?" is pending -> I'm OK answers it
    await t.tap(find.text(l.kwImOk));
    await t.pumpAndSettle();
    expect(api.posts.where((p) => p.$1.endsWith('/checkin')).last.$2['kind'], 'ok');
    // location switch off -> nothing location-wise is sent
    await t.ensureVisible(find.text(l.kwShareLocationNow));
    await t.tap(find.text(l.kwShareLocationNow));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('kw-big-button')));
    await t.pumpAndSettle();
    expect(api.posts.where((p) => p.$1.endsWith('/checkin')).last.$2.containsKey('lat'), isFalse);
    // one-tap stop + confirm
    await t.ensureVisible(find.text(l.kwStop));
    await t.tap(find.text(l.kwStop));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, l.kwStop));
    await t.pumpAndSettle();
    expect(api.posts.last.$1, '/school-mode/plans/6/stop');
  });

  for (final dark in [false, true]) {
    testWidgets('200% Bangla ${dark ? 'dark' : 'light'}: hub + child screen, no overflow',
        (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const KidsWatchScreen(), _Fake(bn: true),
          lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(_app(
          SchoolModeChildScreen(locate: () async => null), _Fake(bn: true),
          lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
