// o1-otp — widget tests for every OTP screen flow against a fake backend.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/otp_api.dart';
import 'package:assisto/screens/delete_account_screen.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/screens/otp/otp_login_screen.dart';
import 'package:assisto/screens/otp/otp_verify_screen.dart';
import 'package:assisto/screens/password_reset_screen.dart';
import 'package:assisto/services/security_guard.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/otp_code_input.dart';

import 'fake_api.dart';
import 'fake_otp.dart';

/// FakeApi that records sign-up / delete-account calls instead of networking.
class _RecApi extends FakeApi {
  String? registerProof;
  String? registerPhone;
  final List<String?> deleteProofs = [];
  final List<String?> secProofs = [];

  @override
  Future<Map<String, dynamic>> securityAction(String action, String pin,
      {double? lat, double? lng, String? otpProof}) async {
    secProofs.add(otpProof);
    if (otpProof == null) {
      return {'ok': false, 'reason': 'otp_required', 'purpose': 'section8', '_status': 403};
    }
    return {'state': 'applied', 'id': null};
  }
  _RecApi() : super(lang: 'en');

  @override
  Future<({String token, AppUser user})> register({
    required String name,
    String? phone,
    String? email,
    required String password,
    String? otpProof,
  }) async {
    registerProof = otpProof;
    registerPhone = phone;
    // Stop before AppState touches secure storage in the test VM.
    throw ApiException('register-recorded', 418);
  }

  @override
  Future<Map<String, dynamic>> accountDeleteStatus() async => {'state': null};
  @override
  Future<Map<String, dynamic>> securityState() async => {'has_pin': false};
  @override
  Future<Map<String, dynamic>> accountDeletePreview() async =>
      {'counts': {'notes': 2}, 'export_downloaded': true};

  @override
  Future<Map<String, dynamic>> accountDeleteRequest({
    required String password,
    String? otp,
    String? otpProof,
    String? securityPin,
    double? lat,
    double? lng,
  }) async {
    deleteProofs.add(otpProof);
    if (otpProof == null) {
      return {'ok': false, 'reason': 'otp_required', '_status': 403};
    }
    return {
      'state': 'pending',
      'effective_at': '2026-10-28T10:00:00Z',
      'id': 1,
    };
  }
}

AppState _state(ApiClient api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _wrap(Widget child, {ApiClient? api}) {
  return ChangeNotifierProvider<AppState>.value(
    value: _state(api ?? _RecApi()),
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    ),
  );
}

/// A tiny host that pushes the verify step and shows what it popped with.
class _Host extends StatefulWidget {
  final OtpBackend backend;
  const _Host(this.backend);
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
                    purpose: 'login',
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

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _spin(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _typeCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('otp-code-field')), code);
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });
  setUp(() {
    // Plugin channels never answer in the test VM: location off, no biometric.
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async => call.method == 'isLocationServiceEnabled' ? false : null);
    m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/local_auth'),
        (call) async => false);
  });

  testWidgets('code input: 6 boxes, digits only, max 6, fits 360px',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = TextEditingController();
    String? done;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Padding(
                padding: const EdgeInsets.all(24),
                child: OtpCodeInput(controller: c, onCompleted: (v) => done = v)))));
    await tester.enterText(find.byKey(const Key('otp-code-field')), '12a3456789');
    await tester.pump();
    expect(c.text, '123456');
    expect(done, '123456');
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(find.byKey(const Key('otp-code-field')));
    expect(field.autofillHints, contains(AutofillHints.oneTimeCode));
  });

  testWidgets('verify: sends on open, shows masked number + resend timer, pops proof',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    await tester.pumpWidget(_wrap(_Host(b)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(b.calls, contains('request:login'));
    expect(find.textContaining('017•••••678'), findsOneWidget);
    expect(find.text('Resend code in 60s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Resend code in 57s'), findsOneWidget);
    await _typeCode(tester, '123456');
    await tester.pumpAndSettle();
    expect(find.text('result:proof-login'), findsOneWidget);
  });

  testWidgets('verify: wrong code shows attempts left, then lockout', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(attemptsLeft: 2);
    await tester.pumpWidget(_wrap(_Host(b)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _typeCode(tester, '000000');
    await tester.pump();
    expect(find.text("That code didn't match. 1 tries left."), findsOneWidget);
    await _typeCode(tester, '000000');
    await tester.pump();
    expect(find.text('Too many wrong codes. Please try again in 30 min.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('verify: resend enabled after the countdown', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    await tester.pumpWidget(_wrap(_Host(b)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(find.byKey(const Key('otp-resend'))).onPressed, isNull);
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('Resend code'), findsOneWidget);
    await tester.tap(find.byKey(const Key('otp-resend')));
    await tester.pumpAndSettle();
    expect(b.calls.where((c) => c == 'request:login').length, 2);
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('verify: SMS not configured -> honest state, pops null', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false);
    await tester.pumpWidget(_wrap(_Host(b)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text("SMS codes aren't available yet"), findsOneWidget);
    expect(find.byKey(const Key('otp-code-field')), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('result:null'), findsOneWidget);
  });

  testWidgets('login with SMS: bad number rejected; good flow calls login with proof',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    await tester.pumpWidget(_wrap(OtpLoginScreen(backend: b)));
    await tester.enterText(find.byKey(const Key('otp-phone')), '12345');
    await tester.tap(find.byKey(const Key('otp-send')));
    await tester.pump();
    expect(find.textContaining('valid Bangladeshi mobile'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('otp-phone')), '+8801712345678');
    await tester.tap(find.byKey(const Key('otp-send')));
    await tester.pumpAndSettle();
    await _typeCode(tester, '123456');
    await tester.pumpAndSettle();
    expect(b.calls, contains('login:+8801712345678:proof-login'));
    // fake login refuses -> honest error, still on the screen
    expect(find.text("Couldn't sign in with that code. Please try again."), findsOneWidget);
  });

  testWidgets('login screen offers "Sign in with an SMS code"', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    await tester.pumpWidget(_wrap(LoginScreen(otpBackend: b)));
    await tester.tap(find.byKey(const Key('login-with-sms')));
    await tester.pumpAndSettle();
    expect(find.byType(OtpLoginScreen), findsOneWidget);
  });

  Future<void> openRegister(WidgetTester tester, OtpBackend b, ApiClient api) async {
    await tester.pumpWidget(_wrap(LoginScreen(otpBackend: b), api: api));
    await tester.tap(find.text('New here? Create a profile'));
    await tester.pump();
  }

  testWidgets('sign-up with SMS on: phone verified first, proof sent to register',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    final api = _RecApi();
    await openRegister(tester, b, api);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Nadia');
    await tester.enterText(fields.at(1), '01712345678');
    await tester.enterText(fields.at(3), 'pw123456');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(b.calls, contains('request:signup'));
    await _typeCode(tester, '123456');
    await tester.pumpAndSettle();
    expect(api.registerProof, 'proof-signup');
    expect(api.registerPhone, '01712345678');
  });

  testWidgets('sign-up with gate OFF and SMS off: honest refusal, no register call',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false, passwordOnlySignup: false);
    final api = _RecApi();
    await openRegister(tester, b, api);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(2), 'a@b.co');
    await tester.enterText(fields.at(3), 'pw123456');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't available right now"), findsOneWidget);
    expect(api.registerProof, isNull);
    expect(api.registerPhone, isNull);
  });

  testWidgets('sign-up with SMS off and gate ON: password-only path unchanged',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false);
    final api = _RecApi();
    await openRegister(tester, b, api);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), '01712345678');
    await tester.enterText(fields.at(3), 'pw123456');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(b.calls, isNot(contains('request:signup')));
    expect(api.registerPhone, '01712345678');
    expect(api.registerProof, isNull);
  });

  testWidgets('forgot password: SMS tile live when connected -> code -> new password',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    await tester.pumpWidget(_wrap(PasswordResetScreen(otpBackend: b)));
    await tester.pumpAndSettle();
    expect(find.text('Get a code by SMS on your registered number'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reset-sms-tile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('otp-phone')), '01712345678');
    await tester.tap(find.byKey(const Key('otp-send')));
    await tester.pumpAndSettle();
    expect(b.lastPurpose, 'password_reset');
    await _typeCode(tester, '123456');
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byKey(const Key('otp-new-password')), matching: find.byType(TextField)),
        'newpass123');
    await tester.tap(find.byKey(const Key('otp-save-password')));
    await tester.pumpAndSettle();
    expect(b.calls, contains('reset:01712345678:proof-password_reset'));
    expect(b.lastResetPassword, 'newpass123');
    expect(find.textContaining('Password changed'), findsOneWidget);
  });

  testWidgets('forgot password: SMS tile stays locked when SMS off', (tester) async {
    _tall(tester);
    final b = FakeOtpBackend(smsEnabled: false);
    await tester.pumpWidget(_wrap(PasswordResetScreen(otpBackend: b)));
    await tester.pumpAndSettle();
    expect(find.text('Get a code by SMS on your registered number'), findsNothing);
  });

  testWidgets('delete account: server asks for OTP -> code step -> resubmits with proof',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    final api = _RecApi();
    await tester.pumpWidget(_wrap(DeleteAccountScreen(otpBackend: b), api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).last); // Continue
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'x123456');
    await tester.pump();
    final submit = find.byType(FilledButton).last;
    await tester.tap(submit);
    await _spin(tester);
    expect(b.lastPurpose, 'delete_account');
    expect(b.lastPhone, isNull); // server uses the account's own number
    await _typeCode(tester, '123456');
    await _spin(tester);
    expect(api.deleteProofs, [null, 'proof-delete_account']);
  });

  testWidgets('Section 8: PIN -> server asks OTP -> code -> retried with proof',
      (tester) async {
    _tall(tester);
    final b = FakeOtpBackend();
    final api = _RecApi();
    SecActionResult? res;
    await tester.pumpWidget(_wrap(Builder(
        builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    res = await SecurityGuard(otpBackend: b).run(ctx, 'disarm');
                  },
                  child: const Text('go'),
                ),
              ),
            )), api: api));
    await tester.tap(find.text('go'));
    await _spin(tester);
    await tester.enterText(
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '4321');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await _spin(tester);
    expect(b.lastPurpose, 'section8');
    await _typeCode(tester, '123456');
    await _spin(tester);
    expect(api.secProofs, [null, 'proof-section8']);
    expect(res?.state, SecActionState.applied);
  });
}
