import '../../api.dart';
import '../../payments/payments_api.dart';
import '../../payments/store_billing.dart';

/// probashi-plan (flag `probashi_plan`, default OFF): every server call the
/// Probashi screens make, behind ONE seam so widget tests inject a fake.
/// Shapes mirror backend/core/views_probashi.py + core/probashi_plan.py.
abstract class ProbashiSource {
  Future<Map<String, dynamic>> overview();
  Future<List<Map<String, dynamic>>> candidates();
  Future<Map<String, dynamic>> invite(int memberId);
  Future<Map<String, dynamic>> respond(int seatId, bool accept, Map<String, bool> consent);
  Future<Map<String, dynamic>> remove(int seatId);
  Future<Map<String, dynamic>> leave(int seatId);
  Future<Map<String, dynamic>> transfer(int seatId, int memberId);
  Future<Map<String, dynamic>> setCap(int seatId, int cap);
  Future<Map<String, dynamic>> setConsent(int seatId, Map<String, bool> consent);
  Future<Map<String, dynamic>> pool();
  Future<Map<String, dynamic>> family();
  Future<List<Map<String, dynamic>>> reports();
  Future<void> markRead(int reportId);
}

List<Map<String, dynamic>> _list(Object? v) =>
    [for (final x in (v as List? ?? const [])) (x as Map).cast<String, dynamic>()];

class ApiProbashiSource implements ProbashiSource {
  final ApiClient api;
  ApiProbashiSource(this.api);

  Future<Map<String, dynamic>> _act(int id, String action, [Map<String, dynamic> body = const {}]) =>
      api.postJson('/probashi/seats/$id/$action', body);

  @override
  Future<Map<String, dynamic>> overview() => api.getJson('/probashi');
  @override
  Future<List<Map<String, dynamic>>> candidates() async =>
      _list((await api.getJson('/probashi/candidates'))['candidates']);
  @override
  Future<Map<String, dynamic>> invite(int memberId) =>
      api.postJson('/probashi/seats', {'member_id': memberId});
  @override
  Future<Map<String, dynamic>> respond(int seatId, bool accept, Map<String, bool> consent) =>
      _act(seatId, 'respond', {'accept': accept, 'consent': consent});
  @override
  Future<Map<String, dynamic>> remove(int seatId) => _act(seatId, 'remove');
  @override
  Future<Map<String, dynamic>> leave(int seatId) => _act(seatId, 'leave');
  @override
  Future<Map<String, dynamic>> transfer(int seatId, int memberId) =>
      _act(seatId, 'transfer', {'member_id': memberId});
  @override
  Future<Map<String, dynamic>> setCap(int seatId, int cap) => _act(seatId, 'cap', {'cap': cap});
  @override
  Future<Map<String, dynamic>> setConsent(int seatId, Map<String, bool> consent) =>
      _act(seatId, 'consent', {'consent': consent});
  @override
  Future<Map<String, dynamic>> pool() => api.getJson('/probashi/pool');
  @override
  Future<Map<String, dynamic>> family() => api.getJson('/probashi/family');
  @override
  Future<List<Map<String, dynamic>>> reports() async =>
      _list((await api.getJson('/probashi/reports'))['reports']);
  @override
  Future<void> markRead(int reportId) async {
    await api.postJson('/probashi/reports/$reportId/read', const {});
  }
}

// ---------------------------------------------------------------- buying
const kProbashiProduct = 'assisto_probashi';
const kProbashiPlans = ['monthly', 'annual'];

enum ProbashiBuyStatus { done, pending, cancelled, unavailable, failed }

/// Buying `assisto_probashi` through the app's EXISTING Play path
/// (payments/store_billing.dart + /payments/play/precheck + verify). Prices
/// come ONLY from Google Play — never a number in the app.
abstract class ProbashiBuyer {
  /// basePlan ('monthly' | 'annual') -> Play's formatted price. Empty = the
  /// product is not on Google Play for this account / build.
  Future<Map<String, String>> prices();
  Future<ProbashiBuyStatus> buy(String basePlan);
}

class PlayProbashiBuyer implements ProbashiBuyer {
  final PaymentsBackend backend;
  final Future<StoreBilling?> Function() billing;
  PlayProbashiBuyer(ApiClient api, {PaymentsBackend? backend, Future<StoreBilling?> Function()? billing})
      : backend = backend ?? ApiPaymentsBackend(api),
        billing = billing ?? StoreBilling.forThisBuild;

  @override
  Future<Map<String, String>> prices() async {
    try {
      final b = await billing();
      if (b == null) return const {};
      final all = await b.prices({kProbashiProduct});
      return {
        for (final p in kProbashiPlans)
          if ((all['$kProbashiProduct/$p'] ?? '').isNotEmpty) p: all['$kProbashiProduct/$p']!,
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<ProbashiBuyStatus> buy(String basePlan) async {
    final sku = basePlan == 'annual' ? 'probashi_yearly' : 'probashi_monthly';
    final pre = await backend.playPrecheck(sku);
    if (!pre.ok) return pre.reason == 'network' ? ProbashiBuyStatus.failed : ProbashiBuyStatus.unavailable;
    final b = await billing();
    if (b == null) return ProbashiBuyStatus.unavailable;
    StoreBuyResult res;
    try {
      res = await b.buy(
          productId: kProbashiProduct,
          basePlanId: basePlan,
          isSubscription: true,
          accountId: '${pre.data['play_account_id'] ?? ''}');
    } catch (e) {
      return ProbashiBuyStatus.failed;
    }
    switch (res.status) {
      case StoreBuyStatus.cancelled:
        return ProbashiBuyStatus.cancelled;
      case StoreBuyStatus.pending:
        return ProbashiBuyStatus.pending;
      case StoreBuyStatus.unavailable:
        return ProbashiBuyStatus.unavailable;
      case StoreBuyStatus.error:
        return ProbashiBuyStatus.failed;
      case StoreBuyStatus.purchased:
        break;
    }
    var v = await backend.playVerify(kind: 'sub', productId: kProbashiProduct, purchaseToken: res.purchaseToken);
    for (var i = 0; i < 2 && !v.ok && v.reason == 'network'; i++) {
      await Future<void>.delayed(Duration(seconds: 2 * (i + 1)));
      v = await backend.playVerify(kind: 'sub', productId: kProbashiProduct, purchaseToken: res.purchaseToken);
    }
    if (v.ok && v.data['entitled'] == true) {
      try {
        await b.finish(res.purchaseToken);
      } catch (_) {}
      return ProbashiBuyStatus.done;
    }
    // Google took the money: the server also learns it from RTDN / restore.
    return ProbashiBuyStatus.pending;
  }
}
