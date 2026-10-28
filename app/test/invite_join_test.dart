// invite-join — link parsing, install referrer (mocked channel), the join
// screen in every state (signed out / in, SMS on / off, email fallback,
// expired, offline, already, server error), bn/en, the inviter share sheet
// and the "invited, not joined yet" list.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/invite/invite_join_screen.dart';
import 'package:assisto/invite/invite_link.dart';
import 'package:assisto/invite/invite_router.dart';
import 'package:assisto/invite/invite_share_sheet.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

import 'fake_invite.dart';
import 'fake_otp.dart';

const _code = 'K7QF2M9PAB';

AppState _app({bool signedIn = false, String lang = 'en'}) {
  final s = AppState()
    ..locale = Locale(lang)
    ..loading = false;
  if (signedIn) {
    s.api.token = 't';
    s.user = AppUser(
        id: 1, name: 'B', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  }
  return s;
}

Widget _wrap(Widget child, {AppState? app, String lang = 'en', double scale = 1}) {
  return ChangeNotifierProvider<AppState>.value(
    value: app ?? _app(lang: lang),
    child: MaterialApp(
      locale: Locale(lang),
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
      home: child,
    ),
  );
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PendingInvite.resetForTest();
  });

  group('InviteLink', () {
    test('codeFrom accepts our forms only', () {
      for (final raw in [
        _code,
        _code.toLowerCase(),
        'https://lifeassisto.com/i/$_code',
        'https://www.lifeassisto.com/i/$_code?utm=x',
        '/i/$_code',
        '/i/$_code/',
      ]) {
        expect(InviteLink.codeFrom(raw), _code, reason: raw);
      }
      for (final raw in [
        '',
        'K7QF2M9PA', // 9
        'K7QF2M9PAB1', // 11
        'O0I1O0I1O0', // excluded letters
        'https://evil.example/i/$_code',
        '12.friend.99.x.sig',
      ]) {
        expect(InviteLink.codeFrom(raw), isNull, reason: raw);
      }
    });

    test('referral codes on /i/ are kept apart', () {
      expect(InviteLink.referralFrom('https://lifeassisto.com/i/K7QF2M9P'), 'K7QF2M9P');
      expect(InviteLink.referralFrom('https://lifeassisto.com/i/$_code'), isNull);
      expect(InviteLink.referralFrom('/photo/app?t=x'), isNull);
    });

    test('Play referrer string', () {
      final a = InviteLink.fromReferrer('ci=$_code&utm_source=google-play');
      expect(a.circle, _code);
      expect(a.referral, isNull);
      final b = InviteLink.fromReferrer('ref=k7qf2m9p');
      expect(b.circle, isNull);
      expect(b.referral, 'K7QF2M9P');
      final c = InviteLink.fromReferrer('utm_source=google-play&utm_medium=organic');
      expect(c.circle, isNull);
      expect(InviteLink.fromReferrer(null).circle, isNull);
    });
  });

  group('PendingInvite', () {
    test('takeLink stores the code (and persists it)', () async {
      expect(PendingInvite.takeLink('https://lifeassisto.com/i/$_code'), isTrue);
      expect(PendingInvite.code.value, _code);
      await Future<void>.delayed(Duration.zero);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('ij_pending_code'), _code);
      // a new launch restores it
      await PendingInvite.resetForTest();
      await PendingInvite.load();
      expect(PendingInvite.code.value, _code);
    });

    test('an old saved code (> 7 days) is dropped', () async {
      SharedPreferences.setMockInitialValues({
        'ij_pending_code': _code,
        'ij_pending_at': DateTime.now()
            .subtract(const Duration(days: 8))
            .millisecondsSinceEpoch,
      });
      await PendingInvite.load();
      expect(PendingInvite.code.value, isNull);
    });

    test('install referrer read once per install, mocked channel', () async {
      const ch = MethodChannel('test/install_referrer');
      var asked = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        asked++;
        return 'ci=$_code&utm_source=google-play';
      });
      expect(await PendingInvite.readReferrerOnce(channel: ch), _code);
      expect(PendingInvite.code.value, _code);
      expect(PendingInvite.via, 'referrer');
      expect(await PendingInvite.readReferrerOnce(channel: ch), isNull);
      expect(asked, 1);
    });

    test('missing native channel never throws', () async {
      expect(await PendingInvite.readReferrerOnce(
              channel: const MethodChannel('test/none')),
          isNull);
      expect(PendingInvite.code.value, isNull);
    });

    test('warm App Link route only records the code', () {
      final r = InviteRouter.route(const RouteSettings(name: '/i/$_code'));
      expect(r, isNotNull);
      expect(PendingInvite.code.value, _code);
      expect(InviteRouter.route(const RouteSettings(name: '/photo/app?t=x')), isNull);
    });
  });

  group('Join screen — signed out', () {
    testWidgets('SMS off: name + phone + Join = account + joined, no password',
        (tester) async {
      _tall(tester);
      final b = FakeInviteBackend();
      Map<String, dynamic>? joined;
      String? adoptedToken;
      await tester.pumpWidget(_wrap(InviteJoinScreen(
        code: _code,
        asRoot: true,
        backend: b,
        adopt: (tok, u) async => adoptedToken = tok,
        onJoined: (m, n) => joined = m,
      )));
      await _settle(tester);
      expect(find.text("Join Rahim's circle"), findsWidgets);
      expect(find.text('No password needed.'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2)); // name + phone, nothing else
      await tester.enterText(find.byKey(const Key('ij-name')), 'Nasima');
      await tester.enterText(find.byKey(const Key('ij-phone')), '01711000410');
      await tester.tap(find.byKey(const Key('ij-join')));
      await _settle(tester);
      expect(b.lastSignup!['name'], 'Nasima');
      expect(b.lastSignup!['phone'], '01711000410');
      expect(b.lastSignup!['otp_proof'], isNull);
      expect(adoptedToken, 'tok-123');
      expect(joined!['state'], 'accepted');
      expect(PendingInvite.code.value, isNull);
    });

    testWidgets('validation: name and a real BD mobile', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend();
      await tester.pumpWidget(_wrap(InviteJoinScreen(
          code: _code, asRoot: true, backend: b, adopt: (_, __) async {})));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('ij-join')));
      await _settle(tester);
      expect(find.text('Please type your name.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('ij-name')), 'N');
      await tester.enterText(find.byKey(const Key('ij-phone')), '12345');
      await tester.tap(find.byKey(const Key('ij-join')));
      await _settle(tester);
      expect(find.byKey(const Key('ij-error')), findsOneWidget);
      expect(b.lastSignup, isNull);
    });

    testWidgets('SMS on: one OTP step, proof sent with the sign-up', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend(smsEnabled: true);
      final otp = FakeOtpBackend(smsEnabled: true);
      var done = false;
      await tester.pumpWidget(_wrap(InviteJoinScreen(
          code: _code,
          asRoot: true,
          backend: b,
          otpBackend: otp,
          adopt: (_, __) async {},
          onJoined: (_, __) => done = true)));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('ij-name')), 'Nasima');
      await tester.enterText(find.byKey(const Key('ij-phone')), '01711000410');
      await tester.tap(find.byKey(const Key('ij-join')));
      await _settle(tester);
      expect(otp.calls, contains('request:signup'));
      await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
      await _settle(tester);
      await _settle(tester);
      expect(b.lastSignup!['otp_proof'], 'proof-signup');
      expect(done, isTrue);
    });

    testWidgets('SMS fails -> continue with email', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend(smsEnabled: true);
      await tester.pumpWidget(_wrap(InviteJoinScreen(
          code: _code,
          asRoot: true,
          backend: b,
          adopt: (_, __) async {},
          onJoined: (_, __) {})));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('ij-switch-email')));
      await _settle(tester);
      expect(find.byKey(const Key('ij-phone')), findsNothing);
      await tester.enterText(find.byKey(const Key('ij-name')), 'Nasima');
      await tester.enterText(find.byKey(const Key('ij-email')), 'n@example.com');
      await tester.tap(find.byKey(const Key('ij-join')));
      await _settle(tester);
      expect(b.lastSignup!['email'], 'n@example.com');
      expect(b.lastSignup!['phone'], '');
      expect(b.lastSignup!['otp_proof'], isNull);
    });

    testWidgets('server refusal is shown, nothing adopted', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend(signupReason: 'has_account');
      var adopted = false;
      await tester.pumpWidget(_wrap(InviteJoinScreen(
          code: _code, asRoot: true, backend: b, adopt: (_, __) async => adopted = true)));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('ij-name')), 'N');
      await tester.enterText(find.byKey(const Key('ij-phone')), '01711000401');
      await tester.tap(find.byKey(const Key('ij-join')));
      await _settle(tester);
      expect(find.textContaining('already has an account'), findsOneWidget);
      expect(adopted, isFalse);
    });

    testWidgets('expired / used / invalid show the honest text', (tester) async {
      for (final st in ['expired', 'used', 'invalid']) {
        await tester.pumpWidget(_wrap(InviteJoinScreen(
            key: ValueKey(st), code: _code, asRoot: true,
            backend: FakeInviteBackend(state: st))));
        await _settle(tester);
        expect(find.byKey(const Key('ij-problem')), findsOneWidget, reason: st);
        expect(find.text("This invite can't be used"), findsOneWidget);
        expect(find.byKey(const Key('ij-name')), findsNothing);
      }
    });

    testWidgets('offline -> Retry -> loads', (tester) async {
      final b = FakeInviteBackend(state: 'offline');
      await tester.pumpWidget(_wrap(InviteJoinScreen(code: _code, asRoot: true, backend: b)));
      await _settle(tester);
      expect(find.byKey(const Key('ij-offline')), findsOneWidget);
      b.state = 'ok';
      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(find.byKey(const Key('ij-name')), findsOneWidget);
    });

    testWidgets('Bangla: title, labels and digits', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(
          InviteJoinScreen(
              code: _code, asRoot: true, backend: FakeInviteBackend(inviter: 'রহিম')),
          lang: 'bn'));
      await _settle(tester);
      expect(find.text('রহিম-এর সার্কেলে যোগ দিন'), findsWidgets);
      expect(find.text('যোগ দিন'), findsOneWidget);
      expect(find.text('কোনো পাসওয়ার্ড লাগবে না।'), findsOneWidget);
      expect(find.text('যেমন: ০১৭১২৩৪৫৬৭৮'), findsOneWidget);
      expect(find.text('English'), findsOneWidget); // language switch
    });

    testWidgets('200% font: no overflow, still scrollable', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(
          InviteJoinScreen(code: _code, asRoot: true, backend: FakeInviteBackend()),
          scale: 2.0));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.byKey(const Key('ij-join')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const Key('ij-join')), findsOneWidget);
    });

    testWidgets('a11y: 48dp targets + labels', (tester) async {
      _tall(tester);
      final h = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(
          InviteJoinScreen(code: _code, asRoot: true, backend: FakeInviteBackend())));
      await _settle(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      h.dispose();
    });
  });

  group('Join screen — signed in', () {
    testWidgets('one tap Join', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend();
      Map<String, dynamic>? joined;
      await tester.pumpWidget(_wrap(
          InviteJoinScreen(code: _code, backend: b, onJoined: (m, _) => joined = m),
          app: _app(signedIn: true)));
      await _settle(tester);
      expect(find.byKey(const Key('ij-name')), findsNothing);
      await tester.tap(find.byKey(const Key('ij-join')));
      await _settle(tester);
      expect(b.calls, contains('join:$_code:link'));
      expect(joined, isNotNull);
    });

    testWidgets('already in the circle -> Open chat', (tester) async {
      final b = FakeInviteBackend(state: 'already');
      var opened = false;
      await tester.pumpWidget(_wrap(
          InviteJoinScreen(code: _code, backend: b, onJoined: (_, __) => opened = true),
          app: _app(signedIn: true)));
      await _settle(tester);
      expect(find.byKey(const Key('ij-already')), findsOneWidget);
      await tester.tap(find.text('Open chat'));
      await _settle(tester);
      expect(opened, isTrue);
    });

    testWidgets('own invite -> honest message', (tester) async {
      await tester.pumpWidget(_wrap(
          InviteJoinScreen(code: _code, backend: FakeInviteBackend(state: 'self')),
          app: _app(signedIn: true)));
      await _settle(tester);
      expect(find.textContaining('your own invite'), findsOneWidget);
    });
  });

  group('Inviter', () {
    testWidgets('WhatsApp: one invite made, wa.me with the Bangla text', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend();
      final launched = <Uri>[];
      await tester.pumpWidget(_wrap(Scaffold(
          body: InviteShareSheet(
              backend: b, launcher: (u) async {
                launched.add(u);
                return true;
              }, sharer: (_) async {}))));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('ij-label')), 'Ammu');
      await tester.tap(find.byKey(const Key('ij-via-whatsapp')));
      await _settle(tester);
      expect(b.calls.where((c) => c.startsWith('create')).toList(),
          ['create:friend:Ammu:1']);
      expect(launched.single.host, 'wa.me');
      expect(Uri.decodeComponent(launched.single.query), contains('lifeassisto.com/i/K7QF2M9PAB'));
      expect(find.byKey(const Key('ij-preview')), findsOneWidget);
      // SMS reuses the SAME invite
      await tester.tap(find.byKey(const Key('ij-via-sms')));
      await _settle(tester);
      expect(launched.last.scheme, 'sms');
      expect(b.calls.where((c) => c.startsWith('create')).length, 1);
    });

    testWidgets('family group link = up to 10 uses; more = share sheet', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend();
      final shared = <String>[];
      await tester.pumpWidget(_wrap(Scaffold(
          body: InviteShareSheet(
              backend: b, launcher: (_) async => true, sharer: (s) async => shared.add(s)))));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('ij-group')));
      await tester.tap(find.byKey(const Key('ij-via-more')));
      await _settle(tester);
      expect(b.calls.first, 'create:friend::10');
      expect(shared.single, contains('lifeassisto.com/i/'));
    });

    testWidgets('invited, not joined yet: statuses + revoke', (tester) async {
      _tall(tester);
      final b = FakeInviteBackend(sent: fakeSentRows('en'));
      await tester.pumpWidget(_wrap(InviteSentScreen(backend: b)));
      await _settle(tester);
      expect(find.text('Joined: Nasima'), findsOneWidget);
      expect(find.text('Not joined yet'), findsOneWidget);
      expect(find.text('Link expired — send it again'), findsOneWidget);
      expect(find.byKey(const Key('ij-resend-1')), findsNothing); // joined: no resend
      await tester.tap(find.byKey(const Key('ij-revoke-2')));
      await _settle(tester);
      expect(b.calls, contains('revoke:2'));
    });

    testWidgets('sent list offline -> retry', (tester) async {
      final b = FakeInviteBackend(state: 'offline');
      await tester.pumpWidget(_wrap(InviteSentScreen(backend: b)));
      await _settle(tester);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
