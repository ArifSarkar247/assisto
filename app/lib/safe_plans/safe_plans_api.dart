import '../api.dart';
import '../payments/payments_api.dart';
import '../payments/store_billing.dart';

/// safeplans — Safety plans (owner order 3 Nov 18:40): Child Plan, Safe
/// Family, School Safe code, monthly credits (no rollover), prepaid request
/// packs, guardian-only rewarded unlocks.
///
/// The SERVER is the source of every number (GET /safe-plans). Google Play's
/// own price string is shown on the buy buttons when Play answers; no Play
/// price -> no buy button (never a wrong price). Purchases use the EXISTING
/// Play path: buy -> POST /payments/play/verify -> finish.
abstract class SafePlansApi {
  Future<Map<String, dynamic>> load();
  Future<Map<String, dynamic>> redeemSchool(String code, int childId);
  Future<Map<String, dynamic>> adTicket(String goal);
  Future<Map<String, dynamic>> adTicketState(String nonce);
  Future<PayResult> verify(String kind, String productId, String purchaseToken);
}

class ApiSafePlansApi implements SafePlansApi {
  final ApiClient api;
  ApiSafePlansApi(this.api);

  @override
  Future<Map<String, dynamic>> load() => api.getJson('/safe-plans');

  @override
  Future<Map<String, dynamic>> redeemSchool(String code, int childId) async {
    try {
      return await api.postJson('/safe-plans/school/redeem', {'code': code, 'child_id': childId});
    } on ApiException catch (e) {
      return e.body ?? {'ok': false, 'reason': 'error'};
    }
  }

  @override
  Future<Map<String, dynamic>> adTicket(String goal) =>
      api.postJson('/safe-plans/ad/ticket', {'goal': goal});

  @override
  Future<Map<String, dynamic>> adTicketState(String nonce) =>
      api.getJson('/safe-plans/ad/ticket/$nonce');

  @override
  Future<PayResult> verify(String kind, String productId, String purchaseToken) =>
      ApiPaymentsBackend(api).playVerify(kind: kind, productId: productId, purchaseToken: purchaseToken);
}

/// Test seam: inject a fake API.
class SafePlansDeps {
  static SafePlansApi? debugApi;
  static Future<StoreBilling?> Function()? debugBilling;
}

enum SafeBuyStatus { done, pending, cancelled, unavailable, failed }

int spInt(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

Map<String, dynamic> spMap(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

/// Buys one subscription (base plan) or one prepaid pack through Play.
class SafePlansBuyer {
  final SafePlansApi api;
  final Future<StoreBilling?> Function() billing;
  SafePlansBuyer(this.api, {Future<StoreBilling?> Function()? billing})
      : billing = billing ?? SafePlansDeps.debugBilling ?? StoreBilling.forThisBuild;

  Future<Map<String, String>> prices(Set<String> ids) async {
    try {
      final b = await billing();
      if (b == null) return const {};
      return await b.prices(ids);
    } catch (_) {
      return const {};
    }
  }

  Future<SafeBuyStatus> buy(
      {required String productId,
      String basePlanId = '',
      required bool subscription,
      required String accountId}) async {
    StoreBilling? b;
    try {
      b = await billing();
    } catch (_) {}
    if (b == null) return SafeBuyStatus.unavailable;
    StoreBuyResult res;
    try {
      res = await b.buy(
          productId: productId,
          basePlanId: basePlanId,
          isSubscription: subscription,
          accountId: accountId);
    } catch (_) {
      return SafeBuyStatus.failed;
    }
    switch (res.status) {
      case StoreBuyStatus.cancelled:
        return SafeBuyStatus.cancelled;
      case StoreBuyStatus.pending:
        return SafeBuyStatus.pending;
      case StoreBuyStatus.unavailable:
        return SafeBuyStatus.unavailable;
      case StoreBuyStatus.error:
        return SafeBuyStatus.failed;
      case StoreBuyStatus.purchased:
        break;
    }
    final v = await api.verify(subscription ? 'sub' : 'pack', productId, res.purchaseToken);
    if (v.ok) {
      try {
        await b.finish(res.purchaseToken);
        if (!subscription && v.data['consumed'] != true) await b.consume(res.purchaseToken);
      } catch (_) {}
      return SafeBuyStatus.done;
    }
    return SafeBuyStatus.pending;
  }
}
