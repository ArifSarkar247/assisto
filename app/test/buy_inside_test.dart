// buyinside (owner order 10 Nov 00:50): buy inside every paid feature.
// Billing fakes only (no network, no Play): the CCTV locked screen (7-day
// Play trial offer, price button, back to the same screen unlocked, no fake
// button without Play), restore, the credits sheet inside the task (keeps
// the typed text, best value pack, 2 ads = 1 Normal answer, continues by
// itself after a purchase) and the routing of every paid feature.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/billing/cctv_plan_source.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/payments/credits_out_sheet.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/plans_v2/buy_inside.dart';
import 'package:assisto/plans_v2/cctv_locked_sheet.dart';
import 'package:assisto/plans_v2/plans_buy_section.dart';
import 'package:assisto/plans_v2/upgrade_sheet.dart';
import 'package:assisto/theme.dart';

import 'cctvprice_fakes.dart';
import 'pay1_fakes.dart';

Widget _app(Widget home, {String lang = 'en', bool dark = false, double scale = 1}) =>
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

/// A locked feature screen: opens the CCTV buy screen, and shows UNLOCKED
/// when it returns true — the "back to the same screen, unlocked" contract.
class _LockedHost extends StatefulWidget {
  const _LockedHost({required this.api, required this.buyer});
  final CctvPlanApi api;
  final CctvPlanBuyer buyer;
  @override
  State<_LockedHost> createState() => _LockedHostState();
}

class _LockedHostState extends State<_LockedHost> {
  bool unlocked = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: unlocked
              ? const Text('UNLOCKED')
              : FilledButton(
                  onPressed: () async {
                    final ok = await showModalBottomSheet<bool>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) =>
                          CctvLockedSheet(api: widget.api, buyer: widget.buyer),
                    );
                    if (ok == true) setState(() => unlocked = true);
                  },
                  child: const Text('open'),
                ),
        ),
      );
}

Future<void> _openCctv(WidgetTester tester, FakeCctvApi api, FakeOffersStore? store,
    {String lang = 'en', bool dark = false, double scale = 1}) async {
  await tester.binding.setSurfaceSize(const Size(400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final buyer = CctvPlanBuyer(api, billing: () async => store);
  await tester.pumpWidget(KeyedSubtree(
      key: UniqueKey(), // a fresh app per call (no sheet left open)
      child: _app(_LockedHost(api: api, buyer: buyer),
          lang: lang, dark: dark, scale: scale)));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The three v2 credit packs on the website APK (server ৳ prices).
PayConfig _packsConfig() => PayConfig.fromJson({
      'channels': [
        {'id': 'gateway', 'enabled': true, 'ready': true, 'label': 'EPS'},
      ],
      'products': {
        'gateway': [
          pay1Product('c50', price: 179, kind: 'pack', credits: 60),
          pay1Product('c120', price: 399, kind: 'pack', credits: 140),
          pay1Product('c300', price: 949, kind: 'pack', credits: 330),
        ],
      },
    });

/// A task screen that keeps the typed text at a paywall and re-sends once.
class _TaskHost extends StatefulWidget {
  const _TaskHost({required this.send});
  final Future<String> Function(String text) send;
  @override
  State<_TaskHost> createState() => _TaskHostState();
}

class _TaskHostState extends State<_TaskHost> {
  final c = TextEditingController(text: 'How do I open a bKash merchant account?');
  String answer = '';
  Future<void> go() async {
    try {
      final a = await widget.send(c.text);
      setState(() {
        answer = a;
        c.clear();
      });
    } catch (e) {
      var again = false;
      if (await BuyInside.handle(context, e, 'ai_chat', then: (ok) => again = ok)) {
        if (again && mounted) return go(); // continues by itself, once
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          TextField(controller: c),
          FilledButton(onPressed: go, child: const Text('send')),
          Text(answer, key: const Key('answer')),
        ]),
      );
}

void main() {
  tearDown(() {
    CreditsOut.debugOffer = null;
    BuyInside.debugOpen = null;
    BuyOrigin.current = '';
  });

  group('CCTV locked screen', () {
    testWidgets('Start 7 days free = Play trial offer; back on the same screen unlocked',
        (tester) async {
      final api = FakeCctvApi();
      final store = FakeOffersStore();
      await _openCctv(tester, api, store);
      expect(find.byKey(const Key('bi-cctv-title')), findsOneWidget);
      expect(find.text('Start 7 days free'), findsOneWidget);
      expect(find.textContaining('a month for 2 cameras'), findsOneWidget);
      expect(find.textContaining('cancel any time · paid with Google Play'), findsOneWidget);
      expect(find.byKey(const Key('bi-cctv-all-plans')), findsOneWidget);
      expect(BuyOrigin.current, 'cctv');
      await tester.tap(find.byKey(const Key('bi-cctv-trial')));
      await tester.pumpAndSettle();
      expect(store.bought, ['cctv_plan/c02-monthly/trial-7d/u1-abc']);
      expect(api.verified, ['cctv_plan:ctok']);
      expect(store.finished, ['ctok']);
      expect(find.text('UNLOCKED'), findsOneWidget);
    });

    testWidgets('price button buys the base plan WITHOUT the trial offer',
        (tester) async {
      final api = FakeCctvApi();
      final store = FakeOffersStore();
      await _openCctv(tester, api, store);
      await tester.tap(find.byKey(const Key('bi-cctv-buy')));
      await tester.pumpAndSettle();
      expect(store.bought, ['cctv_plan/c02-monthly//u1-abc']);
      expect(find.text('UNLOCKED'), findsOneWidget);
    });

    testWidgets('one trial per shop / Google account: server or Play says no -> no trial',
        (tester) async {
      // server: this shop / person already had it
      await _openCctv(tester, FakeCctvApi(cctvPlanPayload(trial: false)), FakeOffersStore());
      expect(find.byKey(const Key('bi-cctv-trial')), findsNothing);
      expect(find.byKey(const Key('bi-cctv-buy')), findsOneWidget);
      // Play: this Google account is not a new customer (offer not listed)
      final store = FakeOffersStore()..offerMap = {'c02-monthly': 'BDT 500.00'};
      await _openCctv(tester, FakeCctvApi(), store);
      expect(find.byKey(const Key('bi-cctv-trial')), findsNothing);
      expect(find.byKey(const Key('bi-cctv-buy')), findsOneWidget);
    });

    testWidgets('cancelled at Google: stays locked, honest note, nothing granted',
        (tester) async {
      final store = FakeOffersStore()
        ..next = const StoreBuyResult(StoreBuyStatus.cancelled);
      final api = FakeCctvApi();
      await _openCctv(tester, api, store);
      await tester.tap(find.byKey(const Key('bi-cctv-trial')));
      await tester.pumpAndSettle();
      expect(api.verified, isEmpty);
      expect(find.byKey(const Key('bi-cctv-note')), findsOneWidget);
      expect(find.text('UNLOCKED'), findsNothing);
    });

    testWidgets('no Play client (website APK): no fake buy button, plans link stays',
        (tester) async {
      await _openCctv(tester, FakeCctvApi(), null);
      expect(find.byKey(const Key('bi-cctv-trial')), findsNothing);
      expect(find.byKey(const Key('bi-cctv-buy')), findsNothing);
      expect(find.byKey(const Key('bi-cctv-nostore')), findsOneWidget);
      expect(find.byKey(const Key('bi-cctv-all-plans')), findsOneWidget);
    });

    testWidgets('Bangla, dark, 200% font: no overflow, 48dp targets', (tester) async {
      await _openCctv(tester, FakeCctvApi(), FakeOffersStore(),
          lang: 'bn', dark: true, scale: 2);
      expect(tester.takeException(), isNull);
      for (final k in ['bi-cctv-trial', 'bi-cctv-buy', 'bi-cctv-all-plans']) {
        expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48));
      }
    });

    test('restore re-sends every CCTV purchase Play still holds to the server', () async {
      final api = FakeCctvApi();
      final store = FakeOffersStore()
        ..ownedList = const [
          StoreOwned('cctv_plan', 't1'),
          StoreOwned('cctv_plan', 't1'), // the same token once
          StoreOwned('credits_p50', 't2'), // not CCTV
        ];
      final n = await CctvPlanBuyer(api, billing: () async => store)
          .restore({'cctv_plan', 'cctv_video'});
      expect(n, 1);
      expect(api.verified, ['cctv_plan:t1']);
    });
  });

  group('credits finished — inside the task', () {
    testWidgets('keeps the typed text; after a purchase the answer continues by itself',
        (tester) async {
      var calls = 0;
      final offered = <String>[];
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async {
        offered.add('$screen:$draftKept');
        return true; // credits landed
      };
      await tester.pumpWidget(_app(_TaskHost(send: (text) async {
        calls++;
        if (calls == 1) {
          throw ApiException('no credits', 402, null, 'credits',
              {'reason': 'credits', 'code': 'out_of_credits', 'need': 1});
        }
        return 'answer for: $text';
      })));
      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      expect(offered, ['ai_chat:true']);
      expect(calls, 2); // re-sent ONCE, automatically
      expect(find.text('answer for: How do I open a bKash merchant account?'),
          findsOneWidget);
    });

    testWidgets('closing the sheet keeps the text in the box, nothing re-sent',
        (tester) async {
      var calls = 0;
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async => false;
      await tester.pumpWidget(_app(_TaskHost(send: (text) async {
        calls++;
        throw ApiException('no credits', 402, null, 'credits', {'reason': 'credits'});
      })));
      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('How do I open a bKash merchant account?'), findsOneWidget);
    });

    testWidgets('packs 179 = 60, 399 = 140 (best value), 949 = 330 + 2 ads = 1 answer',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final b = FakePaymentsBackend(cfg: _packsConfig());
      await tester.pumpWidget(_app(Scaffold(
          body: CreditsOutSheet(
              screen: 'ai_chat',
              draftKept: true,
              backend: b,
              flavour: 'apk',
              adsAvailable: (_) async => true))));
      await tester.pumpAndSettle();
      expect(find.textContaining('৳179'), findsOneWidget);
      expect(find.textContaining('৳399'), findsOneWidget);
      expect(find.textContaining('৳949'), findsOneWidget);
      expect(find.byKey(const ValueKey('credout-best-c120')), findsOneWidget);
      expect(find.byKey(const ValueKey('credout-best-c50')), findsNothing);
      expect(find.byKey(const ValueKey('credout-best-c300')), findsNothing);
      expect(find.textContaining('2 short ads = 1 Normal answer'), findsOneWidget);
    });

    test('every credit 402 spelling opens the same sheet', () {
      for (final r in ['credits', 'out_of_credits', 'insufficient', 'no_credits', 'ai_insufficient']) {
        expect(isOutOfCredits(ApiException('x', 402, null, r)), isTrue, reason: r);
      }
      expect(isOutOfCredits(ApiException('x', 402, null, 'plan_required')), isFalse);
    });
  });

  group('routing: every paid feature opens the RIGHT buy screen', () {
    test('every unlock type is covered and keys are unique snake_case', () {
      expect(kPaidFeatures.length, greaterThanOrEqualTo(40));
      for (final e in kPaidFeatures.entries) {
        expect(e.key, e.value.key);
        expect(RegExp(r'^[a-z0-9_]{2,40}$').hasMatch(e.key), isTrue, reason: e.key);
      }
      expect(kPaidFeatures['cctv']!.unlock, Unlock.cctv);
      expect(kPaidFeatures['reports']!.unlock, Unlock.business);
      expect(kPaidFeatures['video_call']!.unlock, Unlock.premium);
      expect(kPaidFeatures['ai_chat']!.unlock, Unlock.credits);
    });

    testWidgets('a credit feature opens the credits sheet; a plan feature the plan sheet',
        (tester) async {
      final seen = <String>[];
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async {
        seen.add(screen);
        return false;
      };
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      })));
      expect(await BuyInside.open(ctx, 'photo_studio'), isFalse);
      expect(seen, ['photo_studio']);
      expect(BuyOrigin.current, 'photo_studio');
      // a plan feature: the plan sheet with the feature's own name
      BuyInside.open(ctx, 'video_call');
      await tester.pumpAndSettle();
      expect(find.byType(UpgradeSheet), findsOneWidget);
      expect(find.text('Video calls'), findsOneWidget);
    });

    test('handle() knows the plan refusals (call link 402, storage 413)', () async {
      // pure classification via debugOpen
      final opened = <String>[];
      BuyInside.debugOpen = (ctx, key) async {
        opened.add(key);
        return true;
      };
      final ctx = _FakeContext();
      expect(
          await BuyInside.handle(ctx, ApiException('x', 402, null, null,
              {'detail': 'premium_only', 'upgrade_required': true}), 'call_link'),
          isTrue);
      expect(
          await BuyInside.handle(ctx, ApiException('x', 413, null, null,
              {'error': 'storage_full'}), 'storage'),
          isTrue);
      expect(await BuyInside.handle(ctx, ApiException('x', 500), 'storage'), isFalse);
      expect(await BuyInside.handle(ctx, Exception('net'), 'storage'), isFalse);
      expect(opened, ['call_link', 'storage']);
    });
  });

  testWidgets('plans page: a recommendation only from real usage, CCTV plan, manage',
      (tester) async {
    await tester.pumpWidget(_app(const Scaffold(
        body: SingleChildScrollView(
            child: PlansBuySection(
                flavour: 'play',
                preview: {
          'recommend': {'plan': 'premium', 'price': 449, 'saves_bdt': 129},
          'text': 'In the last 30 days you used 150 credits and paid ৳578 in total.',
        })))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bi-recommend')), findsOneWidget);
    expect(find.byKey(const Key('bi-manage-sub')), findsOneWidget);
    // no saving -> no card at all (never a guess)
    await tester.pumpWidget(_app(const Scaffold(
        body: PlansBuySection(flavour: 'apk', preview: {'recommend': null}))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bi-recommend')), findsNothing);
    expect(find.byKey(const Key('bi-manage-sub')), findsNothing); // Play only
  });
}

class _FakeContext extends Fake implements BuildContext {}
