// gap-recovery (board row 52) — account recovery after a lost phone.
//  * wrong code / lockout / long resend wait: UI digits (the int ARB
//    placeholders printed "আর 4 বার", "30 মিনিট", "1800 সেকেন্ড" in Bangla);
//  * "Is your old phone lost?" after a code sign-in: shown only while other
//    phones are signed in; one tap signs them out; "No" keeps them; an
//    honest error when the server fails; bn/en, dark, 200 % text.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/account_security_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/otp_api.dart';
import 'package:assisto/screens/lost_phone_check_screen.dart';
import 'package:assisto/screens/otp/otp_verify_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_account_security.dart';
import 'fake_api.dart';
import 'fake_otp.dart';

final _nav = GlobalKey<NavigatorState>();

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
        navigatorKey: _nav,
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

Future<void> _typeCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('otp-code-field')), code);
  await _spin(tester, 6);
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

String _errText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('otp-error'))).data ?? '';

final _ascii = RegExp(r'[0-9]');

class _FailingSecurity extends FakeAccountSecurity {
  @override
  Future<OtpResult> signOutOthers() async {
    calls.add('signout-others');
    return OtpResult.fromRaw(const {'_status': 502, 'ok': false, 'reason': 'network'});
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('wrong code / lockout digits', () {
    testWidgets('bn: tries left + lockout minutes + long resend wait in Bangla digits',
        (tester) async {
      _tall(tester);
      final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
      await tester.pumpWidget(_app(
          OtpVerifyScreen(
              backend: b, purpose: 'login', email: 'rahim@example.com', emailFirst: true, title: 'T'),
          locale: const Locale('bn')));
      await _spin(tester);
      final t = _t(tester);
      await _typeCode(tester, '000000');
      expect(_errText(tester), t.recovOtpInvalid('৪'));
      expect(_errText(tester).contains(_ascii), isFalse);
      for (var i = 0; i < 4; i++) {
        await _typeCode(tester, '000000');
      }
      expect(_errText(tester), t.recovOtpLocked('৩০'));
      expect(_errText(tester).contains(_ascii), isFalse);
      // the resend button counts minutes, not "1800 seconds"
      final resend = find.byKey(const Key('otp-resend'));
      final label = tester
          .widget<Text>(find.descendant(of: resend, matching: find.byType(Text)))
          .data!;
      expect(label, t.recovResendInMin('৩০'));
      expect(tester.widget<TextButton>(resend).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('en: ASCII digits, same keys', (tester) async {
      _tall(tester);
      final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
      await tester.pumpWidget(_app(OtpVerifyScreen(
          backend: b, purpose: 'login', email: 'rahim@example.com', emailFirst: true, title: 'T')));
      await _spin(tester);
      final t = _t(tester);
      await _typeCode(tester, '000000');
      expect(_errText(tester), t.recovOtpInvalid('4'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the right code after a wrong one still signs in (proof returned)',
        (tester) async {
      _tall(tester);
      final b = FakeOtpBackend(smsEnabled: false, emailEnabled: true);
      String? proof;
      await tester.pumpWidget(_app(Builder(
          builder: (c) => Scaffold(
                body: Center(
                  child: TextButton(
                      onPressed: () async => proof = await OtpVerifyScreen.run(c,
                          backend: b,
                          purpose: 'login',
                          email: 'rahim@example.com',
                          emailFirst: true,
                          title: 'T'),
                      child: const Text('go')),
                ),
              ))));
      await tester.tap(find.text('go'));
      await _spin(tester);
      await _typeCode(tester, '000000');
      expect(find.byKey(const Key('otp-error')), findsOneWidget);
      await _typeCode(tester, b.goodCode);
      await _spin(tester);
      expect(proof, 'proof-login');
      expect(b.calls.where((c) => c.startsWith('verify:login')).length, 2);
    });
  });

  group('Is your old phone lost?', () {
    Future<FakeAccountSecurity> show(WidgetTester tester, FakeAccountSecurity sec,
        {Locale locale = const Locale('en'), bool dark = false, double scale = 1}) async {
      _tall(tester);
      await tester.pumpWidget(_app(const Scaffold(body: Text('home')),
          locale: locale, dark: dark, scale: scale));
      await _spin(tester, 3);
      // ignore: unawaited_futures
      LostPhoneCheckScreen.maybeShow(_nav.currentState!, sec);
      await _spin(tester);
      return sec;
    }

    testWidgets('other phones signed in -> screen; one tap signs them out', (tester) async {
      final sec = await show(tester, FakeAccountSecurity());
      final t = _t(tester);
      expect(find.byKey(const Key('lost-check')), findsOneWidget);
      expect(find.text('Samsung Galaxy'), findsOneWidget);
      expect(find.text(t.acsecOlderApp), findsOneWidget);
      expect(find.text('Realme Narzo'), findsNothing); // this phone is not listed
      await tester.tap(find.byKey(const Key('lost-signout-all')));
      await _spin(tester);
      expect(sec.calls, contains('signout-others'));
      expect(find.byKey(const Key('lost-check')), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only this phone -> nothing is shown', (tester) async {
      final sec = FakeAccountSecurity(
          state: AccountSecurity(phone: '+8801712345678', phoneVerified: true, devices: [
        SignedInDevice(id: 's1', name: 'Realme Narzo', current: true, lastSeen: DateTime(2026, 11, 3)),
      ]));
      await show(tester, sec);
      expect(find.byKey(const Key('lost-check')), findsNothing);
      expect(sec.calls, ['load']);
    });

    testWidgets('"No" keeps the other phones signed in', (tester) async {
      final sec = await show(tester, FakeAccountSecurity());
      await tester.tap(find.byKey(const Key('lost-keep')));
      await _spin(tester);
      expect(sec.calls, isNot(contains('signout-others')));
      expect(find.byKey(const Key('lost-check')), findsNothing);
    });

    testWidgets('server failure -> honest error, screen stays, retry possible', (tester) async {
      final sec = await show(tester, _FailingSecurity());
      final t = _t(tester);
      await tester.tap(find.byKey(const Key('lost-signout-all')));
      await _spin(tester);
      expect(find.byKey(const Key('lost-check')), findsOneWidget);
      expect(find.text(t.recovLostFailed), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('lost-signout-all'))).onPressed,
          isNotNull);
      expect(sec.calls.where((c) => c == 'signout-others').length, 1);
    });

    testWidgets('bn + dark + 200 % text: Bangla digits, no overflow, 48 dp buttons',
        (tester) async {
      await show(tester, FakeAccountSecurity(),
          locale: const Locale('bn'), dark: true, scale: 2);
      final t = _t(tester);
      expect(find.text(t.recovLostTitle), findsOneWidget);
      final sub = tester
          .widget<ListTile>(find.byKey(const Key('lost-device-s2')))
          .subtitle as Text;
      expect(sub.data!.contains(_ascii), isFalse);
      for (final k in ['lost-signout-all', 'lost-keep']) {
        final sz = tester.getSize(find.byKey(Key(k)));
        expect(sz.height >= 48, isTrue, reason: k);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
