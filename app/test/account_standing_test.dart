// adminsafe (owner 3 Nov): Account status + appeal on the server's real
// shapes (backend core/admin_safety.standing(), core/views_safety.py):
// blocked sign-in body (no session), signed-in restricted / good standing,
// appeal min length + the right endpoint, Bangla digits, 200 % font + dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/app_localizations_en.dart';
import 'package:assisto/screens/account_standing_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_standing.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false}) {
    token = 't';
  }
  final bool empty;
  final List<String> gets = [];
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    return empty ? fakeStandingEmpty() : fakeStandingRestricted();
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    if (path.endsWith('/standing/blocked')) {
      return {...fakeBlockedBody()['standing'] as Map<String, dynamic>, '_status': 200};
    }
    final st = Map<String, dynamic>.from(fakeBlockedBody()['standing'] as Map);
    st['notices'] = [
      {...(st['notices'] as List).first as Map<String, dynamic>,
        'appealable': false,
        'appeal': {'state': 'open', 'created_at': '2026-11-03T08:00:00+00:00', 'decision_note': ''}},
    ];
    return {'ok': true, 'id': 1, 'state': 'open', 'standing': st, '_status': 201};
  }
}

Widget _app(ApiClient api, Widget home,
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
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: home,
    ),
  );
}

final _en = AppLocalizationsEn();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  void tall(WidgetTester t, {double w = 1080}) {
    t.view.physicalSize = Size(w, 6000);
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
  }

  testWidgets('blocked sign-in body: status, end date, reason and Appeal — no API call',
      (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, AccountStandingScreen(blockedBody: fakeBlockedBody())));
    await t.pumpAndSettle();
    expect(find.textContaining('Paused until'), findsOneWidget);
    expect(find.text(_en.astdReason('Scam attempts — several reports')), findsOneWidget);
    expect(find.text(_en.astdBlockedNote), findsOneWidget);
    expect(find.text(_en.astdAppealBtn), findsOneWidget);
    expect(api.gets, isEmpty);
  });

  testWidgets('appeal: under 10 characters is refused in place; then sent with the token',
      (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, AccountStandingScreen(blockedBody: fakeBlockedBody())));
    await t.pumpAndSettle();
    await t.tap(find.text(_en.astdAppealBtn));
    await t.pumpAndSettle();
    expect(find.text(_en.astdAppealTitle), findsOneWidget);
    await t.enterText(find.byType(TextField), 'short');
    await t.tap(find.text(_en.astdAppealSend));
    await t.pumpAndSettle();
    expect(find.text(_en.astdAppealTooShort), findsOneWidget);
    expect(api.posts, isEmpty);

    await t.enterText(find.byType(TextField), 'I never sent those messages, my phone was stolen.');
    await t.tap(find.text(_en.astdAppealSend));
    await t.pumpAndSettle();
    expect(api.posts.single.$1, '/account/appeal/blocked');
    expect(api.posts.single.$2['appeal_token'], 'tok123');
    expect(api.posts.single.$2['action_id'], 9);
    expect(find.text(_en.astdAppealSent), findsOneWidget);
    // the answer's standing replaces the button with the open-appeal state
    expect(find.text(_en.astdAppealOpen), findsOneWidget);
    expect(find.text(_en.astdAppealBtn), findsNothing);
  });

  testWidgets('signed in, nothing limited: good-standing benefit line, no buttons', (t) async {
    tall(t);
    final api = _Fake(empty: true);
    await t.pumpWidget(_app(api, const AccountStandingScreen()));
    await t.pumpAndSettle();
    expect(api.gets, ['/account/standing']);
    expect(find.text(_en.astdGoodTitle), findsOneWidget);
    expect(find.text(_en.astdGoodBody), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('signed in, restricted: limit with reason + end, open appeal, Appeal on the warning',
      (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AccountStandingScreen()));
    await t.pumpAndSettle();
    expect(find.text(_en.astdLimitedTitle), findsOneWidget);
    expect(find.text(_en.astdLimitsHead), findsOneWidget);
    expect(find.text(_en.astdLimitStrangerMsg), findsOneWidget);
    expect(find.text(_en.astdAppealOpen), findsOneWidget);
    expect(find.text(_en.astdAppealBtn), findsOneWidget); // only the warning
    await t.tap(find.text(_en.astdAppealBtn));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'That advert was posted once by a friend.');
    await t.tap(find.text(_en.astdAppealSend));
    await t.pumpAndSettle();
    expect(api.posts.single.$1, '/account/appeal');
    expect(api.posts.single.$2['action_id'], 5);
  });

  testWidgets('Bangla: dates in Bangla digits', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(),
        AccountStandingScreen(blockedBody: fakeBlockedBody(bn: true)), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.textContaining('১০/১১/২০২৬'), findsWidgets);
    expect(find.textContaining('10/11/2026'), findsNothing);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('$lang 200 % font + dark at 360 dp: no overflow', (t) async {
      tall(t, w: 900); // 360 dp
      await t.pumpWidget(_app(_Fake(), const AccountStandingScreen(),
          lang: lang, dark: true, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(_app(_Fake(),
          AccountStandingScreen(blockedBody: fakeBlockedBody(bn: lang == 'bn', banned: true)),
          lang: lang, dark: true, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
