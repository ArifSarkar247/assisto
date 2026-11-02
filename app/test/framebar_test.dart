// framebar (2 Nov) — launch bar for board groups 14 (plans / credits / ads)
// and 15 (app frame: start, login, settings). Each test pins one bug that
// was found in the checklist sweep (see owner_actions/FEATURE_CARD_*_BN.md).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/play_prices.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/play_update.dart';
import 'package:assisto/push/push_service.dart';
import 'package:assisto/screens/about_screen.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/screens/otp/otp_login_screen.dart';
import 'package:assisto/screens/plans_screen.dart';
import 'package:assisto/services/data_export.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_otp.dart';
import 'pay1_fakes.dart';

/// Login fails like a phone with no internet (the http client throws).
class _OfflineApi extends FakeApi {
  _OfflineApi() : super(lang: 'en');
  @override
  Future<({String token, AppUser user})> login(
          {required String identifier, required String password}) async =>
      throw const SocketException('Failed host lookup');
}

/// Login refused by the server with its own localized message.
class _WrongPwApi extends FakeApi {
  _WrongPwApi() : super(lang: 'en');
  @override
  Future<({String token, AppUser user})> login(
          {required String identifier, required String password}) async =>
      throw ApiException('Wrong phone/email or password.', 400);
}

AppState _state(ApiClient api, {String lang = 'en'}) => AppState()
  ..api = api
  ..user = AppUser(
      id: 1,
      name: 'Rahim',
      phone: '01712345678',
      email: '',
      autonomyLevel: 2,
      language: lang)
  ..locale = Locale(lang)
  ..loading = false;

Widget _wrap(Widget child, {ApiClient? api, String lang = 'en'}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api ?? FakeApi(lang: lang), lang: lang),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        home: child,
      ),
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _spin(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ---------------------------------------------------------------- login
  group('Login: honest one-time-code button (SMS is off at launch)', () {
    testWidgets('SMS live -> "SMS code" button, no email one', (tester) async {
      _tall(tester);
      await tester.pumpWidget(
          _wrap(LoginScreen(otpBackend: FakeOtpBackend(smsEnabled: true))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-with-sms')), findsOneWidget);
      expect(find.byKey(const Key('login-with-email-code')), findsNothing);
    });

    testWidgets('SMS off + email on -> "code by email" button only',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(LoginScreen(
          otpBackend: FakeOtpBackend(smsEnabled: false, emailEnabled: true))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-with-sms')), findsNothing);
      await tester.tap(find.byKey(const Key('login-with-email-code')));
      await tester.pumpAndSettle();
      final s = tester.widget<OtpLoginScreen>(find.byType(OtpLoginScreen));
      expect(s.emailMode, isTrue);
    });

    testWidgets('neither can send -> no code button at all (no dead end)',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(LoginScreen(
          otpBackend: FakeOtpBackend(smsEnabled: false, emailEnabled: false))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-with-sms')), findsNothing);
      expect(find.byKey(const Key('login-with-email-code')), findsNothing);
    });

    testWidgets('offline login: localized "couldn\'t connect", never a raw '
        'Dart error', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(
          LoginScreen(otpBackend: FakeOtpBackend(smsEnabled: false)),
          api: _OfflineApi()));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(tester.element(find.byType(LoginScreen)));
      await tester.enterText(find.byType(TextField).first, '01712345678');
      await tester.enterText(find.byType(TextField).at(1), 'pw123456');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text(t.otpErrNetwork), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.textContaining('Failed host lookup'), findsNothing);
      // the error uses the theme's error colour (dark-mode contrast)
      final err = tester.widget<Text>(find.byKey(const Key('login-error')));
      expect(err.style?.color,
          Theme.of(tester.element(find.byType(LoginScreen))).colorScheme.error);
    });

    testWidgets('server refusal keeps the server\'s own message',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(
          LoginScreen(otpBackend: FakeOtpBackend(smsEnabled: false)),
          api: _WrongPwApi()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '01712345678');
      await tester.enterText(find.byType(TextField).at(1), 'nope');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('Wrong phone/email or password.'), findsOneWidget);
    });
  });

  group('Email-code sign-in (SMS off)', () {
    testWidgets('email typed -> code goes by EMAIL first, verified + signed in '
        'by email (no SMS attempt)', (tester) async {
      _tall(tester);
      final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
      await tester.pumpWidget(_wrap(OtpLoginScreen(backend: b, emailMode: true)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('otp-id')), 'rahim@example.com');
      await tester.tap(find.byKey(const Key('otp-send')));
      await _spin(tester);
      expect(b.calls, contains('email:login'));
      expect(b.calls, isNot(contains('request:login'))); // no SMS detour
      expect(b.lastEmail, 'rahim@example.com');
      await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
      await _spin(tester);
      expect(b.lastVerifyEmail, 'rahim@example.com');
      expect(b.calls, contains('login-email:rahim@example.com:proof-login'));
    });

    testWidgets('phone typed -> email code for that account (phone identity)',
        (tester) async {
      _tall(tester);
      final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
      await tester.pumpWidget(_wrap(OtpLoginScreen(backend: b, emailMode: true)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('otp-id')), '01712345678');
      await tester.tap(find.byKey(const Key('otp-send')));
      await _spin(tester);
      expect(b.calls, contains('email:login'));
      expect(b.lastEmail, isNull);
      await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
      await _spin(tester);
      expect(b.calls, contains('login:01712345678:proof-login'));
    });

    testWidgets('neither phone nor email -> honest inline error, nothing sent',
        (tester) async {
      _tall(tester);
      final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
      await tester.pumpWidget(_wrap(OtpLoginScreen(backend: b, emailMode: true)));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(tester.element(find.byType(OtpLoginScreen)));
      await tester.enterText(find.byKey(const Key('otp-id')), 'rahim');
      await tester.tap(find.byKey(const Key('otp-send')));
      await tester.pumpAndSettle();
      expect(find.text(t.fbOtpIdInvalid), findsOneWidget);
      expect(b.calls.where((c) => c.startsWith('email:')), isEmpty);
    });
  });

  // ------------------------------------------------- permissions in context
  test('no bare notification-permission dialog right after sign-in', () {
    // The ask lives in the call/SOS ring checklist (after onboarding) and on
    // the screens that need it — never a reason-less popup mid-onboarding.
    expect(PushService.autoAskOnSignIn, isFalse);
  });

  // ------------------------------------------------------- update policy
  group('Play update prompt never pops over home', () {
    tearDown(PlayUpdate.resetForTest);

    test('launch check is silent; Settings prompts once per run', () async {
      var starts = 0;
      PlayUpdate.isPlayBuild = () => true;
      PlayUpdate.availableFn = () async => true;
      PlayUpdate.startFn = () async {
        starts++;
        return false;
      };
      await PlayUpdate.checkSoon(delay: Duration.zero);
      expect(PlayUpdate.available, isTrue);
      expect(starts, 0, reason: 'no Play dialog at launch (= over home)');
      await PlayUpdate.promptIfAvailable(); // Settings opened
      await PlayUpdate.promptIfAvailable(); // Settings opened again
      expect(starts, 1);
    });

    test('nothing waiting -> Settings shows nothing', () async {
      var starts = 0;
      PlayUpdate.isPlayBuild = () => true;
      PlayUpdate.availableFn = () async => false;
      PlayUpdate.startFn = () async {
        starts++;
        return false;
      };
      await PlayUpdate.checkSoon(delay: Duration.zero);
      await PlayUpdate.promptIfAvailable();
      expect(starts, 0);
    });

    test('About button: up to date / started / failed / not Play', () async {
      PlayUpdate.isPlayBuild = () => true;
      PlayUpdate.availableFn = () async => false;
      expect(await PlayUpdate.checkNow(), PlayUpdateCheck.upToDate);
      PlayUpdate.availableFn = () async => true;
      PlayUpdate.startFn = () async => false;
      expect(await PlayUpdate.checkNow(), PlayUpdateCheck.started);
      PlayUpdate.availableFn = () async => throw StateError('no Play');
      expect(await PlayUpdate.checkNow(), PlayUpdateCheck.failed);
      PlayUpdate.isPlayBuild = () => false;
      expect(await PlayUpdate.checkNow(), PlayUpdateCheck.notPlay);
    });

    test('direct APK build: everything is a no-op', () async {
      var calls = 0;
      PlayUpdate.isPlayBuild = () => false;
      PlayUpdate.availableFn = () async {
        calls++;
        return true;
      };
      await PlayUpdate.checkSoon(delay: Duration.zero);
      await PlayUpdate.promptIfAvailable();
      await PlayUpdate.onBackground();
      expect(calls, 0);
    });
  });

  // ------------------------------------------------------------ about
  group('About: licences + data credits', () {
    testWidgets('credits card names OpenStreetMap; licences open the licence '
        'page', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(const AboutScreen()));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(tester.element(find.byType(AboutScreen)));
      expect(find.byKey(const Key('about-data-credits')), findsOneWidget);
      expect(find.text(t.fbCreditOsm), findsOneWidget);
      final tile = find.byKey(const Key('about-licences'));
      await tester.ensureVisible(tile);
      expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
      await tester.tap(tile);
      // the licence list loads asynchronously (spinner) -> no pumpAndSettle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(LicensePage), findsOneWidget);
    });

    testWidgets('Bangla: credits in Bangla, 200% font does not overflow',
        (tester) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(_wrap(const AboutScreen(), lang: 'bn'));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(tester.element(find.byType(AboutScreen)));
      expect(find.text(t.fbCreditsTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------------------------ export
  group('Data export reaches the person (share sheet)', () {
    tearDown(() {
      DataExport.sharer = (p, s) async => true;
    });

    test('writes the JSON and hands that file to the share sheet', () async {
      final tmp = await Directory.systemTemp.createTemp('fb_export');
      addTearDown(() => tmp.delete(recursive: true));
      DataExport.dirOf = () async => tmp;
      String? sharedPath;
      String? sharedSubject;
      DataExport.sharer = (p, s) async {
        sharedPath = p;
        sharedSubject = s;
        return true;
      };
      final ok = await DataExport.run(() async => '{"notes":[1,2]}',
          subject: 'My Assisto data');
      expect(ok, isTrue);
      expect(sharedPath, '${tmp.path}/${DataExport.fileName}');
      expect(File(sharedPath!).readAsStringSync(), '{"notes":[1,2]}');
      expect(sharedSubject, 'My Assisto data');
    });

    test('server error propagates (caller shows its honest message)', () async {
      DataExport.dirOf = () async => Directory.systemTemp;
      expect(
          DataExport.run(() async => throw ApiException('boom', 500),
              subject: 's'),
          throwsA(isA<ApiException>()));
    });

    test('share sheet failure -> false, never a crash', () async {
      final tmp = await Directory.systemTemp.createTemp('fb_export2');
      addTearDown(() => tmp.delete(recursive: true));
      DataExport.dirOf = () async => tmp;
      DataExport.sharer = (p, s) async => throw StateError('no activity');
      expect(await DataExport.run(() async => '{}', subject: 's'), isFalse);
    });
  });

  // ------------------------------------------------------------ plans
  group('Plans page: one price source on the Play build', () {
    tearDown(() {
      FakeApi.payLive = false;
      FakeApi.playLive = false;
      FakeApi.planSlug = 'premium';
      debugPayFlavour = null;
      StoreBilling.debugOverride = null;
      PlayPrices.debugReset();
    });

    Future<AppLocalizations> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 9000);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(const PlansScreen()));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return AppLocalizations.of(tester.element(find.byType(PlansScreen)));
    }

    testWidgets('Play: no FAQ "annual saves ৳X" line from server taka',
        (tester) async {
      debugPayFlavour = 'play';
      FakeApi.playLive = true;
      FakeApi.planSlug = 'free';
      StoreBilling.debugOverride = FakeStoreBilling();
      final t = await pump(tester);
      // Play says BDT 1,990 for the year; the server row says 1910 — the
      // FAQ line would have shown a second, different price.
      expect(find.text(t.plansAnnualVsMonthlyTitle), findsNothing);
    });

    testWidgets('website APK keeps the saving line (server prices there)',
        (tester) async {
      debugPayFlavour = 'apk';
      FakeApi.payLive = true;
      FakeApi.planSlug = 'free';
      final t = await pump(tester);
      expect(find.text(t.plansAnnualVsMonthlyTitle), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ ads
  group('Ads: never on money / sign-in / permission screens', () {
    const never = [
      'plans', 'credits_topup', 'checkout', 'payment', 'login', 'otp',
      'signup', 'onboarding', 'language_picker', 'delete_account',
      'permission', 'ring_check', 'chat', 'circle_chat', 'sos',
    ];
    for (final s in never) {
      test('"$s" refused for every ad format', () {
        for (final f in AdSurface.values) {
          expect(AdPlacements.screenAllowed(f, s), isFalse, reason: '$f on $s');
        }
      });
    }

    test('My Circle: banner on the chat LIST only', () {
      expect(AdPlacements.screenAllowed(AdSurface.banner, 'circle_list'), isTrue);
      for (final s in ['circle_chat', 'circle_conversation', 'circle_calls',
          'chat_conversation', 'chat_lock']) {
        expect(AdPlacements.screenAllowed(AdSurface.banner, s), isFalse,
            reason: s);
      }
    });

    test('counting: every SDK bridge uses the de-duplicating tracker', () {
      // the 28 Oct "2 impressions, 3 clicks" bug came from per-callback
      // counting; the legacy undeduped calls must stay unused.
      final files = [
        ...Directory('lib/ads').listSync().whereType<File>(),
        File('lib/photo_studio/admob_photo_bridge.dart'),
      ].where((f) => f.path.endsWith('.dart') &&
          !f.path.endsWith('ad_telemetry.dart'));
      final legacy = RegExp(r'AdTelemetry\.(impression|click|paid)\(');
      for (final f in files) {
        expect(legacy.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
      }
    });
  });
}
