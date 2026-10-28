// probashi-plan (flag probashi_plan): the app side with a fake server.
// Every screen state (loading, feature off, offline, error + retry, empty,
// data) in bn + en, the three roles (not a payer / invitee / member / payer),
// consent defaults OFF, Play price only from the store (honest "not on
// Google Play yet"), 48dp buttons, dark theme and 200% text without overflow.
import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/probashi/probashi_entry_card.dart';
import 'package:assisto/screens/probashi/probashi_family_screen.dart';
import 'package:assisto/screens/probashi/probashi_plan_screen.dart';
import 'package:assisto/screens/probashi/probashi_pool_screen.dart';
import 'package:assisto/screens/probashi/probashi_reports_screen.dart';
import 'package:assisto/screens/probashi/probashi_source.dart';
import 'package:assisto/theme.dart';

const _benefits = ['Premium for you', 'Up to 4 family members', 'A shared pool of 180 credits'];

Map<String, dynamic> _base({bool payer = false}) => {
      'flag': true,
      'seats_max': 4,
      'pool_credits': 180,
      'cooldown_days': 30,
      'benefits': _benefits,
      'is_payer': payer,
      'invites': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _seat(int id, String name, String status, {int used = 0, int cap = 40}) => {
      'id': id,
      'status': status,
      'status_label': status == 'active' ? 'Active' : 'Invited',
      'monthly_cap': cap,
      'used_this_month': used,
      'consent': {'journeys': true},
      'member': {'id': 100 + id, 'name': name},
      'payer': {'id': 1, 'name': 'Rahim'},
    };

class FakeSource implements ProbashiSource {
  Map<String, dynamic> ov;
  Object? fail;
  Completer<void>? hold;
  final calls = <String>[];
  Map<String, bool>? lastConsent;
  int? lastCap;
  List<Map<String, dynamic>> cands = [];
  Map<String, dynamic> famData = {'members': []};
  Map<String, dynamic> poolData = {'rows': [], 'per_member': [], 'left': 180};
  List<Map<String, dynamic>> reps = [];
  FakeSource(this.ov);

  Future<T> _r<T>(T v) async {
    if (hold != null) await hold!.future;
    if (fail != null) throw fail!;
    return v;
  }

  @override
  Future<Map<String, dynamic>> overview() {
    calls.add('overview');
    return _r(ov);
  }

  @override
  Future<List<Map<String, dynamic>>> candidates() => _r(cands);
  @override
  Future<Map<String, dynamic>> invite(int memberId) {
    calls.add('invite:$memberId');
    return _r({});
  }

  @override
  Future<Map<String, dynamic>> respond(int seatId, bool accept, Map<String, bool> consent) {
    calls.add('respond:$seatId:$accept');
    lastConsent = consent;
    return _r({});
  }

  @override
  Future<Map<String, dynamic>> remove(int seatId) {
    calls.add('remove:$seatId');
    return _r({});
  }

  @override
  Future<Map<String, dynamic>> leave(int seatId) {
    calls.add('leave:$seatId');
    return _r({});
  }

  @override
  Future<Map<String, dynamic>> transfer(int seatId, int memberId) {
    calls.add('transfer:$seatId:$memberId');
    return _r({});
  }

  @override
  Future<Map<String, dynamic>> setCap(int seatId, int cap) {
    calls.add('cap:$seatId:$cap');
    lastCap = cap;
    return _r({});
  }

  @override
  Future<Map<String, dynamic>> setConsent(int seatId, Map<String, bool> consent) {
    lastConsent = consent;
    return _r({});
  }

  @override
  Future<Map<String, dynamic>> pool() => _r(poolData);
  @override
  Future<Map<String, dynamic>> family() => _r(famData);
  @override
  Future<List<Map<String, dynamic>>> reports() => _r(reps);
  @override
  Future<void> markRead(int reportId) async => calls.add('read:$reportId');
}

class FakeBuyer implements ProbashiBuyer {
  Map<String, String> p;
  final bought = <String>[];
  FakeBuyer(this.p);
  @override
  Future<Map<String, String>> prices() async => p;
  @override
  Future<ProbashiBuyStatus> buy(String basePlan) async {
    bought.add(basePlan);
    return ProbashiBuyStatus.pending;
  }
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
      key: UniqueKey(),
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void _tall(WidgetTester tester, Finder f) {
  final s = tester.getSize(f);
  expect(s.height, greaterThanOrEqualTo(48), reason: '$f is ${s.height}dp tall');
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });

  group('states', () {
    testWidgets('loading', (tester) async {
      _phone(tester);
      final s = FakeSource(_base())..hold = Completer<void>();
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({}))));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      s.hold!.complete();
      await _settle(tester);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('feature off ($lang): honest message, no retry', (tester) async {
        _phone(tester);
        final t = lang == 'en' ? en : bn;
        final s = FakeSource(_base())
          ..fail = ApiException('x', 403, null, null, {'error': 'feature_off', 'detail': 'off'});
        await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({})), lang: lang));
        await _settle(tester);
        expect(find.text(t.pbsOffTitle), findsOneWidget);
        expect(find.text(t.pbsRetry), findsNothing);
      });

      testWidgets('offline ($lang) then retry works', (tester) async {
        _phone(tester);
        final t = lang == 'en' ? en : bn;
        final s = FakeSource(_base())..fail = const SocketException('no net');
        await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({})), lang: lang));
        await _settle(tester);
        expect(find.text(t.pbsOfflineTitle), findsOneWidget);
        _tall(tester, find.widgetWithText(FilledButton, t.pbsRetry));
        s.fail = null;
        await tester.tap(find.text(t.pbsRetry));
        await _settle(tester);
        expect(find.text(t.pbsIncludesTitle), findsOneWidget);
      });

      testWidgets('server error ($lang) shows the server message', (tester) async {
        _phone(tester);
        final t = lang == 'en' ? en : bn;
        final s = FakeSource(_base())
          ..fail = ApiException('boom', 500, null, null, {'detail': 'Server says no'});
        await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({})), lang: lang));
        await _settle(tester);
        expect(find.text(t.pbsErrorTitle), findsOneWidget);
        expect(find.text('Server says no'), findsOneWidget);
      });
    }
  });

  group('not a payer', () {
    testWidgets('benefits = server list only; price from Google Play only', (tester) async {
      _phone(tester, height: 1400);
      final buyer = FakeBuyer({'monthly': 'SAR 37.99', 'annual': 'SAR 379.99'});
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: FakeSource(_base()), buyer: buyer)));
      await _settle(tester);
      for (final b in _benefits) {
        expect(find.text(b), findsOneWidget);
      }
      expect(find.text(en.pbsBuyMonthly('SAR 37.99')), findsOneWidget);
      _tall(tester, find.byKey(const ValueKey('pbs-buy-monthly')));
      await tester.tap(find.byKey(const ValueKey('pbs-buy-annual')));
      await _settle(tester);
      expect(buyer.bought, ['annual']);
      expect(find.text(en.pbsBuyPending), findsOneWidget);
    });

    testWidgets('bn: store price digits in Bangla', (tester) async {
      _phone(tester, height: 1400);
      final buyer = FakeBuyer({'monthly': 'SAR 37.99'});
      await tester.pumpWidget(
          _app(ProbashiPlanScreen(source: FakeSource(_base()), buyer: buyer), lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.pbsBuyMonthly('SAR ৩৭.৯৯')), findsOneWidget);
    });

    testWidgets('product not on Play: honest state, no buy button', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: FakeSource(_base()), buyer: FakeBuyer({}))));
      await _settle(tester);
      expect(find.byKey(const ValueKey('pbs-not-on-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('pbs-buy-monthly')), findsNothing);
    });
  });

  group('invitee', () {
    testWidgets('accept: every consent switch starts OFF', (tester) async {
      _phone(tester, height: 1400);
      final s = FakeSource({
        ..._base(),
        'invites': [_seat(5, 'Ma', 'invited')..['payer'] = {'id': 1, 'name': 'Rahim'}],
      });
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({}))));
      await _settle(tester);
      expect(find.text(en.pbsInviteFrom('Rahim')), findsOneWidget);
      _tall(tester, find.byKey(const ValueKey('pbs-accept-5')));
      await tester.tap(find.byKey(const ValueKey('pbs-accept-5')));
      await _settle(tester);
      for (final k in ['journeys', 'sos', 'budget', 'reminders', 'report']) {
        final sw = tester.widget<SwitchListTile>(find.byKey(ValueKey('pbs-consent-$k')));
        expect(sw.value, isFalse, reason: k);
      }
      await tester.tap(find.byKey(const ValueKey('pbs-consent-journeys')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pbs-consent-save')));
      await _settle(tester);
      expect(s.calls, contains('respond:5:true'));
      expect(s.lastConsent, {'journeys': true, 'sos': false, 'budget': false, 'reminders': false, 'report': false});
    });

    testWidgets('decline asks first', (tester) async {
      _phone(tester, height: 1400);
      final s = FakeSource({..._base(), 'invites': [_seat(5, 'Ma', 'invited')]});
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({})), lang: 'bn'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pbs-decline-5')));
      await _settle(tester);
      expect(find.text(bn.pbsDeclineTitle), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, bn.pbsDecline));
      await _settle(tester);
      expect(s.calls, contains('respond:5:false'));
    });
  });

  group('member', () {
    Map<String, dynamic> member({bool live = true}) => {
          ..._base(),
          'membership': {..._seat(9, 'Ma', 'active', used: 12, cap: 40), 'live': live, 'pool_left': 150},
        };

    testWidgets('bn digits, leave with confirm', (tester) async {
      _phone(tester, height: 1600);
      final s = FakeSource(member());
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({})), lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.pbsUsedOfCap('১২', '৪০')), findsOneWidget);
      expect(find.text(bn.pbsPoolLeftShort('১৫০')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('pbs-leave')));
      await tester.tap(find.byKey(const ValueKey('pbs-leave')));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, bn.pbsLeave));
      await _settle(tester);
      expect(s.calls, contains('leave:9'));
    });

    testWidgets('paused when the payer plan is off', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: FakeSource(member(live: false)), buyer: FakeBuyer({}))));
      await _settle(tester);
      expect(find.text(en.pbsPaused), findsOneWidget);
    });
  });

  group('payer', () {
    Map<String, dynamic> payer({int used = 2, String? freeAt}) => {
          ..._base(payer: true),
          'seats': [_seat(1, 'Ma', 'active', used: 5), _seat(2, 'Bon', 'invited')],
          'slots_used': used,
          'slot_free_at': freeAt,
          'pool': {'total': 180, 'left': 120},
        };

    testWidgets('seats, pool, cap editor', (tester) async {
      _phone(tester, height: 1600);
      final s = FakeSource(payer());
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({}))));
      await _settle(tester);
      expect(find.text(en.pbsPoolLeft('120', '180')), findsOneWidget);
      expect(find.text(en.pbsSeatsTitle('2', '4')), findsOneWidget);
      _tall(tester, find.byKey(const ValueKey('pbs-invite')));
      await tester.tap(find.byKey(const ValueKey('pbs-seat-menu-1')));
      await _settle(tester);
      await tester.tap(find.text(en.pbsSetCap).last);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pbs-cap-plus')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pbs-cap-save')));
      await _settle(tester);
      expect(s.lastCap, 45);
    });

    testWidgets('full: invite disabled + when a seat frees', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(
          ProbashiPlanScreen(source: FakeSource(payer(used: 4, freeAt: '2026-11-20T10:00:00Z')), buyer: FakeBuyer({})),
          lang: 'bn'));
      await _settle(tester);
      final b = tester.widget<FilledButton>(
          find.ancestor(of: find.text(bn.pbsInvite), matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(b.onPressed, isNull);
      expect(find.text(bn.pbsSlotFreeAt('২০/১১/২০২৬')), findsOneWidget);
    });

    testWidgets('invite: ineligible people greyed with the reason', (tester) async {
      _phone(tester, height: 1600);
      final s = FakeSource(payer())
        ..cands = [
          {'id': 7, 'name': 'Bhai', 'eligible': true, 'reason': '', 'reason_text': ''},
          {'id': 8, 'name': 'Friend', 'eligible': false, 'reason': 'bd_phone_required', 'reason_text': 'Bangladesh numbers only'},
        ];
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({}))));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pbs-invite')));
      await _settle(tester);
      expect(find.text('Bangladesh numbers only'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('pbs-cand-8'))).enabled, isFalse);
      await tester.tap(find.byKey(const ValueKey('pbs-cand-7')));
      await _settle(tester);
      expect(s.calls, contains('invite:7'));
    });

    testWidgets('remove asks first', (tester) async {
      _phone(tester, height: 1600);
      final s = FakeSource(payer());
      await tester.pumpWidget(_app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({}))));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pbs-seat-menu-1')));
      await _settle(tester);
      await tester.tap(find.text(en.pbsRemove).last);
      await _settle(tester);
      expect(find.text(en.pbsRemoveTitle), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, en.pbsRemove));
      await _settle(tester);
      expect(s.calls, contains('remove:1'));
    });
  });

  group('family dashboard', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('only consented sections ($lang)', (tester) async {
        _phone(tester, height: 1600);
        final t = lang == 'en' ? en : bn;
        final s = FakeSource(_base())
          ..famData = {
            'members': [
              {
                'member': {'id': 101, 'name': 'Ma'},
                'shared': ['budget', 'journeys'],
                'location_sharing': true,
                'journeys_month': 2,
                'journeys': [
                  {'at': '2026-10-20T08:00:00Z', 'status': 'arrived'}
                ],
                'money': {'received_poisha': 2000000, 'budget_poisha': 1500000, 'spent_poisha': 900000},
              },
              {'member': {'id': 102, 'name': 'Bon'}, 'shared': [], 'location_sharing': false},
            ]
          };
        await tester.pumpWidget(_app(ProbashiFamilyScreen(source: s), lang: lang));
        await _settle(tester);
        expect(find.text(t.pbsLocationOn), findsOneWidget);
        expect(find.text(t.pbsLocationOff), findsOneWidget);
        expect(find.text(t.pbsNotShared(t.pbsConsentBudget, 'Bon')), findsOneWidget);
        expect(find.text(t.pbsNotShared(t.pbsConsentSos, 'Ma')), findsOneWidget);
        final taka = lang == 'bn' ? ['৳২০,০০০', '৳১৫,০০০', '৳৯,০০০'] : ['৳20,000', '৳15,000', '৳9,000'];
        expect(find.text(t.pbsMoneyLine(taka[0], taka[1], taka[2])), findsOneWidget);
      });
    }

    testWidgets('empty', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(ProbashiFamilyScreen(source: FakeSource(_base()))));
      await _settle(tester);
      expect(find.byKey(const ValueKey('pbs-family-empty')), findsOneWidget);
    });
  });

  group('pool + reports', () {
    testWidgets('pool ledger empty + per member', (tester) async {
      _phone(tester);
      final s = FakeSource(_base())
        ..poolData = {
          'rows': [],
          'per_member': [
            {'member': {'id': 1, 'name': 'Ma'}, 'used': 10, 'cap': 40}
          ],
          'left': 170
        };
      await tester.pumpWidget(_app(ProbashiPoolScreen(source: s)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('pbs-ledger-empty')), findsOneWidget);
      expect(find.text(en.pbsUsedOfCap('10', '40')), findsOneWidget);
    });

    testWidgets('reports empty, then open one marks it read', (tester) async {
      _phone(tester);
      final s = FakeSource(_base());
      await tester.pumpWidget(_app(ProbashiReportsScreen(source: s), lang: 'bn'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('pbs-reports-empty')), findsOneWidget);
      s.reps = [
        {
          'id': 3,
          'month': '2026-09',
          'read': false,
          'sections': [
            {'member': {'id': 1, 'name': 'Ma'}, 'lines': ['Ma: ২টি নিরাপদ যাত্রা']}
          ],
        }
      ];
      await tester.pumpWidget(_app(ProbashiReportsScreen(source: s), lang: 'bn'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pbs-report-3')));
      await _settle(tester);
      expect(find.text('Ma: ২টি নিরাপদ যাত্রা'), findsOneWidget);
      expect(s.calls, contains('read:3'));
    });
  });

  group('look', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('dark + 200% text, payer page has no overflow ($lang)', (tester) async {
        _phone(tester, height: 800);
        final s = FakeSource({
          ..._base(payer: true),
          'seats': [_seat(1, 'Ma', 'active', used: 5)],
          'slots_used': 1,
          'pool': {'total': 180, 'left': 175},
        });
        await tester.pumpWidget(
            _app(ProbashiPlanScreen(source: s, buyer: FakeBuyer({})), lang: lang, scale: 2.0, dark: true));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(_app(ProbashiPlanScreen(source: FakeSource(_base()), buyer: FakeBuyer({'monthly': 'USD 9.99'})),
            lang: lang, scale: 2.0, dark: true));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('entry card hidden when off, shown when on', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const Scaffold(body: ProbashiPlanEntryCard(visible: false))));
      expect(find.byKey(const ValueKey('pbs-entry-card')), findsNothing);
      await tester.pumpWidget(_app(const Scaffold(body: ProbashiPlanEntryCard(visible: true))));
      expect(find.byKey(const ValueKey('pbs-entry-card')), findsOneWidget);
      _tall(tester, find.byKey(const ValueKey('pbs-entry-card')));
    });
  });
}
