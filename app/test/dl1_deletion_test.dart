// dl1 — account-deletion UX: the sign-in grace screen (Restore / Delete now
// and start fresh), the already-pending message, "Cancel deletion" from
// Settings and from the delete screen, and the honest "deleting does not fix
// app problems" guidance with Send feedback / Contact support.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/delete_account_screen.dart';
import 'package:assisto/screens/deletion_grace_screen.dart';
import 'package:assisto/screens/settings_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/plans_compare_table.dart';

import 'fake_api.dart';
import 'fake_otp.dart';

class _DelApi extends FakeApi {
  _DelApi({this.pending = false, this.startFreshReplies = const []})
      : super(lang: 'en');
  bool pending;
  int cancels = 0;
  final List<Map<String, dynamic>> startFreshReplies;
  final List<Map<String, String?>> startFreshCalls = [];

  @override
  Future<Map<String, dynamic>> accountDeleteStatus() async => pending
      ? {'state': 'pending', 'effective_at': '2026-10-29T10:00:00Z'}
      : {'state': null};

  @override
  Future<Map<String, dynamic>> accountDeleteCancel({String? token}) async {
    cancels++;
    pending = false;
    return {'ok': true, 'state': 'cancelled'};
  }

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
  }) async =>
      {
        'state': 'pending',
        'effective_at': '2026-10-29T10:00:00Z',
        'id': 7,
        'already_pending': true,
      };

  @override
  Future<Map<String, dynamic>> accountStartFresh({
    required String password,
    required String confirmText,
    String? otpProof,
  }) async {
    startFreshCalls.add(
        {'password': password, 'confirm': confirmText, 'proof': otpProof});
    final i = startFreshCalls.length - 1;
    return startFreshReplies[i < startFreshReplies.length
        ? i
        : startFreshReplies.length - 1];
  }
}

/// AppState that records the start-fresh hand-over instead of touching
/// secure storage / sqlite in the test VM.
class _State extends AppState {
  String? adoptedToken;
  @override
  Future<void> adoptFreshAccount(String token, AppUser fresh) async {
    adoptedToken = token;
    clearDeletionGrace();
  }
}

_State _state(ApiClient api, {bool grace = false, bool otp = false}) {
  final s = _State();
  s.api = api;
  s.user = AppUser(
      id: 1,
      name: 'A',
      phone: '01712345678',
      email: '',
      autonomyLevel: 2,
      language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  if (grace) {
    s.deletionGraceAt = DateTime(2026, 10, 29);
    s.deletionGraceOtp = otp;
  }
  return s;
}

Widget _wrap(Widget child, AppState s) => ChangeNotifierProvider<AppState>.value(
      value: s,
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

AppLocalizations _t(WidgetTester tester, Type type) =>
    AppLocalizations.of(tester.element(find.byType(type)));

final _when = DateFormat.yMMMMd('en')
    .add_jm()
    .format(DateTime.parse('2026-10-29T10:00:00Z').toLocal());

final _freshOk = {
  'ok': true,
  'start_fresh': true,
  'token': 'new-token',
  'user': {
    'id': 2,
    'name': 'A',
    'phone': '01712345678',
    'email': '',
    'autonomy_level': 2,
    'language': 'en',
  },
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('sign-in grace screen', () {
    testWidgets('Restore account cancels the deletion and continues',
        (tester) async {
      _tall(tester);
      final api = _DelApi(pending: true);
      final s = _state(api, grace: true);
      await tester.pumpWidget(_wrap(const DeletionGraceScreen(), s));
      await tester.pumpAndSettle();
      final t = _t(tester, DeletionGraceScreen);
      expect(find.text(t.dlGraceTitle), findsOneWidget);
      expect(find.textContaining('2026'), findsWidgets); // the date is shown
      await tester.tap(find.byKey(const Key('dl-grace-restore')));
      await _spin(tester);
      expect(api.cancels, 1);
      expect(s.deletionGraceAt, isNull);
    });

    testWidgets('Delete now: honest no-SMS note, needs password + DELETE',
        (tester) async {
      _tall(tester);
      final api = _DelApi(pending: true, startFreshReplies: [_freshOk]);
      final s = _state(api, grace: true);
      await tester.pumpWidget(_wrap(const DeletionGraceScreen(), s));
      await tester.pumpAndSettle();
      final t = _t(tester, DeletionGraceScreen);
      await tester.tap(find.byKey(const Key('dl-grace-fresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dl-grace-confirm')), findsOneWidget);
      expect(find.text(t.dlGraceOtpOff), findsOneWidget);
      FilledButton go() => tester
          .widget<FilledButton>(find.byKey(const Key('dl-grace-fresh-go')));
      expect(go().onPressed, isNull);
      await tester.enterText(
          find.descendant(
              of: find.byKey(const Key('dl-grace-password')),
              matching: find.byType(TextField)),
          'x123456');
      await tester.pump();
      expect(go().onPressed, isNull); // still needs the typed word
      await tester.enterText(find.byKey(const Key('dl-grace-typed')), 'delete');
      await tester.pump();
      expect(go().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('dl-grace-fresh-go')));
      await _spin(tester);
      expect(api.startFreshCalls.single['confirm'], 'delete');
      expect(api.startFreshCalls.single['password'], 'x123456');
      expect(s.adoptedToken, 'new-token');
      expect(s.deletionGraceAt, isNull);
    });

    testWidgets('Delete now with SMS on: code step, then resubmits with proof',
        (tester) async {
      _tall(tester);
      final b = FakeOtpBackend();
      final api = _DelApi(pending: true, startFreshReplies: [
        {'ok': false, 'reason': 'otp_required', '_status': 403},
        _freshOk,
      ]);
      final s = _state(api, grace: true, otp: true);
      await tester.pumpWidget(_wrap(DeletionGraceScreen(otpBackend: b), s));
      await tester.pumpAndSettle();
      final t = _t(tester, DeletionGraceScreen);
      await tester.tap(find.byKey(const Key('dl-grace-fresh')));
      await tester.pumpAndSettle();
      expect(find.text(t.dlGraceOtpOn), findsOneWidget);
      await tester.enterText(
          find.descendant(
              of: find.byKey(const Key('dl-grace-password')),
              matching: find.byType(TextField)),
          'x123456');
      await tester.enterText(find.byKey(const Key('dl-grace-typed')), 'DELETE');
      await tester.pump();
      await tester.tap(find.byKey(const Key('dl-grace-fresh-go')));
      await _spin(tester);
      expect(b.lastPurpose, 'delete_account');
      await tester.enterText(find.byKey(const Key('otp-code-field')), '123456');
      await tester.pump();
      await _spin(tester);
      expect(api.startFreshCalls.map((c) => c['proof']).toList(),
          [null, 'proof-delete_account']);
      expect(s.adoptedToken, 'new-token');
    });

    testWidgets('wrong password is said plainly, nothing deleted',
        (tester) async {
      _tall(tester);
      final api = _DelApi(pending: true, startFreshReplies: [
        {'ok': false, 'reason': 'bad_password', '_status': 403},
      ]);
      final s = _state(api, grace: true);
      await tester.pumpWidget(_wrap(const DeletionGraceScreen(), s));
      await tester.pumpAndSettle();
      final t = _t(tester, DeletionGraceScreen);
      await tester.tap(find.byKey(const Key('dl-grace-fresh')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(
              of: find.byKey(const Key('dl-grace-password')),
              matching: find.byType(TextField)),
          'nope');
      await tester.enterText(find.byKey(const Key('dl-grace-typed')), 'DELETE');
      await tester.pump();
      await tester.tap(find.byKey(const Key('dl-grace-fresh-go')));
      await _spin(tester);
      expect(find.text(t.delAcctBadPassword), findsOneWidget);
      expect(s.adoptedToken, isNull);
      expect(s.deletionGraceAt, isNotNull);
    });
  });

  group('delete account screen', () {
    testWidgets('already pending: says so with the date + Cancel deletion',
        (tester) async {
      _tall(tester);
      final api = _DelApi(pending: true);
      await tester.pumpWidget(_wrap(const DeleteAccountScreen(), _state(api)));
      await tester.pumpAndSettle();
      final t = _t(tester, DeleteAccountScreen);
      final body = tester.widget<Text>(
          find.byKey(const Key('del-acct-pending-body')));
      expect(body.data, t.delAcctAlreadyPending(_when));
      expect(find.text(t.delAcctCancelDeletion), findsOneWidget);
      await tester.tap(find.byKey(const Key('del-acct-cancel')));
      await _spin(tester);
      expect(api.cancels, 1);
      expect(find.text(t.delAcctCancelled), findsOneWidget);
    });

    testWidgets('a second request shows the already-scheduled message',
        (tester) async {
      _tall(tester);
      final api = _DelApi();
      await tester.pumpWidget(_wrap(const DeleteAccountScreen(), _state(api)));
      await tester.pumpAndSettle();
      final t = _t(tester, DeleteAccountScreen);
      await tester.ensureVisible(find.text(t.delAcctContinue));
      await tester.tap(find.text(t.delAcctContinue));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'x123456');
      await tester.pump();
      await tester.ensureVisible(find.text(t.delAcctScheduleDeletion));
      await tester.tap(find.text(t.delAcctScheduleDeletion));
      // The best-effort location lookup is a real platform call: let it
      // settle outside the fake clock.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await _spin(tester, 5);
      }
      final body = tester.widget<Text>(
          find.byKey(const Key('del-acct-pending-body')));
      expect(body.data, t.delAcctAlreadyPending(_when));
      expect(find.byKey(const Key('del-acct-cancel')), findsOneWidget);
    });

    testWidgets('honest guidance before confirming: feedback + support',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(
          _wrap(const DeleteAccountScreen(), _state(_DelApi())));
      await tester.pumpAndSettle();
      final t = _t(tester, DeleteAccountScreen);
      expect(find.byKey(const Key('del-acct-guidance')), findsOneWidget);
      expect(find.text(t.delAcctGuidanceBody), findsOneWidget);
      expect(find.text(t.delAcctSendFeedback), findsOneWidget);
      expect(find.text(t.delAcctContactSupport), findsOneWidget);
      // The guidance sits ABOVE the Continue button (seen before confirming).
      final g = tester.getTopLeft(find.byKey(const Key('del-acct-guidance')));
      final c = tester.getTopLeft(find.text(t.delAcctContinue));
      expect(g.dy, lessThan(c.dy));
      await tester.tap(find.byKey(const Key('del-acct-support')));
      await tester.pumpAndSettle();
      expect(find.byType(SupportScreen), findsOneWidget);
    });
  });

  testWidgets('Settings: Cancel deletion opens the screen with the button',
      (tester) async {
    _tall(tester);
    final api = _DelApi(pending: true);
    await tester.pumpWidget(_wrap(const SettingsScreen(), _state(api)));
    await _spin(tester);
    final t = _t(tester, SettingsScreen);
    final btn = find.byKey(const Key('settings-cancel-deletion'));
    expect(btn, findsOneWidget);
    expect(find.text(t.delAcctCancelDeletion), findsOneWidget);
    await tester.tap(btn);
    await _spin(tester);
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    await tester.tap(find.byKey(const Key('del-acct-cancel')));
    await _spin(tester);
    expect(api.cancels, 1);
  });

  test('the deletion notice routes to the Cancel deletion screen', () {
    expect(PushRouting.routeMap['account/delete'], 'account_delete');
    expect(ChatNav.accountDeleteRoute, 'account_delete');
    // never a chat / Discover target
    expect(ChatNav.routes.containsKey('account_delete'), isFalse);
  });

  testWidgets('plans table: calls show free (testing) when the server says so',
      (tester) async {
    final plans = <Map<String, dynamic>>[
      {'id': 'free', 'credits': 0, 'calls_free': true},
      {'id': 'premium', 'credits': 90, 'calls_free': true},
    ];
    _tall(tester);
    await tester.pumpWidget(_wrap(
        Scaffold(
            body: SingleChildScrollView(
                child: PlansCompareTable(plans: plans, current: 'free'))),
        _state(_DelApi())));
    await tester.pumpAndSettle();
    final t = _t(tester, PlansCompareTable);
    expect(find.text(t.dlCallsFreeTesting), findsNWidgets(2));
  });
}
