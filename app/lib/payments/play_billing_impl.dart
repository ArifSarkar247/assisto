// pay1 — the REAL Google Play Billing client (package in_app_purchase).
//
// Only ever reached through `store_billing.dart`'s DEFERRED import, and only
// when AppConfig.playStore is true and the user tapped "Google Play". Every
// call is crash-guarded; a failure returns an honest StoreBuyResult and the
// gateway option still works.
//
// The device grants NOTHING: the purchase token goes to our server, which
// verifies it with the Play Developer API, acknowledges subscriptions and
// consumes packs. finish() only tells Play the app has handled the purchase.
import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'store_billing.dart';

// pay-e2e: ONE client per app run — a new instance per tap used to add
// another purchaseStream listener every time.
_PlayBilling? _instance;
StoreBilling createPlayBilling() => _instance ??= _PlayBilling();

class _PlayBilling implements StoreBilling {
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final Map<String, PurchaseDetails> _toFinish = {};
  Completer<StoreBuyResult>? _waiting;
  String _waitingFor = '';

  void _listen() {
    _sub ??= _iap.purchaseStream.listen(_onUpdates, onError: (Object e) {
      _complete(StoreBuyResult(StoreBuyStatus.error, error: '$e'));
    });
  }

  void _complete(StoreBuyResult r) {
    final w = _waiting;
    if (w != null && !w.isCompleted) w.complete(r);
  }

  void _onUpdates(List<PurchaseDetails> list) {
    for (final p in list) {
      final token = p.verificationData.serverVerificationData;
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        _toFinish[token] = p;
      }
      if (p.productID != _waitingFor) continue;
      switch (p.status) {
        case PurchaseStatus.pending:
          _complete(StoreBuyResult(StoreBuyStatus.pending, productId: p.productID));
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _complete(StoreBuyResult(StoreBuyStatus.purchased,
              purchaseToken: token, productId: p.productID));
          break;
        case PurchaseStatus.canceled:
          _complete(const StoreBuyResult(StoreBuyStatus.cancelled));
          break;
        case PurchaseStatus.error:
          _complete(StoreBuyResult(StoreBuyStatus.error,
              error: p.error?.message ?? 'error'));
          break;
      }
    }
  }

  /// The running Assisto subscription on this Play account, if any — a
  /// plan change must REPLACE it (never a second parallel subscription).
  Future<GooglePlayPurchaseDetails?> _activeSubscription(String productId) async {
    try {
      final add =
          _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      // ignore: deprecated_member_use
      final r = await add.queryPastPurchases();
      for (final p in r.pastPurchases) {
        final id = p.productID;
        if (id.startsWith('assisto_') &&
            p.billingClientPurchase.purchaseState ==
                PurchaseStateWrapper.purchased) {
          return p;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<StoreBuyResult> buy({
    required String productId,
    required String basePlanId,
    required bool isSubscription,
    required String accountId,
  }) async {
    try {
      if (!await _iap.isAvailable()) {
        return const StoreBuyResult(StoreBuyStatus.unavailable);
      }
      _listen();
      final resp = await _iap.queryProductDetails({productId});
      if (resp.productDetails.isEmpty) {
        return const StoreBuyResult(StoreBuyStatus.unavailable,
            error: 'product not found in Play Console');
      }
      ProductDetails? pick = isSubscription ? null : resp.productDetails.first;
      if (isSubscription) {
        for (final d in resp.productDetails) {
          if (d is GooglePlayProductDetails) {
            final i = d.subscriptionIndex;
            final offers = d.productDetails.subscriptionOfferDetails;
            if (i != null &&
                offers != null &&
                i < offers.length &&
                offers[i].basePlanId == basePlanId &&
                offers[i].offerId == null) {
              pick = d;
              break;
            }
          }
        }
      }
      // pay-e2e: never fall back to another base plan (a "yearly" tap must
      // never charge "monthly" when the yearly base plan is missing/inactive).
      if (pick == null) {
        return const StoreBuyResult(StoreBuyStatus.unavailable,
            error: 'base plan not active in Play Console');
      }
      ChangeSubscriptionParam? change;
      if (isSubscription) {
        final old = await _activeSubscription(productId);
        if (old != null) {
          change = ChangeSubscriptionParam(
              oldPurchaseDetails: old,
              // pay-e2e: CHARGE_PRORATED_PRICE is valid for upgrades only
              // (Play refuses it for a downgrade or a monthly<->yearly
              // change). WITH_TIME_PRORATION works for every change: the
              // switch is immediate and unused time is credited.
              replacementMode: ReplacementMode.withTimeProration);
        }
      }
      final param = GooglePlayPurchaseParam(
          productDetails: pick,
          applicationUserName: accountId,
          changeSubscriptionParam: change);
      _waiting = Completer<StoreBuyResult>();
      _waitingFor = productId;
      final started = isSubscription
          ? await _iap.buyNonConsumable(purchaseParam: param)
          : await _iap.buyConsumable(purchaseParam: param, autoConsume: false);
      if (!started) return const StoreBuyResult(StoreBuyStatus.error);
      return await _waiting!.future.timeout(const Duration(minutes: 15),
          onTimeout: () => const StoreBuyResult(StoreBuyStatus.pending));
    } catch (e) {
      return StoreBuyResult(StoreBuyStatus.error, error: '$e');
    }
  }

  @override
  Future<List<StoreOwned>> owned() async {
    try {
      if (!await _iap.isAvailable()) return const [];
      final add =
          _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      // ignore: deprecated_member_use
      final r = await add.queryPastPurchases();
      final out = <StoreOwned>[];
      for (final p in r.pastPurchases) {
        if (p.billingClientPurchase.purchaseState !=
            PurchaseStateWrapper.purchased) {
          continue; // pending (slow card): the server/RTDN grants it later
        }
        final token = p.verificationData.serverVerificationData;
        if (token.isEmpty) continue;
        out.add(StoreOwned(p.productID, token));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> finish(String purchaseToken) async {
    final p = _toFinish.remove(purchaseToken);
    if (p == null || !p.pendingCompletePurchase) return;
    try {
      await _iap.completePurchase(p);
    } catch (_) {}
  }
}
