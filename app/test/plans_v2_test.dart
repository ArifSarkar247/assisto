// plans-v2: the honest upgrade sheet (Play price from ProductDetails vs the
// website APK's server price, never a fake button), usage display with
// Bangla digits, locked actions, the trial button, the comparison matrix,
// and the "only built features" rule.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/app_localizations_en.dart';
import 'package:assisto/payments/play_prices.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/plans_v2/plans_v2.dart';
import 'package:assisto/plans_v2/trial_banner.dart';
import 'package:assisto/plans_v2/upgrade_sheet.dart';
import 'package:assisto/screens/crm/crm_contacts_tab.dart'
    show CrmContactsTab, CrmUsageBanner;
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/plans_compare_table.dart';

import 'pay1_fakes.dart';

/// CRM contacts tab fake: an empty list + the given /plans/v2 answer.
class _CrmApi extends ApiClient {
  _CrmApi(this.v2) {
    token = 't';
  }
  final Map<String, dynamic> v2;

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      path.startsWith('/plans/v2') ? v2 : <String, dynamic>{};
}

Future<void> _pumpContacts(WidgetTester tester, Map<String, dynamic> v2) async {
  SharedPreferences.setMockInitialValues({});
  final app = AppState();
  app.api = _CrmApi(v2);
  app.loading = false;
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app, child: _app(const CrmContactsTab(org: 1))));
  await tester.pumpAndSettle();
}

Widget _app(Widget home, {String lang = 'en', double scale = 1, bool dark = false}) =>
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
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

const _contacts = UpgradeReason(
    feature: 'crm_contacts', neededPlan: 'premium', limit: 20, used: 20);
const _write = UpgradeReason(feature: 'crm_write', neededPlan: 'premium');

PlansV2State _state({bool trial = true}) => PlansV2State.fromJson({
      'on': true,
      'tier': 'free',
      'trial_available': trial,
      'trial_days': 7,
      'trial_plan': 'business',
    });

Future<void> _open(WidgetTester tester, UpgradeReason r,
    {required FakePaymentsBackend b,
    String flavour = 'apk',
    String lang = 'en',
    double scale = 1,
    bool dark = false,
    PlansV2State? state,
    Future<Map<String, dynamic>> Function()? startTrial}) async {
  await tester.binding.setSurfaceSize(const Size(360, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(
      Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showModalBottomSheet<bool>(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => UpgradeSheet(
                  reason: r,
                  backend: b,
                  flavour: flavour,
                  loadState: () async => state ?? _state(),
                  startTrial: startTrial,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      lang: lang,
      scale: scale,
      dark: dark));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late FakeStoreBilling billing;
  setUp(() {
    billing = FakeStoreBilling();
    StoreBilling.debugOverride = billing;
    PlayPrices.billing = () async => billing;
  });
  tearDown(() {
    StoreBilling.debugOverride = null;
    PlayPrices.debugReset();
  });

  test('a structured 402 becomes a reason; other errors do not', () {
    final e = ApiException('x', 402, null, 'upgrade_required', {
      'error': 'upgrade_required',
      'feature': 'crm_contacts',
      'needed_plan': 'premium',
      'limit': 20,
      'used': 20,
      'detail': 'line',
    });
    final r = UpgradeReason.fromError(e)!;
    expect((r.feature, r.neededPlan, r.limit, r.used), ('crm_contacts', 'premium', 20, 20));
    expect(UpgradeReason.fromError(ApiException('x', 402, null, 'credits',
        {'reason': 'credits', 'code': 'out_of_credits'})), isNull);
    expect(UpgradeReason.fromError(ApiException('x', 500)), isNull);
    expect(UpgradeReason.fromError(Exception('net')), isNull);
  });

  test('locks follow the ORG OWNER caps; flag off locks nothing', () {
    final s = PlansV2State.fromJson({
      'on': true,
      'tier': 'business', // the viewer is rich, the owner is not
      'needed': {'crm_write': 'premium', 'automation': 'business'},
      'crm': {
        'owner_tier': 'free',
        'caps': {'crm_write': false, 'automation': false},
        'contacts': {'used': 20, 'limit': 20, 'unlimited': false, 'can_add': false},
      },
    });
    expect(s.crmLock('crm_write')!.neededPlan, 'premium');
    expect(s.crmLock('automation')!.neededPlan, 'business');
    expect(s.contactLock()!.limit, 20);
    // the OWNER is on Free, so Premium is enough (the viewer's Business tier
    // must not decide what the owner needs)
    expect(s.contactLock()!.neededPlan, 'premium');
    final prem = PlansV2State.fromJson({
      'on': true,
      'tier': 'free',
      'crm': {
        'owner_tier': 'premium',
        'contacts': {'used': 500, 'limit': 500, 'unlimited': false, 'can_add': false},
      },
    });
    expect(prem.contactLock()!.neededPlan, 'business');
    expect(PlansV2State.off.crmLock('crm_write'), isNull);
    expect(PlansV2State.off.contactLock(), isNull);
    expect(PlansV2State.fromJson({'on': false, 'crm': {'caps': {'crm_write': false}}})
        .crmLock('crm_write'), isNull);
  });

  test('only built features are offered (no team members, no marketing)', () {
    final t = AppLocalizationsEn();
    final all = [
      ...upgradeBenefits(t, 'premium'),
      ...upgradeBenefits(t, 'business', booking: true, retention: true),
    ].join(' ').toLowerCase();
    expect(all.contains('team'), isFalse);
    expect(all.contains('marketing'), isFalse);
    expect(upgradeBenefits(t, 'business').any((b) => b.contains('Booking')), isFalse);
    expect(upgradeBenefits(t, 'business', booking: true).any((b) => b.contains('Booking')),
        isTrue);
  });

  testWidgets('website APK: the server price, real Upgrade button -> checkout',
      (tester) async {
    final b = FakePaymentsBackend(cfg: pay1Config(play: false));
    await _open(tester, _contacts, b: b);
    expect(find.text('Contact limit reached'), findsOneWidget);
    expect(find.text('20/20 contacts'), findsOneWidget); // usage
    final buy = find.byKey(const Key('pv2-upgrade-buy'));
    expect(buy, findsOneWidget);
    expect(find.textContaining('৳199'), findsOneWidget);
    expect(find.textContaining('BDT 199.00'), findsNothing); // never Play's on the APK
    expect(billing.priceQueries, isEmpty); // the APK never asks Play
    await tester.tap(buy);
    await tester.pumpAndSettle();
    expect(b.calls, contains('config:apk'));
  });

  testWidgets('Play build: Play\'s own ProductDetails price, never the server ৳',
      (tester) async {
    final b = FakePaymentsBackend();
    await _open(tester, _write, b: b, flavour: 'play');
    expect(find.text('CRM is view only on Free'), findsOneWidget);
    expect(find.textContaining('BDT 199.00'), findsOneWidget);
    expect(find.textContaining('৳199'), findsNothing);
    expect(billing.priceQueries.single, contains('assisto_premium'));
    expect(find.byKey(const Key('pv2-upgrade-buy')), findsOneWidget);
  });

  testWidgets('Play build, store price unknown: NO buy button (no fake button)',
      (tester) async {
    billing.priceMap = {};
    await _open(tester, _write, b: FakePaymentsBackend(), flavour: 'play');
    expect(find.byKey(const Key('pv2-upgrade-buy')), findsNothing);
    expect(find.byKey(const Key('pv2-price-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('pv2-see-plans')), findsOneWidget);
  });

  testWidgets('no live channel sells the plan: no buy button, plans link only',
      (tester) async {
    final b = FakePaymentsBackend(cfg: pay1Config(play: false, gwEnabled: false));
    await _open(tester, _write, b: b);
    expect(find.byKey(const Key('pv2-upgrade-buy')), findsNothing);
    expect(find.byKey(const Key('pv2-price-unavailable')), findsNothing);
    expect(find.byKey(const Key('pv2-see-plans')), findsOneWidget);
    // offline config: same honest result
    await _open(tester, _write, b: FakePaymentsBackend(failConfig: true));
    expect(find.byKey(const Key('pv2-upgrade-buy')), findsNothing);
  });

  testWidgets('trial: offered once, no card, clear end date; shows the result',
      (tester) async {
    var calls = 0;
    await _open(tester, _write,
        b: FakePaymentsBackend(cfg: pay1Config(play: false)),
        startTrial: () async {
          calls++;
          return {'ok': true, 'trial_plan': 'business', 'trial_until': '2026-11-03T10:00:00Z'};
        });
    expect(find.text('Start the free 7-day Business trial'), findsOneWidget);
    expect(find.textContaining('no card needed'), findsOneWidget);
    expect(find.textContaining('nothing is charged'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pv2-trial')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('pv2-trial')), findsNothing);
    expect(find.textContaining('Your Business trial has started'), findsOneWidget);
  });

  testWidgets('trial already used: no trial button', (tester) async {
    await _open(tester, _write,
        b: FakePaymentsBackend(cfg: pay1Config(play: false)), state: _state(trial: false));
    expect(find.byKey(const Key('pv2-trial')), findsNothing);
  });

  testWidgets('Bangla: Bangla digits, no overflow at 200% font in dark mode',
      (tester) async {
    await _open(tester, _contacts,
        b: FakePaymentsBackend(cfg: pay1Config(play: false)),
        lang: 'bn',
        scale: 2,
        dark: true);
    expect(find.text('২০/২০ কন্টাক্ট'), findsOneWidget);
    expect(find.textContaining('৳১৯৯'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // every tappable is at least 48 dp tall
    for (final f in [
      find.byKey(const Key('pv2-see-plans')),
      find.ancestor(of: find.text('এখন না'), matching: find.byType(TextButton)),
    ]) {
      expect(tester.getSize(f.first).height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('usage banner: 18/20 in Bangla digits, Unlimited for Business',
      (tester) async {
    await tester.pumpWidget(_app(
        const Scaffold(
            body: CrmUsageBanner(
                usage: ContactUsage(used: 18, limit: 20, unlimited: false, canAdd: true),
                viewOnly: true)),
        lang: 'bn'));
    expect(find.text('১৮/২০ কন্টাক্ট'), findsOneWidget);
    expect(find.textContaining('শুধু দেখা যায়'), findsOneWidget);
    await tester.pumpWidget(_app(const Scaffold(
        body: CrmUsageBanner(
            usage: ContactUsage(used: 1200, limit: 50000, unlimited: true, canAdd: true)))));
    expect(find.text('1,200 contacts · Unlimited'), findsOneWidget);
    expect(find.textContaining('50,000'), findsNothing); // the safety cap stays hidden
  });

  testWidgets('trial banner: shows the end date only while plans-v2 + trial',
      (tester) async {
    final on = PlansV2State.fromJson({
      'on': true,
      'trial_active': true,
      'trial_plan': 'business',
      'trial_until': '2026-11-03T10:00:00Z',
    });
    await tester.pumpWidget(_app(Scaffold(body: PlansV2TrialBanner(state: on))));
    expect(find.byKey(const Key('pv2-trial-banner')), findsOneWidget);
    expect(find.textContaining('Nov 3, 2026'), findsOneWidget);
    expect(find.textContaining('nothing is charged'), findsOneWidget);
    await tester.pumpWidget(_app(const Scaffold(body: PlansV2TrialBanner(state: PlansV2State.off))));
    expect(find.byKey(const Key('pv2-trial-banner')), findsNothing);
  });

  testWidgets('comparison table: the new matrix only when plans-v2 is on',
      (tester) async {
    final plans = <Map<String, dynamic>>[
      {'id': 'free', 'name': 'Free', 'ads': true, 'credits': 0, 'family': 0},
      {'id': 'premium', 'name': 'Premium', 'ads': false, 'credits': 90, 'family': 5},
      {'id': 'business', 'name': 'Business', 'ads': false, 'credits': 240, 'family': 0},
    ];
    final m = {
      'free': {'crm_contacts': 20, 'crm_unlimited': false, 'crm_write': false},
      'premium': {'crm_contacts': 500, 'crm_unlimited': false, 'crm_write': true,
          'crm_followup_reminders': true},
      'business': {'crm_contacts': 50000, 'crm_unlimited': true, 'crm_write': true,
          'crm_followup_reminders': true, 'automation': true, 'ai_sales_agent': true,
          'reports': true},
    };
    await tester.pumpWidget(_app(Scaffold(
        body: SingleChildScrollView(
            child: PlansCompareTable(plans: plans, current: 'free', v2: m)))));
    expect(find.text('View only'), findsOneWidget);
    expect(find.text('Up to 20'), findsOneWidget);
    expect(find.text('Up to 500'), findsOneWidget);
    expect(find.text('Unlimited'), findsOneWidget);
    expect(find.text('Booking bot'), findsNothing); // hidden feature not sold
    await tester.pumpWidget(_app(Scaffold(
        body: SingleChildScrollView(child: PlansCompareTable(plans: plans, current: 'free')))));
    expect(find.text('View only'), findsNothing);
  });

  testWidgets('locked action: a full Free CRM shows a lock and opens the sheet',
      (tester) async {
    await _pumpContacts(tester, {
      'on': true,
      'tier': 'free',
      'crm': {
        'owner_tier': 'free',
        'caps': {'crm_write': false},
        'contacts': {'used': 20, 'limit': 20, 'unlimited': false, 'can_add': false},
      },
    });
    final t = AppLocalizationsEn();
    expect(find.text('20/20 contacts'), findsOneWidget);
    expect(find.descendant(
            of: find.byKey(const Key('crm-add-contact')),
            matching: find.byIcon(Icons.lock_rounded)),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('crm-add-contact')));
    await tester.pumpAndSettle();
    expect(find.byType(UpgradeSheet), findsOneWidget);
    expect(find.text(t.pv2ReasonContactsTitle), findsOneWidget);
  });

  testWidgets('flag off: no lock, no usage bar (today\'s behaviour)',
      (tester) async {
    await _pumpContacts(tester, {'on': false});
    expect(find.byIcon(Icons.lock_rounded), findsNothing);
    expect(find.byType(CrmUsageBanner), findsNothing);
    await tester.tap(find.byKey(const Key('crm-add-contact')));
    await tester.pumpAndSettle();
    expect(find.byType(UpgradeSheet), findsNothing);
  });
}
