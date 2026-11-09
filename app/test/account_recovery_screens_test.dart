// recovery (owner order Part 8) — Account & security, change password,
// email nudge, forgot password (SMS or verified email), support recovery.
// Fake backends, no network. bn + en, light + dark, 48 dp, no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/account_security_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/account_recovery_screens.dart';
import 'package:assisto/screens/account_security_screen.dart';

import 'fake_account_security.dart';
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

void _tall(WidgetTester tester, {double w = 400, double h = 2400}) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _spin(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('Account & security: phone verified, no email, honest Google note, devices',
      (tester) async {
    _tall(tester);
    final b = FakeAccountSecurity();
    await tester.pumpWidget(_app(AccountSecurityScreen(backend: b, otpBackend: FakeOtpBackend())));
    await _spin(tester);
    expect(find.text('+8801712345678'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('No email yet'), findsOneWidget);
    expect(find.text('Add email'), findsOneWidget);
    expect(find.byKey(const Key('rec-google-note')), findsOneWidget);
    expect(find.text('This phone'), findsOneWidget);
    expect(find.text('Samsung Galaxy'), findsOneWidget);
    expect(find.text('Older app version (one or more phones)'), findsOneWidget);
    // the current phone has no Sign out button; the others do
    expect(find.byKey(const Key('rec-signout-s1')), findsNothing);
    expect(tester.getSize(find.byKey(const Key('rec-signout-s2'))).height,
        greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const Key('rec-signout-s2')));
    await _spin(tester);
    await tester.tap(find.byKey(const Key('rec-confirm-yes')));
    await _spin(tester);
    expect(b.calls, contains('signout:s2'));
    expect(find.text('Samsung Galaxy'), findsNothing);
    await tester.tap(find.byKey(const Key('rec-signout-others')));
    await _spin(tester);
    await tester.tap(find.byKey(const Key('rec-confirm-yes')));
    await _spin(tester);
    expect(b.calls, contains('signout-others'));
    expect(find.byKey(const Key('rec-signout-others')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner "this was not me" cancel + family confirm', (tester) async {
    _tall(tester);
    final b = FakeAccountSecurity(state: FakeAccountSecurity.sample(alerts: true, email: true));
    await tester.pumpWidget(_app(AccountSecurityScreen(backend: b, otpBackend: FakeOtpBackend())));
    await _spin(tester);
    expect(find.text('Someone asked to recover your account'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rec-owner-cancel-7')));
    await _spin(tester);
    expect(b.calls, contains('cancel:7'));
    expect(find.textContaining('Karim Ahmed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rec-family-yes-9')));
    await _spin(tester);
    await tester.tap(find.byKey(const Key('rec-confirm-yes')));
    await _spin(tester);
    expect(b.calls, contains('family:9:true'));
    expect(find.text('Change email'), findsOneWidget);
  });

  testWidgets('change password: wrong current shows error; success rotates token',
      (tester) async {
    _tall(tester);
    final b = FakeAccountSecurity();
    String? tok;
    await tester.pumpWidget(_app(AccountSecurityScreen(
        backend: b, otpBackend: FakeOtpBackend(), onToken: (t) => tok = t)));
    await _spin(tester);
    await tester.tap(find.byKey(const Key('rec-password')));
    await _spin(tester);
    await tester.enterText(find.descendant(
        of: find.byKey(const Key('rec-pw-current')), matching: find.byType(TextField)), 'bad');
    await tester.enterText(find.descendant(
        of: find.byKey(const Key('rec-pw-new')), matching: find.byType(TextField)), 'newpass456');
    await tester.enterText(find.descendant(
        of: find.byKey(const Key('rec-pw-again')), matching: find.byType(TextField)), 'newpass4');
    await tester.tap(find.byKey(const Key('rec-pw-save')));
    await _spin(tester);
    expect(find.text("The two new passwords don't match."), findsOneWidget);
    await tester.enterText(find.descendant(
        of: find.byKey(const Key('rec-pw-again')), matching: find.byType(TextField)), 'newpass456');
    await tester.tap(find.byKey(const Key('rec-pw-save')));
    await _spin(tester);
    expect(find.byKey(const Key('rec-pw-error')), findsOneWidget);
    await tester.enterText(find.descendant(
        of: find.byKey(const Key('rec-pw-current')), matching: find.byType(TextField)), 'oldpass123');
    await tester.tap(find.byKey(const Key('rec-pw-save')));
    await _spin(tester);
    expect(tok, 'rotated-token');
    expect(find.byKey(const Key('rec-pw-save')), findsNothing); // popped back
  });

  testWidgets('email nudge: Later is remembered on the server, shown once per run',
      (tester) async {
    _tall(tester);
    EmailNudge.resetForTest();
    final b = FakeAccountSecurity();
    await tester.pumpWidget(_app(Builder(
        builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                    onPressed: () => EmailNudge.maybeShow(ctx,
                        backend: b, otpBackend: FakeOtpBackend()),
                    child: const Text('open')),
              ),
            ))));
    await tester.tap(find.text('open'));
    await _spin(tester);
    expect(find.text('Add an email to protect your account'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rec-nudge-later')));
    await _spin(tester);
    expect(b.calls, contains('nudge:later'));
    await tester.tap(find.text('open'));
    await _spin(tester);
    expect(find.text('Add an email to protect your account'), findsNothing);
  });

  testWidgets('forgot password: choose email; SMS-only note without a verified email',
      (tester) async {
    _tall(tester);
    final b = FakeAccountSecurity(emailOnAccount: true);
    final otp = FakeOtpBackend(emailEnabled: true);
    await tester.pumpWidget(_app(ForgotPasswordScreen(backend: b, otpBackend: otp)));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('fp-phone')), '01712345678');
    await tester.tap(find.byKey(const Key('fp-continue')));
    await _spin(tester);
    expect(find.byKey(const Key('fp-via-sms')), findsOneWidget);
    expect(find.byKey(const Key('fp-via-email')), findsOneWidget);
    expect(find.textContaining('ra•••@example.com'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fp-send')));
    await _spin(tester);
    expect(otp.calls, contains('email:password_reset')); // the chosen channel

    final b2 = FakeAccountSecurity(emailOnAccount: false);
    await tester.pumpWidget(const SizedBox()); // drop the pushed code step
    await tester.pumpWidget(_app(ForgotPasswordScreen(backend: b2, otpBackend: FakeOtpBackend()),
        locale: const Locale('bn')));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('fp-phone')), '01712345678');
    await tester.tap(find.byKey(const Key('fp-continue')));
    await _spin(tester);
    expect(find.byKey(const Key('fp-via-email')), findsNothing);
    expect(find.byKey(const Key('fp-sms-only')), findsOneWidget);
    expect(find.byKey(const Key('fp-lost-phone')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('support recovery: must verify the new number, then sends the proof',
      (tester) async {
    _tall(tester, h: 3200);
    final b = FakeAccountSecurity();
    final store = MemoryRefStore();
    await tester.pumpWidget(_app(SupportRecoveryScreen(
        backend: b, otpBackend: FakeOtpBackend(), store: store)));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('sr-lost')), '01712345678');
    await tester.enterText(find.byKey(const Key('sr-new')), '01611000004');
    await tester.enterText(find.byKey(const Key('sr-name')), 'Rahim Uddin');
    await tester.tap(find.byKey(const Key('sr-submit')));
    await _spin(tester);
    expect(find.byKey(const Key('sr-error')), findsOneWidget); // verify first
    expect(b.calls, isNot(contains('start')));
    await tester.tap(find.byKey(const Key('sr-verify-new')));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
    await _spin(tester);
    expect(find.byKey(const Key('sr-new-ok')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sr-family')), '01911000002');
    await tester.ensureVisible(find.byKey(const Key('sr-submit')));
    await tester.tap(find.byKey(const Key('sr-submit')));
    await _spin(tester);
    expect(b.lastStart!['contact_otp_proof'], 'proof-account_recovery');
    expect(b.lastStart!['family_phone'], '01911000002');
    expect(store.v!['ref'], 'AB12CD34');
    expect(find.byKey(const Key('sr-state')), findsOneWidget);
    expect(find.textContaining('Under review'), findsOneWidget);
  });

  testWidgets('support recovery ready: verify new number + password -> signed in',
      (tester) async {
    _tall(tester);
    final b = FakeAccountSecurity(supportState: 'ready');
    final store = MemoryRefStore({'ref': 'AB12CD34', 'secret': 's', 'contact': '01611000004'});
    String? signedIn;
    await tester.pumpWidget(_app(SupportRecoveryScreen(
        backend: b,
        otpBackend: FakeOtpBackend(),
        store: store,
        onSignedIn: (tok, u) async => signedIn = tok)));
    await _spin(tester);
    await tester.enterText(find.descendant(
        of: find.byKey(const Key('sr-final-pw')), matching: find.byType(TextField)), 'fresh12345');
    await tester.tap(find.byKey(const Key('sr-finish')));
    await _spin(tester);
    await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
    await _spin(tester);
    expect(b.calls, contains('complete:AB12CD34:proof-account_recovery'));
    expect(signedIn, 'new-token');
    expect(store.v, isNull);
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('no overflow at 200% font $lang dark=$dark', (tester) async {
        _tall(tester, w: 360, h: 4000);
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(_app(
            AccountSecurityScreen(
                backend: FakeAccountSecurity(
                    state: FakeAccountSecurity.sample(alerts: true)),
                otpBackend: FakeOtpBackend()),
            locale: Locale(lang),
            dark: dark));
        await _spin(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(_app(
            SupportRecoveryScreen(
                backend: FakeAccountSecurity(),
                otpBackend: FakeOtpBackend(),
                store: MemoryRefStore()),
            locale: Locale(lang),
            dark: dark));
        await _spin(tester);
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('AccountSecurity.fromJson reads the server overview', () {
    final s = AccountSecurity.fromJson({
      'phone': '+8801712345678',
      'phone_verified': true,
      'email': '',
      'email_verified': false,
      'has_password': true,
      'google': {'available': false},
      'devices': [
        {'id': 's3', 'kind': 'device', 'name': 'Realme', 'current': true,
         'last_seen_at': '2026-11-03T09:00:00+06:00'},
        {'id': 'legacy', 'kind': 'legacy', 'created_at': '2026-10-01T09:00:00+06:00'},
      ],
      'nudge': {'show': true, 'stage': 0},
      'email_change_blocked': '',
      'phone_change_blocked': 'identity_cooldown',
      'recovery_requests': [{'id': 4, 'contact_masked': 'x', 'hold_until': '2026-11-05T10:00:00+06:00'}],
      'family_requests': [],
    });
    expect(s.devices.length, 2);
    expect(s.devices.first.current, isTrue);
    expect(s.nudge, isTrue);
    expect(s.blockedReason, 'identity_cooldown');
    expect(s.myRecoveryRequests.single.id, 4);
    expect(s.googleAvailable, isFalse);
  });
}
