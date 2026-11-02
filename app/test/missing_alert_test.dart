// missing (owner 2 Nov) — Missing person alert screens:
//  1 hub: near + mine, honest "who gets it" card, opt-in entry; empty state
//    with one primary action;
//  2 the missing person: "I am safe" sends NO location;
//  3 a nearby user: GD "not verified" line, private tip (anonymous unless
//    chosen, location only if switched on), 999 = own dialer;
//  4 the family: Found -> (only if they agree) the reusable success-share;
//  5 post form: adult needs a GD (format checked before any call), child
//    shows the guardian card; no address / phone text leaves the phone;
//  6 success share: copy, no-reward line, Play review only after a share,
//    at most once per 120 days;
//  7 Bangla 200% text, light + dark: no overflow.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/missing_alert_api.dart';
import 'package:assisto/photo_studio/ps_engines.dart' show SecureScreen;
import 'package:assisto/screens/missing/missing_detail_screen.dart';
import 'package:assisto/screens/missing/missing_hub_screen.dart';
import 'package:assisto/screens/missing/missing_optin_screen.dart';
import 'package:assisto/screens/missing/missing_post_screen.dart';
import 'package:assisto/services/review_prompt.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/success_share.dart';

import 'fake_missing.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.bn = false, this.aboutMe = false}) {
    token = 't';
  }

  final bool empty;
  final bool bn;
  final bool aboutMe;
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (aboutMe && path == '/missing-alerts') {
      final a = fakeMissingAlert(31, bn: bn)..['role'] = 'subject';
      return {'enabled': true, 'near': const [], 'mine': const [], 'cosign': const [],
              'about_me': [a], 'optin': {'enabled': false}};
    }
    return fakeMissingGet(path, bn: bn, empty: empty) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    if (path.endsWith('/found')) {
      final a = fakeMissingAlert(21, bn: bn)
        ..['state'] = 'found'
        ..['photo_url'] = null
        ..['share_agreed'] = body['share_ok'] == true;
      return {'ok': true, 'alert': a};
    }
    return fakeMissingPost(path, bn: bn) ?? {'ok': true};
  }
}

class _NoSecure implements SecureScreen {
  int on = 0;
  @override
  Future<bool> enable() async {
    on++;
    return true;
  }

  @override
  Future<void> disable() async {}
}

Widget _app(Widget child, ApiClient api, {String lang = 'en', bool dark = false, double scale = 1}) {
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
      home: child,
    ),
  );
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 6400);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ReviewPrompt.debugRequest = null;
  });

  test('GD format mirror + coarse rounding', () {
    expect(maCleanGd('512/2026'), '512/2026');
    expect(maCleanGd('GD No. 512 / 2026'), '512/2026');
    expect(maCleanGd('৫১২'), '512'); // Bangla digits
    expect(maCleanGd('hello'), isNull);
    expect(maCleanGd('0'), isNull);
    expect(maCoarse(23.806912), 23.81);
  });

  testWidgets('hub: near + mine, who-gets card, opt-in entry opens the opt-in screen', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const MissingHubScreen(), _Fake()));
    await t.pumpAndSettle();
    expect(find.text(l.maNear), findsOneWidget);
    expect(find.text(l.maMine), findsOneWidget);
    expect(find.text(l.maWhoGetsBody), findsOneWidget);
    expect(find.text(l.maOptinOn), findsOneWidget);
    expect(find.byKey(const ValueKey('ma-alert-11')), findsOneWidget);
    expect(find.byKey(const ValueKey('ma-alert-21')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ma-optin-tile')));
    await t.pumpAndSettle();
    expect(find.byType(MissingOptinScreen), findsOneWidget);
  });

  testWidgets('hub empty: benefit, one primary action, opt-in off', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const MissingHubScreen(), _Fake(empty: true)));
    await t.pumpAndSettle();
    expect(find.text(l.maEmptyTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('ma-empty-post')), findsOneWidget);
    expect(find.text(l.maOptinOffTitle), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ma-empty-post')));
    await t.pumpAndSettle();
    expect(find.byType(MissingPostScreen), findsOneWidget);
  });

  testWidgets('the missing person: I am safe sends no location', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake(aboutMe: true);
    await t.pumpWidget(_app(const MissingHubScreen(), api));
    await t.pumpAndSettle();
    expect(find.text(l.maAboutMeTitle), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ma-safe')));
    await t.pumpAndSettle();
    expect(find.text(l.maSafeConfirmAdult), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ma-safe-confirm')));
    await t.pumpAndSettle();
    final p = api.posts.single;
    expect(p.$1, '/missing-alerts/31/safe');
    expect(p.$2.containsKey('lat'), isFalse);
    expect(p.$2.containsKey('lng'), isFalse);
  });

  testWidgets('nearby user: GD not verified, private anonymous tip, 999 button', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(
        MissingDetailScreen(alertId: 11, secure: _NoSecure(), locate: () async => (lat: 23.8069, lng: 90.3687)),
        api));
    await t.pumpAndSettle();
    expect(find.text(l.maGdUnverified), findsOneWidget);
    expect(find.byKey(const ValueKey('ma-999')), findsOneWidget);
    expect(find.text(l.maNoScreenshot), findsNothing); // no photo in the fake
    await t.tap(find.byKey(const ValueKey('ma-tip')));
    await t.pumpAndSettle();
    expect(find.text(l.maTipPrivate), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('ma-tip-text')), 'Saw him at the bus stand');
    await t.tap(find.byKey(const ValueKey('ma-tip-send')));
    await t.pumpAndSettle();
    final p = api.posts.single;
    expect(p.$1, '/missing-alerts/11/tips');
    expect(p.$2['share_identity'], isFalse);
    expect(p.$2.containsKey('lat'), isFalse);
    // second tip: with location (rounded on the phone) + name shared
    await t.tap(find.byKey(const ValueKey('ma-tip')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ma-tip-text')), 'Still there');
    await t.tap(find.byKey(const ValueKey('ma-tip-loc')));
    await t.tap(find.byKey(const ValueKey('ma-tip-share')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ma-tip-send')));
    await t.pumpAndSettle();
    expect(api.posts.last.$2['lat'], 23.81);
    expect(api.posts.last.$2['lng'], 90.37);
    expect(api.posts.last.$2['share_identity'], isTrue);
  });

  testWidgets('family: Found + agree to share opens the success-share screen', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(MissingDetailScreen(alertId: 21, secure: _NoSecure()), api));
    await t.pumpAndSettle();
    expect(find.textContaining('46'), findsWidgets); // reach line
    await t.tap(find.byKey(const ValueKey('ma-found')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ma-found-share')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ma-found-confirm')));
    await t.pumpAndSettle();
    expect(api.posts.single.$1, '/missing-alerts/21/found');
    expect(api.posts.single.$2['share_ok'], isTrue);
    expect(find.byType(SuccessShareScreen), findsOneWidget);
    expect(find.text(l.ssNoReward), findsOneWidget);
    // a child: the ready text has no name
    final field = t.widget<TextField>(find.byKey(const ValueKey('ss-text')));
    expect(field.controller!.text.contains('Rafi'), isFalse);
    expect(field.controller!.text.contains('https://lifeassisto.com'), isTrue);
  });

  testWidgets('family: Found without sharing does not open the share screen', (t) async {
    _tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(MissingDetailScreen(alertId: 21, secure: _NoSecure()), api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ma-found')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ma-found-confirm')));
    await t.pumpAndSettle();
    expect(api.posts.single.$2['share_ok'], isFalse);
    expect(find.byType(SuccessShareScreen), findsNothing);
  });

  testWidgets('post: adult needs a valid GD before any call; then the body is clean', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(const MissingPostScreen(), api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ma-who-other')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ma-relation')), 'brother');
    await t.enterText(find.byKey(const ValueKey('ma-name')), 'Karim');
    await t.enterText(find.byKey(const ValueKey('ma-age')), '34');
    await t.pumpAndSettle();
    expect(find.text(l.maAgeAdult), findsOneWidget);
    expect(find.text(l.maGdUnverified), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('ma-area')), 'Gabtoli bus terminal');
    await t.enterText(find.byKey(const ValueKey('ma-gd-number')), 'hello');
    await t.enterText(find.byKey(const ValueKey('ma-gd-thana')), 'Mirpur');
    for (final k in ['ma-c1', 'ma-c2', 'ma-c3']) {
      await t.ensureVisible(find.byKey(ValueKey(k)));
      await t.tap(find.byKey(ValueKey(k)));
    }
    await t.ensureVisible(find.byKey(const ValueKey('ma-submit')));
    await t.tap(find.byKey(const ValueKey('ma-submit')));
    await t.pumpAndSettle();
    expect(api.posts, isEmpty);
    expect(find.text(l.maErrGd), findsWidgets);
    await t.enterText(find.byKey(const ValueKey('ma-gd-number')), 'GD 512 / 2026');
    await t.ensureVisible(find.byKey(const ValueKey('ma-submit')));
    await t.tap(find.byKey(const ValueKey('ma-submit')));
    await t.pumpAndSettle();
    final b = api.posts.single.$2;
    expect(api.posts.single.$1, '/missing-alerts');
    expect(b['gd_number'], '512/2026');
    expect(b['district'], 'dhaka'); // from the opt-in
    expect(b['age'], 34);
    expect(b['confirm_no_address'], isTrue);
    expect(b.containsKey('lat'), isFalse);
  });

  testWidgets('post: a child shows the guardian card (co-signer from My Circle)', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const MissingPostScreen(), _Fake()));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ma-age')), '9');
    await t.pumpAndSettle();
    expect(find.text(l.maGuardianTitle), findsOneWidget);
    expect(find.text(l.maGuardianNeeds), findsOneWidget);
    expect(find.byKey(const ValueKey('ma-cosigner')), findsOneWidget);
    expect(find.byKey(const ValueKey('ma-gd-number')), findsNothing);
  });

  testWidgets('success share: copy, then Done asks Play once; never twice in 120 days', (t) async {
    _tall(t);
    var asked = 0;
    ReviewPrompt.debugRequest = () async => asked++;
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add('${(call.arguments as Map)['text']}');
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    Widget screen() => Builder(
        builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                      builder: (_) => const SuccessShareScreen(
                          title: 'Thanks', cardHeadline: 'Found', initialText: 'Thank you all.'))),
                  child: const Text('open'),
                ),
              ),
            ));
    await t.pumpWidget(_app(screen(), _Fake()));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    // Done without sharing: no review card
    await t.tap(find.byKey(const ValueKey('ss-done')));
    await t.pumpAndSettle();
    expect(asked, 0);
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ss-copy')));
    await t.pumpAndSettle();
    expect(copied.single, contains('https://lifeassisto.com'));
    await t.ensureVisible(find.byKey(const ValueKey('ss-done')));
    await t.tap(find.byKey(const ValueKey('ss-done')));
    await t.pumpAndSettle();
    expect(asked, 1);
    // again right away: Play is not asked a second time
    expect(await ReviewPrompt.maybeAsk(), isFalse);
    expect(asked, 1);
  });

  for (final dark in [false, true]) {
    testWidgets('200% Bangla ${dark ? 'dark' : 'light'}: hub, detail, post, share — no overflow', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      for (final w in <Widget>[
        const MissingHubScreen(),
        MissingDetailScreen(alertId: 11, secure: _NoSecure()),
        MissingDetailScreen(alertId: 21, secure: _NoSecure()),
        const MissingPostScreen(),
        const MissingOptinScreen(),
        const SuccessShareScreen(title: 'x', cardHeadline: 'y', initialText: 'z'),
      ]) {
        await t.pumpWidget(_app(w, _Fake(bn: true), lang: 'bn', dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: '${w.runtimeType}');
      }
    });
  }

  testWidgets('TalkBack: key actions have labels', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final h = t.ensureSemantics();
    await t.pumpWidget(_app(MissingDetailScreen(alertId: 11, secure: _NoSecure()), _Fake()));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(l.maTipCta))), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(l.maCall999))), findsOneWidget);
    await t.pumpWidget(_app(const MissingHubScreen(), _Fake()));
    await t.pumpAndSettle();
    expect(find.byTooltip(l.maOptinTitle), findsOneWidget);
    h.dispose();
  });
}
