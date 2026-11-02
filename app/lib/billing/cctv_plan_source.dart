import '../api.dart';
import '../payments/payments_api.dart';
import '../payments/store_billing.dart';

/// cctvprice — the CCTV plan: data + buying (owner's CCTV order 3 Nov, H).
///
/// The SERVER is the source of every number (GET /shop/cctv-plan: tiers 1..10
/// with exact prices, yearly = 12x, the add-on prices, the Play product /
/// base-plan / trial-offer ids, status, notices). Google Play's own price
/// string is shown on the buy button when Play answers. Buying uses the
/// EXISTING Play path: purchase -> POST /payments/play/verify (the server
/// verifies with Google, acknowledges, counts revenue; RTDN as backup).
abstract class CctvPlanApi {
  Future<Map<String, dynamic>> load();
  Future<List<int>> setAddonCameras(List<int> ids);
  Future<PayResult> verify(String productId, String purchaseToken);
}

class ApiCctvPlanApi implements CctvPlanApi {
  final ApiClient api;
  ApiCctvPlanApi(this.api);

  @override
  Future<Map<String, dynamic>> load() => api.getJson('/shop/cctv-plan');

  @override
  Future<List<int>> setAddonCameras(List<int> ids) async {
    final j = await api.postJson('/shop/cctv-plan/addon-cameras', {'ids': ids});
    return [for (final i in (j['addon_cameras'] as List? ?? const [])) (i as num).toInt()];
  }

  @override
  Future<PayResult> verify(String productId, String purchaseToken) =>
      ApiPaymentsBackend(api).playVerify(
          kind: 'sub', productId: productId, purchaseToken: purchaseToken);
}

/// Base plan id for a camera count: 1 camera buys the 2-camera base.
String cctvBasePlan(int cameras, bool yearly) {
  final n = cameras < 2 ? 2 : cameras;
  return 'c${n.toString().padLeft(2, '0')}-${yearly ? 'yearly' : 'monthly'}';
}

String cctvAddonPlan(int days, int cameras) =>
    'd$days-c${cameras.toString().padLeft(2, '0')}';

/// One tier row from the server.
class CctvTier {
  final int cameras, monthly, yearly;
  const CctvTier(this.cameras, this.monthly, this.yearly);
  static List<CctvTier> list(Object? raw) => [
        for (final m in (raw is List ? raw : const []).whereType<Map>())
          CctvTier((m['cameras'] as num).toInt(), (m['monthly'] as num).toInt(),
              (m['yearly'] as num).toInt())
      ];
}

enum CctvBuyStatus { done, pending, cancelled, unavailable, failed }

/// Talks to Google Play for the CCTV products. Null-safe on the website APK
/// (no Play client) and with a Play client that cannot list offers.
class CctvPlanBuyer {
  final CctvPlanApi api;
  final Future<StoreBilling?> Function() billing;
  CctvPlanBuyer(this.api, {Future<StoreBilling?> Function()? billing})
      : billing = billing ?? StoreBilling.forThisBuild;

  Future<StoreOffers?> _offers() async {
    try {
      final b = await billing();
      return b is StoreOffers ? b as StoreOffers : null;
    } catch (_) {
      return null;
    }
  }

  /// Can this build buy at all (the Play build with a working client)?
  Future<bool> available() async => (await _offers()) != null;

  /// Play's offers for a product (see [StoreOffers.offers]).
  Future<Map<String, String>> offers(String productId) async {
    final o = await _offers();
    if (o == null || productId.isEmpty) return const {};
    try {
      return await o.offers(productId);
    } catch (_) {
      return const {};
    }
  }

  Future<CctvBuyStatus> buy(
      {required String productId,
      required String basePlanId,
      String offerId = '',
      required String accountId}) async {
    final o = await _offers();
    if (o == null) return CctvBuyStatus.unavailable;
    StoreBuyResult res;
    try {
      res = await o.buyOffer(
          productId: productId,
          basePlanId: basePlanId,
          offerId: offerId,
          accountId: accountId);
    } catch (_) {
      return CctvBuyStatus.failed;
    }
    switch (res.status) {
      case StoreBuyStatus.cancelled:
        return CctvBuyStatus.cancelled;
      case StoreBuyStatus.pending:
        return CctvBuyStatus.pending;
      case StoreBuyStatus.unavailable:
        return CctvBuyStatus.unavailable;
      case StoreBuyStatus.error:
        return CctvBuyStatus.failed;
      case StoreBuyStatus.purchased:
        break;
    }
    var v = await api.verify(productId, res.purchaseToken);
    for (var i = 0; i < 2 && !v.ok && v.reason == 'network'; i++) {
      await Future<void>.delayed(Duration(seconds: 2 * (i + 1)));
      v = await api.verify(productId, res.purchaseToken);
    }
    if (v.ok && v.data['entitled'] == true) {
      try {
        final b = await billing();
        await b?.finish(res.purchaseToken);
      } catch (_) {}
      return CctvBuyStatus.done;
    }
    // Google took the money: the server also learns it from RTDN / restore.
    return CctvBuyStatus.pending;
  }

  /// Re-send every CCTV purchase Play still holds for this Google account
  /// to OUR server (new phone, reinstall, a purchase that finished while the
  /// app was closed). Returns how many the server accepted.
  Future<int> restore(Set<String> productIds) async {
    StoreBilling? b;
    try {
      b = await billing();
    } catch (_) {}
    if (b == null) return 0;
    var n = 0;
    final seen = <String>{};
    for (final o in await b.owned()) {
      if (!productIds.contains(o.productId) || !seen.add(o.purchaseToken)) continue;
      final r = await api.verify(o.productId, o.purchaseToken);
      if (r.ok && r.data['entitled'] == true) n++;
    }
    return n;
  }
}
