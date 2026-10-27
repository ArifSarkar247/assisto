// smsotp — email OTP backup: "send the code by email" on the OTP step and
// the Settings "Email for sign-in codes" screen (fake backend, no network).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/otp_api.dart';
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

class _Host extends StatefulWidget {
  final OtpBackend backend;
  final String purpose;
  const _Host(this.backend, {this.purpose = 'login'});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String result = 'none';
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('result:$result'),
            ElevatedButton(
              onPressed: () async {
                final p = await OtpVerifyScreen.run(context,
                    backend: widget.backend,
                    purpose: widget.purpose,
                    phone: '01712345678',
                    title: 'T');
                setState(() => result = p ?? 'null');
              },
              child: const Text('open'),
            ),
          ]),
        ),
      );
}

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
  testWidgets('OTP step offers email when the server can send it; code verifies',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(emailEnabled: true);
    await tester.pumpWidget(_app(_Host(b)));
    await tester.tap(find.text('open'));
    await _spin(tester);
    final btn = find.byKey(const Key('otp-email'));
    expect(btn, findsOneWidget);
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(48));
    await tester.tap(btn);
    await _spin(tester);
    expect(b.calls, contains('email:login'));
    expect(find.byKey(const Key('otp-email-note')), findsOneWidget);
    expect(find.byKey(const Key('otp-email')), findsNothing);
    expect(find.byIcon(Icons.email_rounded), findsOneWidget);
    await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
    await _spin(tester);
    expect(find.text('result:proof-login'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no email option when the server has no email set up', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(emailEnabled: false);
    await tester.pumpWidget(_app(_Host(b)));
    await tester.tap(find.text('open'));
    await _spin(tester);
    expect(find.byKey(const Key('otp-email')), findsNothing);
  });

  testWidgets('no email option for sign-up (email cannot prove a phone)',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(emailEnabled: true);
    await tester.pumpWidget(_app(_Host(b, purpose: 'signup')));
    await tester.tap(find.text('open'));
    await _spin(tester);
    expect(find.byKey(const Key('otp-email')), findsNothing);
  });

  testWidgets('SMS off + email on: the honest card offers "get the code by email"',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
    await tester.pumpWidget(_app(_Host(b), locale: const Locale('bn')));
    await tester.tap(find.text('open'));
    await _spin(tester);
    final get = find.byKey(const Key('otp-email-get'));
    expect(get, findsOneWidget);
    await tester.tap(get);
    await _spin(tester);
    expect(find.byKey(const Key('otp-code-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings email screen: send code, verify, shows Verified (dark, 360px)',
      (tester) async {
    _tall(tester, w: 360);
    final b = FakeOtpBackend(emailEnabled: true);
    await tester.pumpWidget(_app(EmailVerifyScreen(backend: b), dark: true));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('email-field')), 'not-an-email');
    await tester.tap(find.byKey(const Key('email-send')));
    await _spin(tester);
    expect(find.byKey(const Key('email-error')), findsOneWidget);
    expect(b.calls.where((c) => c.startsWith('email:')), isEmpty);

    await tester.enterText(find.byKey(const Key('email-field')), 'rahim@example.com');
    await tester.tap(find.byKey(const Key('email-send')));
    await _spin(tester);
    expect(b.calls, contains('email:email_verify'));
    expect(b.lastEmail, 'rahim@example.com');
    expect(find.byKey(const Key('email-note')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
    await _spin(tester);
    expect(b.calls, contains('confirm:rahim@example.com:123456'));
    expect(find.byKey(const Key('email-status')), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('email-send'))).height,
        greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings email screen: honest off state in Bangla', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(emailEnabled: false);
    await tester.pumpWidget(_app(EmailVerifyScreen(backend: b), locale: const Locale('bn')));
    await _spin(tester);
    expect(find.byKey(const Key('email-off')), findsOneWidget);
    expect(find.byKey(const Key('email-field')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wrong code on the email screen shows the error and clears', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(emailEnabled: true);
    await tester.pumpWidget(_app(EmailVerifyScreen(backend: b)));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('email-field')), 'a@example.com');
    await tester.tap(find.byKey(const Key('email-send')));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('otp-code-field')), '000000');
    await _spin(tester);
    expect(find.byKey(const Key('email-error')), findsOneWidget);
    expect(b.verifiedEmail, '');
  });
}
