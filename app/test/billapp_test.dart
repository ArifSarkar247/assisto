// billapp (27 Oct) — the app's billing v2 screens on a mocked API:
// Credits (buckets, locked + unlock time, debt, purchase block, costs from
// the server, paged history, offline cache with its time, out-of-credits
// reason), Refunds (eligible / not, server suggestion, every status with the
// owner's note, duplicate / rate-limit / network errors) and the Plan status
// panel (trial left + what ends, usage meters, limit reached), in bn + en,
// dark mode and 200% font.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/billing/billing_api.dart';
import 'package:assisto/billing/plan_status_panel.dart';
import 'package:assisto/billing/refund_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/plans_v2/plans_v2.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

const _bnDigits = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];
String bnd(String s) =>
    s.split('').map((c) => int.tryParse(c) != null ? _bnDigits[int.parse(c)] : c).join();

Map<String, dynamic> stateJson({
  int now = 18,
  int locked = 72,
  int debt = 0,
  bool purchaseBlocked = false,
  Duration unlockIn = const Duration(hours: 47),
}) {
  final t = DateTime.utc(2026, 10, 27, 10);
  return {
    'balance': debt > 0 ? -debt : now,
    'now_usable': debt > 0 ? 0 : now,
    'locked': locked,
    'unlocks_at': locked > 0 ? t.add(unlockIn).toIso8601String() : null,
    'negative': debt > 0,
    'blocked': debt > 0,
    'purchase_blocked': purchaseBlocked,
    'debt': debt,
    'bucket_detail': [
      if (now > 0 || locked > 0)
        {'bucket': 'plan', 'remaining': now, 'locked': locked,
          'expires_at': t.add(const Duration(days: 30)).toIso8601String(),
          'unlocks_at': locked > 0 ? t.add(unlockIn).toIso8601String() : null},
      if (debt == 0) {'bucket': 'pack', 'remaining': 20, 'locked': 0},
      if (debt > 0) {'bucket': 'debt', 'remaining': -debt, 'locked': 0},
    ],
    'plan_expires_at': t.add(const Duration(days: 30)).toIso8601String(),
    'unlock_pct': 20,
    'unlock_hours': 48,
    'refund_window_hours': 48,
    'action_costs': {'ai_msg_cheap': 1, 'scan_ocr': 2, 'internal_thing': 4, 'retention_in_app': 0},
    'withdrawable': false,
    'server_time': t.toIso8601String(),
  };
}

class BillFakeApi extends ApiClient {
  BillFakeApi() {
    token = 'test';
  }
  Map<String, dynamic> state = stateJson();
  bool offline = false;
  int historyCalls = 0;
  Map<String, dynamic> refunds = const {};
  Map<String, dynamic>? postAnswer;
  ApiException? postError;
  bool postNetworkFail = false;
  final posts = <Map<String, dynamic>>[];

  Never _off() => throw ApiException('offline', null);

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (offline) _off();
    if (path == '/credits/state') return state;
    if (path.startsWith('/credits/history')) {
      historyCalls++;
      final off = int.parse(Uri.parse(path).queryParameters['offset'] ?? '0');
      return off == 0
          ? {
              'ledger': [
                {'id': 9, 'delta': -1, 'reason': 'consume', 'note': 'ai_msg_cheap', 'bucket': 'plan',
                  'at': '2026-10-27T09:00:00Z'},
                {'id': 8, 'delta': 18, 'reason': 'grant', 'bucket': 'plan', 'at': '2026-10-27T08:00:00Z'},
              ],
              'next_offset': 2,
            }
          : {
              'ledger': [
                {'id': 7, 'delta': 20, 'reason': 'topup', 'bucket': 'pack', 'at': '2026-10-20T08:00:00Z'},
              ],
              'next_offset': null,
            };
    }
    if (path == '/credits/refunds') return refunds;
    if (path == '/me/usage-summary') {
      return {'plan': 'premium', 'balance': 18, 'included_pool': 90, 'month_total': 30,
        'month_usage': [{'action': 'ai_msg_cheap', 'credits': 30}]};
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> creditsPacks() async {
    if (offline) _off();
    return const [];
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add({'path': path, ...body});
    if (postNetworkFail) throw Exception('socket');
    if (postError != null) throw postError!;
    return postAnswer ?? {'ok': true, 'request': {'id': 5, 'status': 'pending', 'order': 12}};
  }
}

Widget _wrap(Widget child, {String lang = 'en', ThemeMode mode = ThemeMode.light,
        double scale = 1.0}) =>
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      darkTheme: AssistoTheme.dark,
      themeMode: mode,
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    );

Future<AppLocalizations> pump(WidgetTester tester, Widget screen, BillFakeApi api,
    {String lang = 'en', ThemeMode mode = ThemeMode.light, double scale = 1.0,
    Size size = const Size(1080, 9000), bool resetPrefs = true}) async {
  if (resetPrefs) SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = api
    ..user = AppUser(id: 7, name: 'Me', phone: '+8801700000000', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s, child: _wrap(screen, lang: lang, mode: mode, scale: scale)));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return AppLocalizations.of(tester.element(find.byType(screen.runtimeType)));
}

void main() {
  group('Credits screen', () {
    testWidgets('en: usable now, locked + when, buckets, costs from server, never cash',
        (tester) async {
      final api = BillFakeApi();
      final t = await pump(tester, const CreditsScreen(), api);
      expect(find.text('18 usable now, 72 more unlock in 2 days'), findsOneWidget);
      expect(find.byKey(const ValueKey('bucket-plan')), findsOneWidget);
      expect(find.byKey(const ValueKey('bucket-pack')), findsOneWidget);
      expect(find.text(t.billNeverExpires), findsOneWidget); // the pack
      expect(find.textContaining('72 locked'), findsOneWidget);
      expect(find.byKey(const Key('credits-locked-explain')), findsOneWidget);
      // costs: only the server's numbers, unknown + free codes not shown
      expect(find.byKey(const ValueKey('cost-ai_msg_cheap')), findsOneWidget);
      expect(find.byKey(const ValueKey('cost-scan_ocr')), findsOneWidget);
      expect(find.byKey(const ValueKey('cost-internal_thing')), findsNothing);
      expect(find.byKey(const ValueKey('cost-retention_in_app')), findsNothing);
      expect(find.text(t.credoutNoCash), findsOneWidget);
      expect(find.byKey(const Key('credits-debt')), findsNothing);
      expect(find.byKey(const Key('credits-refunds')), findsOneWidget);
    });

    testWidgets('bn: the owner sentence with Bangla digits', (tester) async {
      final api = BillFakeApi();
      final t = await pump(tester, const CreditsScreen(), api, lang: 'bn');
      final want = t.billNowAndLocked(bnd('18'), bnd('72'), t.billWhenDays(bnd('2')));
      expect(want, contains('এখন ১৮ ব্যবহার করা যাবে, আরও ৭২টি ২ দিনে'));
      expect(find.text(want), findsOneWidget);
      expect(find.text('18 usable now, 72 more unlock in 2 days'), findsNothing);
    });

    testWidgets('unlock under an hour / in hours', (tester) async {
      final api = BillFakeApi()..state = stateJson(unlockIn: const Duration(minutes: 20));
      final t = await pump(tester, const CreditsScreen(), api);
      expect(find.textContaining(t.billWhenSoon), findsWidgets);
      api.state = stateJson(unlockIn: const Duration(hours: 5, minutes: 10));
      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('18 usable now, 72 more unlock in 6 hours'), findsOneWidget);
    });

    testWidgets('debt: banner + owed bucket, nothing usable', (tester) async {
      final api = BillFakeApi()..state = stateJson(now: 0, locked: 0, debt: 12);
      final t = await pump(tester, const CreditsScreen(), api);
      expect(find.byKey(const Key('credits-debt')), findsOneWidget);
      expect(find.text(t.billDebtBody('12')), findsOneWidget);
      expect(find.byKey(const ValueKey('bucket-debt')), findsOneWidget);
      expect(find.byKey(const Key('credits-now')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('credits-now'))).data, '0');
    });

    testWidgets('purchase blocked: says so, no packs', (tester) async {
      final api = BillFakeApi()..state = stateJson(purchaseBlocked: true);
      final t = await pump(tester, const CreditsScreen(), api);
      expect(find.byKey(const Key('credits-purchase-blocked')), findsOneWidget);
      expect(find.text(t.billPurchaseBlocked), findsWidgets);
    });

    testWidgets('history: paged with Show more, plain reasons', (tester) async {
      final api = BillFakeApi();
      final t = await pump(tester, const CreditsScreen(), api);
      expect(find.text(t.billLedPlan), findsOneWidget);
      expect(find.text(t.billLedTopup), findsNothing);
      await tester.tap(find.byKey(const Key('credits-history-more')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(t.billLedTopup), findsOneWidget);
      expect(find.byKey(const Key('credits-history-more')), findsNothing);
      expect(api.historyCalls, 2);
    });

    testWidgets('offline: last saved state with its time; no cache = honest error',
        (tester) async {
      final api = BillFakeApi();
      await pump(tester, const CreditsScreen(), api); // online once: saves
      api.offline = true;
      await tester.pumpWidget(const SizedBox());
      final t = await pump(tester, const CreditsScreen(), api, resetPrefs: false);
      expect(find.byKey(const Key('credits-cached')), findsOneWidget);
      expect(find.text('18 usable now, 72 more unlock in 2 days'), findsOneWidget);
      expect(find.byKey(const Key('credits-history-more')), findsNothing);
      // nothing saved at all: the honest error with retry
      await tester.pumpWidget(const SizedBox());
      SharedPreferences.setMockInitialValues({});
      await pump(tester, const CreditsScreen(), api);
      expect(find.text(t.loadFailed), findsOneWidget);
      expect(find.text(t.retry), findsOneWidget);
    });

    testWidgets('opened from an out-of-credits moment: the exact reason', (tester) async {
      final api = BillFakeApi();
      final t = await pump(
          tester, const CreditsScreen(reason: CreditsOpenReason(need: 3)), api);
      expect(find.byKey(const Key('credits-reason')), findsOneWidget);
      expect(find.textContaining(t.billReasonNeed('3', '18')), findsOneWidget);
      expect(find.textContaining('72'), findsWidgets);
    });

    testWidgets('dark mode + 200% font at phone width: no overflow', (tester) async {
      final api = BillFakeApi()..state = stateJson(debt: 0);
      await pump(tester, const CreditsScreen(), api,
          lang: 'bn', mode: ThemeMode.dark, scale: 2.0, size: const Size(800, 12000));
      expect(tester.takeException(), isNull);
      await pump(tester, const CreditsScreen(), api,
          lang: 'en', scale: 2.0, size: const Size(800, 12000));
      expect(tester.takeException(), isNull);
    });

    testWidgets('48dp: every button on the screen', (tester) async {
      final api = BillFakeApi();
      await pump(tester, const CreditsScreen(), api);
      for (final f in [find.byKey(const Key('credits-history-more')),
        find.byKey(const Key('credits-refunds'))]) {
        expect(tester.getSize(f).height, greaterThanOrEqualTo(48));
      }
    });
  });

  group('Refunds', () {
    Map<String, dynamic> refunds() => {
          'window_hours': 48,
          'policy': {'text': 'Within 48 hours, only the unused part.'},
          'purchases': [
            {'id': 12, 'channel': 'play', 'sku': 'premium_monthly', 'kind': 'sub',
              'plan': 'premium', 'price': '199.00', 'currency': 'BDT', 'test': true,
              'purchased_at': '2026-10-27T08:00:00Z', 'window_ends_at': '2026-10-29T08:00:00Z',
              'eligible': true, 'reason': '', 'suggested': '179.10',
              'usage': {'credits_planned': 90, 'credits_used': 9, 'days_total': 30.0,
                'days_used': 0.1}},
            {'id': 11, 'kind': 'pack', 'sku': 'pack_p50', 'price': '50.00', 'currency': 'BDT',
              'eligible': false, 'reason': 'outside_window'},
            {'id': 10, 'kind': 'pack', 'sku': 'pack_p20', 'price': '20.00', 'currency': 'BDT',
              'eligible': false, 'reason': 'already_requested'},
          ],
          'requests': [
            {'id': 1, 'status': 'pending', 'order': 10, 'requested_at': '2026-10-26T08:00:00Z'},
            {'id': 2, 'status': 'approved', 'order': 9, 'approved_amount': '199.00'},
            {'id': 3, 'status': 'manual', 'order': 8, 'approved_amount': '120.50'},
            {'id': 4, 'status': 'rejected', 'order': 7, 'note': 'Used most credits'},
          ],
        };

    testWidgets('list: eligible ask button, honest reasons, every status + note',
        (tester) async {
      final api = BillFakeApi()..refunds = refunds();
      final t = await pump(tester, const RefundScreen(), api);
      expect(find.byKey(const ValueKey('refund-ask-12')), findsOneWidget);
      expect(find.byKey(const ValueKey('refund-ask-11')), findsNothing);
      expect(find.text(t.billRefundNotEligibleWindow('48')), findsOneWidget);
      expect(find.text(t.billRefundNotEligibleRequested), findsOneWidget);
      expect(find.text(t.billRefundTest), findsOneWidget);
      expect(find.text(t.billRefundStatusPending), findsOneWidget);
      expect(find.text(t.billRefundStatusApproved('৳199')), findsOneWidget);
      expect(find.textContaining('120.50'), findsOneWidget);
      expect(find.text(t.billRefundStatusRejected), findsOneWidget);
      expect(find.text(t.billRefundOwnerNote('Used most credits')), findsOneWidget);
      expect(find.byKey(const Key('refund-policy')), findsOneWidget);
    });

    testWidgets('ask: server suggestion + usage + no promise; send -> pending', (tester) async {
      final api = BillFakeApi()..refunds = refunds();
      final t = await pump(tester, const RefundScreen(), api);
      await tester.tap(find.byKey(const ValueKey('refund-ask-12')));
      await tester.pumpAndSettle();
      expect(find.text(t.billRefundSuggested('৳179.10')), findsOneWidget);
      expect(find.text(t.billRefundUsageCredits('9', '90')), findsOneWidget);
      expect(find.text(t.billRefundUsageDays('0', '30')), findsOneWidget);
      expect(find.byKey(const Key('refund-no-promise')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('refund-reason')), 'did not need it');
      await tester.tap(find.byKey(const Key('refund-send')));
      await tester.pumpAndSettle();
      expect(api.posts.single['purchase_id'], 12);
      expect(api.posts.single['reason'], 'did not need it');
      expect(find.text(t.billRefundSent), findsOneWidget);
    });

    testWidgets('bn: Bangla digits + taka in the sheet', (tester) async {
      final api = BillFakeApi()..refunds = refunds();
      final t = await pump(tester, const RefundScreen(), api, lang: 'bn');
      await tester.tap(find.byKey(const ValueKey('refund-ask-12')));
      await tester.pumpAndSettle();
      expect(find.text(t.billRefundSuggested('৳${bnd('179.10')}')), findsOneWidget);
    });

    for (final c in [
      (ApiException('dup', 409, null, 'already_requested',
          {'reason': 'already_requested', 'message': 'A request for this purchase was already sent.'}),
          'A request for this purchase was already sent.'),
      (ApiException('rl', 429, null, 'rate_limited', {'reason': 'rate_limited', 'message': ''}),
          null),
    ]) {
      testWidgets('refusal ${c.$1.reason}: shown, sheet stays', (tester) async {
        final api = BillFakeApi()
          ..refunds = refunds()
          ..postError = c.$1;
        final t = await pump(tester, const RefundScreen(), api);
        await tester.tap(find.byKey(const ValueKey('refund-ask-12')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('refund-send')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('refund-error-note')), findsOneWidget);
        expect(find.text(c.$2 ?? t.billRefundRateLimited), findsOneWidget);
        expect(find.byKey(const Key('refund-send')), findsOneWidget);
      });
    }

    testWidgets('no internet: nothing sent claim', (tester) async {
      final api = BillFakeApi()
        ..refunds = refunds()
        ..postNetworkFail = true;
      final t = await pump(tester, const RefundScreen(), api);
      await tester.tap(find.byKey(const ValueKey('refund-ask-12')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('refund-send')));
      await tester.pumpAndSettle();
      expect(find.text(t.billRefundNetwork), findsOneWidget);
    });

    testWidgets('empty + load error states', (tester) async {
      final api = BillFakeApi()..refunds = {'window_hours': 48, 'purchases': [], 'requests': []};
      await pump(tester, const RefundScreen(), api);
      expect(find.byKey(const Key('refund-empty')), findsOneWidget);
      api.offline = true;
      await tester.pumpWidget(const SizedBox());
      await pump(tester, const RefundScreen(), api);
      expect(find.byKey(const Key('refund-error')), findsOneWidget);
    });

    testWidgets('200% font, dark: no overflow', (tester) async {
      final api = BillFakeApi()..refunds = refunds();
      await pump(tester, const RefundScreen(), api,
          lang: 'bn', mode: ThemeMode.dark, scale: 2.0, size: const Size(800, 9000));
      expect(tester.takeException(), isNull);
    });
  });

  group('Plan status panel', () {
    Widget host(PlanStatusPanel p) => Scaffold(body: SingleChildScrollView(child: p));

    testWidgets('trial left + what ends; credits until; meters; limit reached', (tester) async {
      final now = DateTime(2026, 10, 27, 10);
      final v2 = PlansV2State.fromJson({
        'on': true, 'tier': 'business', 'trial_active': true,
        'trial_until': DateTime(2026, 10, 30, 9).toIso8601String(),
        'own_crm_contacts': {'used': 20, 'limit': 20, 'unlimited': false, 'can_add': false},
      });
      final api = BillFakeApi();
      final t = await pump(
          tester,
          host(PlanStatusPanel(
            plan: const {'plan': 'business', 'trial_active': true},
            v2: v2,
            now: now,
            credits: CreditsState.fromJson(stateJson()),
            usage: const {'included_pool': 90, 'month_total': 30},
          )),
          api);
      expect(find.text(t.billPlanTrialLeft('3')), findsOneWidget);
      expect(find.byKey(const Key('plan-credits-until')), findsOneWidget);
      expect(find.byKey(const Key('plan-locked-line')), findsOneWidget);
      expect(find.text(t.billPlanUsageCredits('30', '90')), findsOneWidget);
      expect(find.textContaining('20/20'), findsOneWidget);
      expect(find.text(t.billPlanLimitReached), findsOneWidget);
    });

    testWidgets('nothing from the server = nothing shown', (tester) async {
      await pump(tester, host(const PlanStatusPanel(plan: {})), BillFakeApi());
      expect(find.byKey(const Key('plan-status-panel')), findsNothing);
    });

    testWidgets('plans_v2 off: no contact meter even if sent', (tester) async {
      final v2 = PlansV2State.fromJson({
        'on': false,
        'own_crm_contacts': {'used': 2, 'limit': 20, 'can_add': true},
      });
      await pump(
          tester,
          host(PlanStatusPanel(plan: const {}, v2: v2, usage: const {'included_pool': 90})),
          BillFakeApi());
      expect(find.byKey(const Key('plan-meter-contacts')), findsNothing);
      expect(find.byKey(const Key('plan-meter-credits')), findsOneWidget);
    });
  });

  test('CreditsState: older server without bucket_detail / debt', () {
    final s = CreditsState.fromJson({'balance': -4, 'buckets': {'pack': 0, 'debt': -4}});
    expect(s.debt, 4);
    expect(s.buckets.single.bucket, 'debt');
    expect(s.withdrawable, isFalse);
    expect(s.untilUnlock(), isNull);
  });
}
