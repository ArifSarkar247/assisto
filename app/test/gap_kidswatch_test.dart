// gap-kidswatch (17 Nov) — the kids-watch gaps a parent would hit:
//  1 the card says who the watch's SOS button calls — or, in red, that it
//    calls NOBODY (before: no word, and the app never asked);
//  2 "Call the watch" (a normal, visible call) when its SIM is saved;
//  3 a watch SOS in the last hour = red banner first: call + see where;
//  4 Watch settings: at least one SOS number, Bangla-keyboard digits become
//    0-9, the watch SIM, the child's own account — and it never listens;
//  5 pairing pre-fills the parent's own number as the first SOS number;
//  6 numbers typed with spaces ("01711 000001") stay one number;
//  7 200% Bangla, dark: SOS banner + settings, no overflow; Bangla digits.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/kids_watch_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/kids_watch/kids_watch_screen.dart';
import 'package:assisto/screens/kids_watch/kw_settings_sheet.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_kidswatch.dart';

class _Fake extends ApiClient {
  _Fake({this.bn = false, this.sos = false}) {
    token = 't';
  }

  final bool bn;
  final bool sos;
  final List<(String, Map<String, dynamic>)> posts = [];
  final List<(String, Map<String, dynamic>)> patches = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      fakeKidsWatchGet(path, bn: bn, empty: false, sos: sos) ?? <String, dynamic>{};

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
      [Map<String, dynamic> body = const {}]) async {
    patches.add((path, Map.of(body)));
    return {'ok': true};
  }
}

Widget _app(Widget child, ApiClient api,
    {String lang = 'en', bool dark = false, double scale = 1, String? phone}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  if (phone != null) {
    s.user = AppUser(id: 1, name: 'Abba', phone: phone, autonomyLevel: 1, language: lang);
  }
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

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 6000);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

Map<String, dynamic> _watch(int i) => ((fakeKidsWatchGet('/kids-watch/watches',
        bn: false, empty: false)!['watches'] as List)[i] as Map)
    .cast<String, dynamic>();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('numbers: Bangla digits -> 0-9, spaces stay inside one number, max 3', () {
    expect(kwLatinDigits('০১৭১১-০০০০০৯'), '01711000009');
    expect(kwSplitNumbers('01711 000001, ০১৮১১০০০০০২;01911000003\n01511000004'),
        ['01711000001', '01811000002', '01911000003']);
    expect(kwPhoneOk('01711000001'), isTrue);
    expect(kwPhoneOk('+8801711000001'), isTrue);
    expect(kwPhoneOk('12'), isFalse);
  });

  testWidgets('card: who SOS calls, SOS-calls-nobody warning, Call the watch only with a SIM',
      (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const KidsWatchScreen(), _Fake()));
    await t.pumpAndSettle();
    expect(find.text(l.kwgSosCalls('01711000001')), findsOneWidget);
    expect(find.byKey(const ValueKey('kwg-sosnone-2')), findsOneWidget);
    expect(find.text(l.kwgSosNone), findsOneWidget);
    expect(find.byKey(const ValueKey('kwg-call-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('kwg-call-2')), findsNothing);
    expect(find.byKey(const ValueKey('kwg-sos-1')), findsNothing); // no SOS now
    expect(find.byKey(const ValueKey('kwg-settings-1')), findsOneWidget);
  });

  testWidgets('watch SOS in the last hour: red banner with Call the watch + See where',
      (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const KidsWatchScreen(), _Fake(sos: true)));
    await t.pumpAndSettle();
    final banner = find.byKey(const ValueKey('kwg-sos-1'));
    expect(banner, findsOneWidget);
    expect(find.descendant(of: banner, matching: find.text(l.kwgCallWatch)), findsOneWidget);
    expect(find.descendant(of: banner, matching: find.text(l.kwgSeeWhere)), findsOneWidget);
    expect(find.descendant(of: banner, matching: find.text(l.kwgSosNowBody)), findsOneWidget);
    // the banner comes before the everyday buttons
    expect(t.getTopLeft(banner).dy,
        lessThan(t.getTopLeft(find.text(l.kwLocateNow).first).dy));
  });

  testWidgets('settings: needs one SOS number, Bangla digits saved as 0-9, SIM + child; never listens',
      (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(Scaffold(body: KwWatchSettingsSheet(watch: _watch(1))), api));
    await t.pumpAndSettle();
    expect(find.text(l.kwgNoListen), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('kwg-set-save')));
    await t.pumpAndSettle();
    expect(find.text(l.kwgSosNeedOne), findsOneWidget);
    expect(api.patches, isEmpty);
    await t.enterText(find.byKey(const ValueKey('kwg-set-sos')), '12');
    await t.tap(find.byKey(const ValueKey('kwg-set-save')));
    await t.pumpAndSettle();
    expect(find.text(l.kwgBadPhone), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('kwg-set-sos')), '০১৭১১০০০০০৯, 01811 000002');
    await t.enterText(find.byKey(const ValueKey('kwg-set-sim')), '০১৯১১০০০০০৮');
    await t.tap(find.byKey(const ValueKey('kwg-set-child')));
    await t.pumpAndSettle();
    await t.tap(find.text('Rafi').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('kwg-set-save')));
    await t.pumpAndSettle();
    final p = api.patches.single;
    expect(p.$1, '/kids-watch/watches/2');
    expect(p.$2['sos_numbers'], ['01711000009', '01811000002']);
    expect(p.$2['sim_phone'], '01911000008');
    expect(p.$2['child_user_id'], 3);
    expect('${p.$2}'.toLowerCase().contains('monitor'), isFalse);
  });

  testWidgets('pairing pre-fills the parent\'s own number as the first SOS number',
      (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(const KidsWatchScreen(), api, phone: '01711000001'));
    await t.pumpAndSettle();
    await t.tap(find.text(l.kwAdd));            // the + button -> add menu
    await t.pumpAndSettle();
    await t.tap(find.text(l.kwAddWatch).last);
    await t.pumpAndSettle();
    final sos = t.widget<TextField>(find.byKey(const ValueKey('kwg-pair-sos')));
    expect(sos.controller!.text, '01711000001');
    expect(find.text(l.kwgSosHelpDefault), findsOneWidget);
    expect(find.byKey(const ValueKey('kwg-pair-sim')), findsOneWidget);
  });

  testWidgets('Bangla: the SOS line shows Bangla digits', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('bn'));
    await t.pumpWidget(_app(const KidsWatchScreen(), _Fake(bn: true), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.text(l.kwgSosCalls('০১৭১১০০০০০১')), findsOneWidget);
    expect(find.text(l.kwgSosNone), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('200% Bangla ${dark ? 'dark' : 'light'}: SOS banner + settings, no overflow',
        (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const KidsWatchScreen(), _Fake(bn: true, sos: true),
          lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(_app(Scaffold(body: KwWatchSettingsSheet(watch: _watch(1))),
          _Fake(bn: true), lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
