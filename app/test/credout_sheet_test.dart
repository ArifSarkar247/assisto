// credout: the ONE out-of-AI-credits sheet. Play build lists the four Play
// packs (credits_p20/p50/p100/p200) with Play's localized price (never EPS);
// the website APK lists the gateway packs; the rewarded-ad row only where
// allowed; packs are consumable (bought again and again); cancel / pending /
// failure keep the draft; a verified purchase returns true so the caller
// retries the request ONCE (home chat + Ask the web screen tests below).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/credits_out_sheet.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/play_prices.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/screens/world/world_ask_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/world/world_api.dart';

import 'fake_api.dart';
import 'pay1_fakes.dart';

Map<String, dynamic> _pack(String id, int price, int credits) => {
      'sku': 'pack_$id',
      'kind': 'pack',
      'credits': credits,
      'price_bdt': price,
      'title': '$credits',
      'play_product_id': 'credits_$id',
      'play_base_plan': '',
    };

final _packs = [
  _pack('p200', 200, 240), // out of order on purpose: sheet sorts by price
  _pack('p20', 20, 20),
  _pack('p100', 100, 115),
  _pack('p50', 50, 55),
];

PayConfig _cfg({bool play = true, bool gw = true}) => PayConfig.fromJson({
      'channels': [
        {'id': 'play', 'enabled': play, 'ready': play},
        {'id': 'gateway', 'enabled': gw, 'ready': gw},
      ],
      'products': {
        'play': [pay1Product('premium_monthly'), ..._packs],
        'gateway': [pay1Product('premium_monthly'), ..._packs],
      },
      'play_account_id': 'u7-abc',
    });

const _packVerify = PayResult(
    ok: true, data: {'ok': true, 'state': 'granted', 'granted': 20, 'consumed': true});

class _Harness {
  bool? result;
  int billingLoads = 0;
  final gatewaySkus = <String>[];
  int adTaps = 0;
}

Future<_Harness> _open(
  WidgetTester tester, {
  required FakePaymentsBackend backend,
  FakeStoreBilling? billing,
  String flavour = 'play',
  String screen = 'ai_chat',
  bool ads = false,
  bool adCredits = true,
  bool gatewayOk = true,
  String lang = 'en',
  double scale = 1,
  ThemeMode mode = ThemeMode.light,
}) async {
  final h = _Harness();
  PlayPrices.debugReset();
  StoreBilling.debugOverride = billing;
  addTearDown(() {
    StoreBilling.debugOverride = null;
    PlayPrices.debugReset();
  });
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
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
    builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: FilledButton(
            onPressed: () async {
              h.result = await showModalBottomSheet<bool>(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => CreditsOutSheet(
                  screen: screen,
                  draftKept: true,
                  backend: backend,
                  flavour: flavour,
                  billing: () async {
                    h.billingLoads++;
                    return billing;
                  },
                  adsAvailable: (_) async => ads,
                  watchAd: (_) async {
                    h.adTaps++;
                    return adCredits;
                  },
                  gatewayCheckout: (_, sku) async {
                    h.gatewaySkus.add(sku);
                    return gatewayOk;
                  },
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return h;
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(CreditsOutSheet)));

Finder _row(String id) => find.byKey(ValueKey('credout-pack-pack_$id'));

void main() {
  testWidgets('Play build: the 4 Play packs, cheapest first, Play price, no EPS',
      (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg());
    final billing = FakeStoreBilling()
      ..priceMap = {
        'credits_p20': 'BDT 20.00',
        'credits_p50': 'BDT 50.00',
        'credits_p100': 'BDT 100.00',
        'credits_p200': 'BDT 200.00',
      };
    await _open(tester, backend: b, billing: billing);
    final t = _t(tester);
    expect(b.calls.first, 'config:play');
    expect(find.text(t.credoutTitle), findsOneWidget);
    expect(find.text(t.credoutBodyDraft), findsOneWidget);
    for (final id in ['p20', 'p50', 'p100', 'p200']) {
      expect(_row(id), findsOneWidget, reason: id);
    }
    // sorted by price
    final ys = [for (final id in ['p20', 'p50', 'p100', 'p200']) tester.getTopLeft(_row(id)).dy];
    expect(ys, [...ys]..sort());
    expect(find.text('BDT 50.00'), findsOneWidget); // Play's own price
    expect(find.text(t.credoutPlayNote), findsOneWidget);
    expect(find.text(t.payGatewayTitle), findsNothing); // never EPS on Play
    expect(find.text(t.credoutNoCash), findsOneWidget);
  });

  testWidgets('Play build in Bangla: store price with Bangla digits; 200% font + '
      'dark mode: no overflow', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg());
    final billing = FakeStoreBilling()..priceMap = {'credits_p20': 'BDT 20.00'};
    await _open(tester,
        backend: b, billing: billing, lang: 'bn', scale: 2, mode: ThemeMode.dark, ads: true);
    expect(tester.takeException(), isNull);
    // ASCII 20.00 -> Bangla digits (code points, no Bangla literal needed)
    final bn20 = String.fromCharCodes([0x09E8, 0x09E6, 0x2E, 0x09E6, 0x09E6]);
    expect(find.text('BDT $bn20'), findsOneWidget);
    // a pack without a store price: honest "unavailable", never the server ৳
    final t = _t(tester);
    expect(find.text(t.payPriceUnavailable), findsNWidgets(3));
    expect(find.byKey(const Key('credout-price-retry')), findsOneWidget);
    expect(tester.getSize(_row('p20')).height, greaterThanOrEqualTo(48));
  });

  testWidgets('consumable: p20 bought twice — two purchases, two verifies, the '
      'second is never blocked', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg())..verifyResult = _packVerify;
    final billing = FakeStoreBilling()
      ..next = const StoreBuyResult(StoreBuyStatus.purchased,
          purchaseToken: 'tok-A', productId: 'credits_p20');
    var h = await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p20'));
    await tester.pumpAndSettle();
    expect(h.result, isTrue);
    billing.next = const StoreBuyResult(StoreBuyStatus.purchased,
        purchaseToken: 'tok-B', productId: 'credits_p20');
    h = await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p20'));
    await tester.pumpAndSettle();
    expect(h.result, isTrue);
    expect(billing.bought, ['credits_p20//false/u7-abc', 'credits_p20//false/u7-abc']);
    expect(b.calls.where((c) => c.startsWith('verify:pack:credits_p20:')).toList(),
        ['verify:pack:credits_p20:tok-A', 'verify:pack:credits_p20:tok-B']);
    expect(billing.finished, ['tok-A', 'tok-B']);
    expect(billing.consumed, isEmpty); // the server consumed both
  });

  testWidgets('server could not consume -> the app consumes (re-buyable)',
      (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg())
      ..verifyResult = const PayResult(
          ok: true, data: {'ok': true, 'state': 'granted', 'consumed': false});
    final billing = FakeStoreBilling()
      ..next = const StoreBuyResult(StoreBuyStatus.purchased, purchaseToken: 'tok-C');
    final h = await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p50'));
    await tester.pumpAndSettle();
    expect(h.result, isTrue);
    expect(billing.consumed, ['tok-C']);
  });

  testWidgets('cancel keeps the sheet + the draft; Not now returns false (no retry)',
      (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg());
    final billing = FakeStoreBilling()
      ..next = const StoreBuyResult(StoreBuyStatus.cancelled);
    final h = await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p100'));
    await tester.pumpAndSettle();
    final t = _t(tester);
    expect(find.text(t.credoutCancelledKept), findsOneWidget);
    expect(b.calls.any((c) => c.startsWith('verify')), isFalse);
    await tester.tap(find.byKey(const Key('credout-not-now')));
    await tester.pumpAndSettle();
    expect(h.result, isFalse);
  });

  testWidgets('pending purchase: honest note, nothing granted, sheet stays',
      (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg());
    final billing = FakeStoreBilling()
      ..next = const StoreBuyResult(StoreBuyStatus.pending);
    final h = await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p20'));
    await tester.pumpAndSettle();
    expect(find.text(_t(tester).credoutPendingKept), findsOneWidget);
    expect(h.result, isNull);
  });

  testWidgets('store error: an unconsumed earlier pack is reconciled with the '
      'server first (granted -> done)', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg())..verifyResult = _packVerify;
    final billing = FakeStoreBilling()
      ..next = const StoreBuyResult(StoreBuyStatus.error, error: 'itemAlreadyOwned')
      ..ownedList = [const StoreOwned('credits_p20', 'old-tok')];
    final h = await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p20'));
    await tester.pumpAndSettle();
    expect(b.calls, contains('verify:pack:credits_p20:old-tok'));
    expect(h.result, isTrue);
  });

  testWidgets('Play store unavailable: no price -> honest "price unavailable", '
      'buy disabled, never the server taka', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg());
    final h = await _open(tester, backend: b, billing: null);
    final t = _t(tester);
    expect(find.text(t.payPriceUnavailable), findsNWidgets(4));
    expect(find.textContaining('\u09F3'), findsNothing);
    await tester.tap(_row('p20'));
    await tester.pumpAndSettle();
    expect(b.calls.where((c) => c.startsWith('precheck')), isEmpty);
    expect(h.result, isNull);
  });

  testWidgets('Play billing fails at buy time: honest message, no other way '
      'to pay named', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg());
    final billing = FakeStoreBilling()
      ..next = const StoreBuyResult(StoreBuyStatus.unavailable);
    final h = await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p20'));
    await tester.pumpAndSettle();
    expect(find.text(_t(tester).payPlayUnavailableNoAlt), findsOneWidget);
    expect(find.text(_t(tester).payGatewayTitle), findsNothing);
    expect(h.result, isNull);
  });

  testWidgets('Play price shown is the store formattedPrice, never priceBdt',
      (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg());
    final billing = FakeStoreBilling()
      ..priceMap = {
        'credits_p20': 'US\$0.25',
        'credits_p50': 'US\$0.60',
        'credits_p100': 'US\$1.19',
        'credits_p200': 'US\$2.39',
      };
    await _open(tester, backend: b, billing: billing);
    expect(find.text('US\$0.60'), findsOneWidget);
    expect(find.textContaining('\u09F3'), findsNothing); // no server ৳ number
    expect(billing.priceQueries.single,
        {'credits_p20', 'credits_p50', 'credits_p100', 'credits_p200'});
  });

  testWidgets('double tap starts ONE purchase', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg())..verifyResult = _packVerify;
    final billing = FakeStoreBilling();
    await _open(tester, backend: b, billing: billing);
    await tester.tap(_row('p20'));
    await tester.tap(_row('p50'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(billing.bought.length, 1);
  });

  testWidgets('offline: honest state + retry', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg(), failConfig: true);
    await _open(tester, backend: b, billing: FakeStoreBilling());
    expect(find.text(_t(tester).payNetwork), findsOneWidget);
    b.failConfig = false;
    await tester.tap(find.byKey(const Key('credout-retry')));
    await tester.pumpAndSettle();
    expect(_row('p20'), findsOneWidget);
  });

  testWidgets('website APK: gateway packs; Play Billing never loaded',
      (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg(play: false));
    final h = await _open(tester, backend: b, billing: FakeStoreBilling(), flavour: 'apk');
    expect(b.calls.first, 'config:apk');
    expect(find.text(_t(tester).credoutGatewayNote), findsOneWidget);
    await tester.tap(_row('p50'));
    await tester.pumpAndSettle();
    expect(h.gatewaySkus, ['pack_p50']);
    expect(h.billingLoads, 0);
    expect(h.result, isTrue);
  });

  testWidgets('no live channel: honest line, no dead pack buttons', (tester) async {
    final b = FakePaymentsBackend(cfg: _cfg(play: false, gw: false));
    await _open(tester, backend: b, billing: FakeStoreBilling());
    expect(find.byKey(const Key('credout-none')), findsOneWidget);
    expect(_row('p20'), findsNothing);
  });

  group('rewarded-ad row', () {
    testWidgets('Free user on an AI screen with ads available: shown; a verified '
        'reward returns true', (tester) async {
      final b = FakePaymentsBackend(cfg: _cfg());
      final h = await _open(tester, backend: b, billing: FakeStoreBilling(), ads: true);
      expect(find.byKey(const Key('credout-ad')), findsOneWidget);
      await tester.tap(find.byKey(const Key('credout-ad')));
      await tester.pumpAndSettle();
      expect(h.adTaps, 1);
      expect(h.result, isTrue);
    });

    testWidgets('Premium / AdMob off / cap reached (not available): hidden',
        (tester) async {
      final b = FakePaymentsBackend(cfg: _cfg());
      await _open(tester, backend: b, billing: FakeStoreBilling(), ads: false);
      expect(find.byKey(const Key('credout-ad')), findsNothing);
      expect(_row('p20'), findsOneWidget); // Premium still gets the packs
    });

    for (final screen in ['circle', 'business', 'vehicle', 'world_hub', 'sos', 'call']) {
      testWidgets('never on "$screen" even when an ad could play', (tester) async {
        final b = FakePaymentsBackend(cfg: _cfg());
        await _open(tester,
            backend: b, billing: FakeStoreBilling(), ads: true, screen: screen);
        expect(find.byKey(const Key('credout-ad')), findsNothing);
      });
    }

    testWidgets('a dismissed ad does not close the sheet', (tester) async {
      final b = FakePaymentsBackend(cfg: _cfg());
      final h = await _open(tester,
          backend: b, billing: FakeStoreBilling(), ads: true, adCredits: false);
      await tester.tap(find.byKey(const Key('credout-ad')));
      await tester.pumpAndSettle();
      expect(h.result, isNull);
      expect(find.byKey(const Key('credout-ad')), findsOneWidget);
    });
  });

  group('error detection', () {
    test('402 credits/out_of_credits/insufficient only', () {
      expect(isOutOfCredits(ApiException('x', 402, null, 'credits')), isTrue);
      expect(isOutOfCredits(ApiException('x', 402, null, 'out_of_credits')), isTrue);
      expect(isOutOfCredits(ApiException('x', 402, null, 'premium_required')), isFalse);
      expect(isOutOfCredits(ApiException('x', 402)), isFalse);
      expect(isOutOfCredits(ApiException('x', 500, null, 'credits')), isFalse);
      expect(isOutOfCreditsBody({'_status': 402, 'ok': false, 'reason': 'credits'}), isTrue);
      expect(isOutOfCreditsBody({'_status': 402, 'ok': false, 'reason': 'locked'}), isFalse);
    });
  });

  // ------------------------------------------------------------ screens
  group('draft kept + retry once', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() => CreditsOut.debugOffer = null);

    testWidgets('home chat: 402 -> text back in the box + sheet; bought -> sent '
        'again once and answered', (tester) async {
      final api = _CreditsApi(fails: 1);
      final app = _stub(api);
      var offers = 0;
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async {
        offers++;
        expect(screen, 'home');
        expect(draftKept, isTrue);
        // the draft is already back in the box while the sheet is open
        expect(find.widgetWithText(TextField, 'how far is the moon'), findsOneWidget);
        return true;
      };
      await tester.pumpWidget(_app(app, const AgentThreadScreen(debugSeed: [])));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'how far is the moon');
      await tester.pump();
      await tester.tap(find.byTooltip(AppLocalizations.of(
              tester.element(find.byType(AgentThreadScreen)))
          .send));
      await _settle(tester);
      expect(offers, 1);
      expect(api.sent, ['how far is the moon', 'how far is the moon']);
      expect(find.text('About 384,000 km.'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'how far is the moon'), findsNothing);
    });

    testWidgets('home chat: cancel -> no retry, the text stays in the box',
        (tester) async {
      final api = _CreditsApi(fails: 1);
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async => false;
      await tester.pumpWidget(_app(_stub(api), const AgentThreadScreen(debugSeed: [])));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'plan my day');
      await tester.pump();
      await tester.tap(find.byTooltip(AppLocalizations.of(
              tester.element(find.byType(AgentThreadScreen)))
          .send));
      await _settle(tester);
      expect(api.sent, ['plan my day']);
      expect(find.widgetWithText(TextField, 'plan my day'), findsOneWidget);
    });

    testWidgets('home chat: still out after buying -> no loop, draft kept',
        (tester) async {
      final api = _CreditsApi(fails: 5);
      var offers = 0;
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async {
        offers++;
        return true;
      };
      await tester.pumpWidget(_app(_stub(api), const AgentThreadScreen(debugSeed: [])));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'tell me a joke');
      await tester.pump();
      await tester.tap(find.byTooltip(AppLocalizations.of(
              tester.element(find.byType(AgentThreadScreen)))
          .send));
      await _settle(tester);
      expect(offers, 1);
      expect(api.sent.length, 2); // original + exactly one retry
      expect(find.widgetWithText(TextField, 'tell me a joke'), findsOneWidget);
    });

    testWidgets('Ask the web: 402 -> question kept, retried once after buying',
        (tester) async {
      final w = _WorldFake(fails: 1);
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async {
        expect(screen, 'world');
        expect(find.widgetWithText(TextField, 'price of rice today'), findsOneWidget);
        return true;
      };
      await tester.pumpWidget(_app(_stub(FakeApi(lang: 'en')), WorldAskScreen(api: w)));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'price of rice today');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded).first, warnIfMissed: false);
      await _settle(tester);
      expect(w.asked, ['price of rice today', 'price of rice today']);
      expect(find.textContaining('Rice is 60'), findsOneWidget);
    });

    testWidgets('Ask the web: cancel -> question stays, asked once', (tester) async {
      final w = _WorldFake(fails: 1);
      CreditsOut.debugOffer = (ctx, {required screen, required draftKept}) async => false;
      await tester.pumpWidget(_app(_stub(FakeApi(lang: 'en')), WorldAskScreen(api: w)));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'price of rice today');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded).first, warnIfMissed: false);
      await _settle(tester);
      expect(w.asked, ['price of rice today']);
      expect(find.widgetWithText(TextField, 'price of rice today'), findsOneWidget);
    });
  });
}

// ------------------------------------------------------------ screen fakes
class _CreditsApi extends FakeApi {
  _CreditsApi({required this.fails}) : super(lang: 'en');
  int fails;
  final sent = <String>[];

  @override
  Future<Map<String, dynamic>> agent(String text, {String? sessionId}) async {
    sent.add(text);
    if (fails > 0) {
      fails--;
      throw ApiException('out', 402, null, 'credits');
    }
    return {'reply': 'About 384,000 km.', 'cards': [], 'session_id': '5'};
  }
}

class _WorldFake implements WorldApi {
  _WorldFake({required this.fails});
  int fails;
  final asked = <String>[];

  @override
  Future<Map<String, dynamic>> ask(String question, String lang) async {
    asked.add(question);
    if (fails > 0) {
      fails--;
      return {'_status': 402, 'ok': false, 'reason': 'credits', 'message': 'Not enough credits.'};
    }
    return {'_status': 200, 'ok': true, 'answer': 'Rice is 60 taka a kg [1].', 'sources': []};
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

AppState _stub(ApiClient api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(AppState s, Widget child) => ChangeNotifierProvider<AppState>.value(
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
        theme: AssistoTheme.light,
        home: Scaffold(body: child),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
