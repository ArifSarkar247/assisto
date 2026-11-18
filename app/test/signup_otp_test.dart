// signup-otp (owner P0, 17 Nov) — a real new user said "the sign-up code
// did not arrive". Cause: sign-up needs NO code; the person tapped "Sign in
// with a code by email", got the neutral "sent if the account exists" answer
// and waited. These tests pin the fixed OTP step: Spam hint, resend
// countdown, email <-> phone switching, honest provider failures that offer
// the other way, and the one-tap way to "Create an account".
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/screens/otp/otp_verify_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_otp.dart';

Widget _app(Widget home,
        {Locale locale = const Locale('en'), bool dark = false, double scale = 1}) =>
    ChangeNotifierProvider<AppState>.value(
      value: AppState()
        ..api = FakeApi(lang: locale.languageCode)
        ..user = AppUser(
            id: 1,
            name: 'Rahim',
            phone: '01712345678',
            email: '',
            autonomyLevel: 2,
            language: locale.languageCode)
        ..locale = locale
        ..loading = false,
      child: MaterialApp(
        locale: locale,
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: w!),
        home: home,
      ),
    );

void _tall(WidgetTester tester, {double w = 400, double h = 2400}) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _spin(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapKey(WidgetTester tester, String k) async {
  final f = find.byKey(Key(k));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await _spin(tester);
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('email code: Spam hint + 60 s resend countdown, then resend works',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
    await tester.pumpWidget(_app(OtpVerifyScreen(
        backend: b,
        purpose: 'login',
        email: 'new@example.com',
        emailFirst: true,
        title: 'T')));
    await _spin(tester);
    final t = _t(tester);
    expect(find.byKey(const Key('otp-spam-hint')), findsOneWidget);
    expect(find.text(t.signupOtpSpamHint), findsOneWidget);
    final resend = find.byKey(const Key('otp-resend'));
    expect(tester.widget<TextButton>(resend).onPressed, isNull);
    // counting down from the server's 60 s (about 2 s already spun above)
    expect(
        find.descendant(
            of: resend,
            matching: find.byWidgetPredicate((w) =>
                w is Text &&
                ['58', '59', '60'].any((n) => w.data == t.qa1OtpResendIn(n)))),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(tester.widget<TextButton>(resend).onPressed, isNull);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(tester.widget<TextButton>(resend).onPressed, isNotNull);
    expect(find.text(t.otpResend), findsOneWidget);
    await _tapKey(tester, 'otp-resend');
    expect(b.calls.where((c) => c == 'email:login').length, 2);
    // the countdown restarts after a resend (server cooldown respected)
    expect(tester.widget<TextButton>(resend).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SMS -> "email instead" -> "Use phone (SMS) instead" switches back',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: true, emailEnabled: true);
    await tester.pumpWidget(_app(OtpVerifyScreen(
        backend: b, purpose: 'login', phone: '01712345678', title: 'T')));
    await _spin(tester);
    expect(find.byKey(const Key('otp-spam-hint')), findsNothing);
    expect(find.byKey(const Key('otp-use-phone')), findsNothing);
    await _tapKey(tester, 'otp-email');
    expect(b.calls, contains('email:login'));
    expect(find.byKey(const Key('otp-spam-hint')), findsOneWidget);
    expect(find.byKey(const Key('otp-email')), findsNothing);
    await _tapKey(tester, 'otp-use-phone');
    expect(b.calls.where((c) => c == 'request:login').length, 2);
    expect(find.byKey(const Key('otp-spam-hint')), findsNothing);
    expect(find.byKey(const Key('otp-use-phone')), findsNothing);
    expect(find.byKey(const Key('otp-email')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed email send: clear message + offers SMS (bn, dark, 200%)',
      (tester) async {
    _tall(tester, w: 360, h: 3200);
    final b = FakeOtpBackend(
        smsEnabled: true, emailEnabled: true, emailFailReason: 'email_send_failed');
    await tester.pumpWidget(_app(
        OtpVerifyScreen(backend: b, purpose: 'login', phone: '01712345678', title: 'T'),
        locale: const Locale('bn'),
        dark: true,
        scale: 2));
    await _spin(tester);
    await _tapKey(tester, 'otp-email');
    final t = _t(tester);
    expect(find.text(t.emailrelSendFailed), findsOneWidget);
    expect(find.byKey(const Key('otp-use-phone')), findsOneWidget);
    final btn = tester.getSize(find.byKey(const Key('otp-use-phone')));
    expect(btn.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed email with SMS off -> "Sign in with password instead"',
      (tester) async {
    _tall(tester);
    String? left;
    final b = FakeOtpBackend(
        smsEnabled: false, emailEnabled: true, emailFailReason: 'email_send_failed');
    await tester.pumpWidget(_app(Builder(
        builder: (context) => Scaffold(
            body: Center(
                child: FilledButton(
                    key: const Key('open'),
                    onPressed: () => OtpVerifyScreen.run(context,
                        backend: b,
                        purpose: 'login',
                        email: 'x@example.com',
                        emailFirst: true,
                        title: 'T',
                        onLeave: (w) => left = w),
                    child: const Text('open')))))));
    await tester.tap(find.byKey(const Key('open')));
    await _spin(tester);
    expect(find.byKey(const Key('otp-use-phone')), findsNothing); // no SMS
    await _tapKey(tester, 'otp-use-password');
    expect(left, 'password');
    expect(find.byType(OtpVerifyScreen), findsNothing);
  });

  testWidgets(
      'owner-found: a NEW person on "code by email" gets "Create an account" '
      'and lands on sign-up', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
    await tester.pumpWidget(_app(LoginScreen(otpBackend: b)));
    await tester.pumpAndSettle();
    await _tapKey(tester, 'login-with-email-code');
    await tester.enterText(find.byKey(const Key('otp-id')), 'new@example.com');
    await _tapKey(tester, 'otp-send');
    final t = _t(tester);
    // neutral answer (no account enumeration) + the honest way out
    expect(find.text(t.signupOtpEmailNeutral), findsOneWidget);
    expect(find.byKey(const Key('otp-spam-hint')), findsOneWidget);
    await _tapKey(tester, 'otp-create-account');
    await tester.pumpAndSettle();
    expect(find.byType(OtpVerifyScreen), findsNothing);
    expect(find.text(t.haveAccount), findsOneWidget); // sign-up mode
    expect(tester.takeException(), isNull);
  });

  testWidgets('code sign-in screen itself offers "Create an account"',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
    await tester.pumpWidget(_app(LoginScreen(otpBackend: b)));
    await tester.pumpAndSettle();
    await _tapKey(tester, 'login-with-email-code');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'otp-login-create-account');
    await tester.pumpAndSettle();
    expect(find.text(_t(tester).haveAccount), findsOneWidget);
    expect(b.calls.where((c) => c.startsWith('email:')), isEmpty);
  });
}
