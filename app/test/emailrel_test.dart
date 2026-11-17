// emailrel — honest email failures on the sign-in email screen and the OTP
// step: a bounced address shows "please check your email address", a
// temporary failure names SMS / try later, and the OTP step stops offering a
// dead email button (fake backend, no network).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/otp/email_verify_screen.dart';
import 'package:assisto/screens/otp/otp_verify_screen.dart';

import 'fake_otp.dart';

Widget _app(Widget home, {Locale locale = const Locale('en'), bool dark = false}) =>
    MaterialApp(
      locale: locale,
      theme: dark ? ThemeData.dark(useMaterial3: true) : ThemeData(useMaterial3: true),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );

void _tall(WidgetTester tester, {double w = 400}) {
  tester.view.physicalSize = Size(w, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _spin(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('bouncing saved address shows the check-your-address banner (bn, dark)',
      (tester) async {
    _tall(tester, w: 360);
    final b = FakeOtpBackend(
        emailEnabled: true, verifiedEmail: 'rahim@example.com', emailBouncing: true);
    await tester.pumpWidget(
        _app(EmailVerifyScreen(backend: b), locale: const Locale('bn'), dark: true));
    await _spin(tester);
    expect(find.byKey(const Key('email-bouncing')), findsOneWidget);
    expect(find.textContaining('ইমেইল ফেরত আসছে'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no banner when the address is fine', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(emailEnabled: true, verifiedEmail: 'rahim@example.com');
    await tester.pumpWidget(_app(EmailVerifyScreen(backend: b)));
    await _spin(tester);
    expect(find.byKey(const Key('email-bouncing')), findsNothing);
  });

  for (final c in const [
    ('email_bouncing', 'Please check your email address'),
    ('email_send_failed', 'try again in a few minutes'),
    ('email_rejected', 'inbox full'),
  ]) {
    testWidgets('email screen: ${c.$1} shows an honest message, never "sent"',
        (tester) async {
      _tall(tester);
      final b = FakeOtpBackend(emailEnabled: true, emailFailReason: c.$1);
      await tester.pumpWidget(_app(EmailVerifyScreen(backend: b)));
      await _spin(tester);
      await tester.enterText(find.byKey(const Key('email-field')), 'a@example.com');
      await tester.tap(find.byKey(const Key('email-send')));
      await _spin(tester);
      expect(find.byKey(const Key('email-error')), findsOneWidget);
      expect(find.textContaining(c.$2), findsOneWidget);
      expect(find.byKey(const Key('email-note')), findsNothing);
      expect(find.textContaining('SMS'), findsWidgets);
    });
  }

  testWidgets('OTP step: a bounced email hides the email button and keeps SMS',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(emailEnabled: true, emailFailReason: 'email_bouncing');
    await tester.pumpWidget(_app(OtpVerifyScreen(
        backend: b, purpose: 'login', phone: '01712345678', title: 'T')));
    await _spin(tester);
    final btn = find.byKey(const Key('otp-email'));
    expect(btn, findsOneWidget);
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await _spin(tester);
    expect(find.textContaining('Please check your email address'), findsOneWidget);
    expect(find.byKey(const Key('otp-email')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
