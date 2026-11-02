// cctvprice: fakes + gallery payloads for the CCTV plan screen.
import 'package:assisto/billing/cctv_plan_source.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/store_billing.dart';

Map<String, dynamic> cctvPlanPayload(
    {Map<String, dynamic>? status,
    bool onSale = true,
    bool trial = true,
    int used = 0,
    Map<String, dynamic>? notice,
    List<int> addonCams = const [],
    List<Map<String, dynamic>> cameras = const []}) {
  int m(int n) => 500 + 250 * ((n < 2 ? 2 : n) - 2);
  return {
    'on_sale': onSale,
    'play_ready': true,
    'product_id': 'cctv_plan',
    'addon_product_id': 'cctv_video',
    'trial_offer_id': 'trial-7d',
    'trial_days': 7,
    'trial_base_plan': 'c02-monthly',
    'trial_available': trial,
    'base_cameras': 2,
    'base_price': 500,
    'extra_camera_price': 250,
    'max_cameras': 10,
    'tiers': [
      for (var n = 1; n <= 10; n++) {'cameras': n, 'monthly': m(n), 'yearly': 12 * m(n)}
    ],
    'addon': {
      'days': [7, 30],
      'price_per_camera': {'7': 100, '30': 150},
    },
    'status': status ??
        {
          'status': 'none',
          'cameras': 0,
          'period': '',
          'trial_used': !trial,
          'addon': {'status': 'none', 'days': 0, 'cameras': 0},
        },
    'cameras_used': used,
    'over_by': 0,
    'addon_cameras': addonCams,
    'cameras': cameras,
    'notice': notice,
    'unpaid_line': 'If unpaid: after Google\'s waiting time the cameras are released '
        'from Assisto, your data is kept 30 days and then deleted — you get a '
        'notice before every step.',
    'play_account_id': 'u1-abc',
    'limits': {'relay_mb_per_camera': 300, 'ai_checks_per_camera': 50, 'owner_confirmed': false},
  };
}

Map<String, dynamic> cctvActiveStatus({int cams = 3, bool yearly = false, bool addon = false}) => {
      'status': 'active',
      'cameras': cams,
      'period': yearly ? 'yearly' : 'monthly',
      'base_plan': cctvBasePlan(cams, yearly),
      'expires_at': '2026-12-03T10:00:00Z',
      'auto_renew': true,
      'in_trial': false,
      'trial_used': true,
      'addon': addon
          ? {'status': 'active', 'days': 7, 'cameras': 2, 'base_plan': 'd7-c02'}
          : {'status': 'none', 'days': 0, 'cameras': 0},
    };

const kCctvOffers = {
  'c02-monthly': 'BDT 500.00',
  'c02-monthly#trial-7d': 'BDT 500.00',
  'c03-monthly': 'BDT 750.00',
};

class FakeCctvApi implements CctvPlanApi {
  Map<String, dynamic> payload;
  final verified = <String>[];
  List<int> saved = const [];
  bool fail = false;
  FakeCctvApi([Map<String, dynamic>? p]) : payload = p ?? cctvPlanPayload();

  @override
  Future<Map<String, dynamic>> load() async {
    if (fail) throw Exception('offline');
    return payload;
  }

  @override
  Future<List<int>> setAddonCameras(List<int> ids) async => saved = ids;

  @override
  Future<PayResult> verify(String productId, String purchaseToken) async {
    verified.add('$productId:$purchaseToken');
    return PayResult(ok: true, data: {'entitled': true});
  }
}

/// A Play client that can list offers (like the real one).
class FakeOffersStore implements StoreBilling, StoreOffers {
  final bought = <String>[];
  final finished = <String>[];
  Map<String, String> offerMap = Map.of(kCctvOffers);
  List<StoreOwned> ownedList = [];
  StoreBuyResult next = const StoreBuyResult(StoreBuyStatus.purchased, purchaseToken: 'ctok');

  @override
  Future<Map<String, String>> offers(String productId) async =>
      productId == 'cctv_plan' ? offerMap : const {};

  @override
  Future<StoreBuyResult> buyOffer(
      {required String productId,
      required String basePlanId,
      String offerId = '',
      required String accountId}) async {
    bought.add('$productId/$basePlanId/$offerId/$accountId');
    return next;
  }

  @override
  Future<StoreBuyResult> buy(
          {required String productId,
          required String basePlanId,
          required bool isSubscription,
          required String accountId}) async =>
      next;

  @override
  Future<void> finish(String purchaseToken) async => finished.add(purchaseToken);

  @override
  Future<List<StoreOwned>> owned() async => ownedList;

  @override
  Future<Map<String, String>> prices(Set<String> productIds) async => const {};

  @override
  Future<void> consume(String purchaseToken) async {}
}
