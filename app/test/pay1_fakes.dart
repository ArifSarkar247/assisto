// pay1: fakes for the checkout sheet tests + gallery (no network, no Play).
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/store_billing.dart';

Map<String, dynamic> pay1Product(String sku,
        {int price = 199, String kind = 'sub', int credits = 0}) =>
    {
      'sku': sku,
      'kind': kind,
      'plan': sku.split('_').first,
      'period': sku.endsWith('yearly') ? 'yearly' : 'monthly',
      'months': sku.endsWith('yearly') ? 12 : 1,
      'credits': credits,
      'price_bdt': price,
      'title': kind == 'sub' ? 'Premium' : '$credits credits',
      'play_product_id': kind == 'sub' ? 'assisto_premium' : 'credits_p50',
      'play_base_plan': kind == 'sub' ? 'monthly' : '',
    };

PayConfig pay1Config({
  bool play = true,
  bool playEnabled = true,
  bool playReady = true,
  bool gwEnabled = true,
  bool gwReady = true,
}) =>
    PayConfig.fromJson({
      'channels': [
        if (play)
          {'id': 'play', 'enabled': playEnabled, 'ready': playReady, 'label': 'Google Play'},
        {'id': 'gateway', 'enabled': gwEnabled, 'ready': gwReady, 'label': 'EPS'},
      ],
      'products': {
        'play': [pay1Product('premium_monthly'), pay1Product('pack_p50', price: 50, kind: 'pack', credits: 55)],
        'gateway': [pay1Product('premium_monthly'), pay1Product('pack_p50', price: 50, kind: 'pack', credits: 55)],
      },
      'play_account_id': 'u7-abc',
    });

class FakePaymentsBackend implements PaymentsBackend {
  PayConfig cfg;
  bool failConfig;
  PayResult checkoutResult = const PayResult(ok: true, data: {
    'ok': true,
    'order': {'id': 41, 'status': 'pending', 'redirect_url': 'https://sandboxpg.eps.com.bd/PG?data=x'}
  });
  List<PayResult> orderResults = [];
  PayResult precheckResult =
      const PayResult(ok: true, data: {'ok': true, 'play_account_id': 'u7-abc'});
  PayResult verifyResult = const PayResult(
      ok: true, data: {'ok': true, 'entitled': true, 'state': 'SUBSCRIPTION_STATE_ACTIVE'});
  /// pay-e2e: per-token verify answers (restore tests); falls back to
  /// [verifyResult]. A list is consumed one answer per call.
  final verifyByToken = <String, List<PayResult>>{};
  final calls = <String>[];

  FakePaymentsBackend({PayConfig? cfg, this.failConfig = false})
      : cfg = cfg ?? pay1Config();

  @override
  Future<PayConfig> config(String flavour) async {
    calls.add('config:$flavour');
    if (failConfig) throw Exception('offline');
    return cfg;
  }

  @override
  Future<PayResult> checkout(String sku, String idem, String flavour) async {
    calls.add('checkout:$sku:$flavour');
    return checkoutResult;
  }

  @override
  Future<PayResult> order(int id) async {
    calls.add('order:$id');
    return orderResults.isNotEmpty
        ? orderResults.removeAt(0)
        : const PayResult(ok: true, data: {'ok': true, 'order': {'id': 41, 'status': 'pending'}});
  }

  @override
  Future<PayResult> playPrecheck(String sku) async {
    calls.add('precheck:$sku');
    return precheckResult;
  }

  @override
  Future<PayResult> playVerify(
      {required String kind,
      required String productId,
      required String purchaseToken}) async {
    calls.add('verify:$kind:$productId:$purchaseToken');
    final l = verifyByToken[purchaseToken];
    if (l != null && l.isNotEmpty) return l.length == 1 ? l.first : l.removeAt(0);
    return verifyResult;
  }
}

/// A fake Google Play client (the real one is never loaded in tests).
class FakeStoreBilling implements StoreBilling {
  StoreBuyResult next =
      const StoreBuyResult(StoreBuyStatus.purchased, purchaseToken: 'tok-1');
  final bought = <String>[];
  final finished = <String>[];

  @override
  Future<StoreBuyResult> buy(
      {required String productId,
      required String basePlanId,
      required bool isSubscription,
      required String accountId}) async {
    bought.add('$productId/$basePlanId/$isSubscription/$accountId');
    return next;
  }

  @override
  Future<void> finish(String purchaseToken) async => finished.add(purchaseToken);

  /// pay-e2e: what Play still holds for this Google account.
  List<StoreOwned> ownedList = [];
  @override
  Future<List<StoreOwned>> owned() async => ownedList;
}
