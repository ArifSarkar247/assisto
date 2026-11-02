import '../config.dart';
import 'play_billing_impl.dart' deferred as play_impl;

/// pay1 — the Google Play Billing seam.
///
/// The real client (play_billing_impl.dart, package in_app_purchase) is a
/// DEFERRED import and is only ever loaded when [AppConfig.playStore] is
/// true AND the user taps "Google Play" in the checkout sheet. Nothing
/// touches Play Billing at app launch, and the direct website APK never
/// even attempts it ([StoreBilling.forThisBuild] returns null there).

enum StoreBuyStatus { purchased, pending, cancelled, unavailable, error }

class StoreBuyResult {
  final StoreBuyStatus status;
  final String purchaseToken;
  final String productId;
  final String error;
  const StoreBuyResult(this.status,
      {this.purchaseToken = '', this.productId = '', this.error = ''});
}

/// One purchase this Google account still owns on Play (an active
/// subscription, or a credit pack the server has not consumed yet).
class StoreOwned {
  final String productId;
  final String purchaseToken;
  const StoreOwned(this.productId, this.purchaseToken);
}

/// cctvprice — an OPTIONAL extra the real Play client also implements (test
/// fakes of [StoreBilling] need not): every offer of one subscription
/// product, so the CCTV plan screen can show Play's own price per camera
/// count and offer the 7-day free trial ONLY when Google says this Google
/// account is still eligible (Play lists only eligible offers).
abstract class StoreOffers {
  /// Key `basePlanId` = the base offer, `basePlanId#offerId` = an offer
  /// (e.g. the free trial). Value = Play's formatted RECURRING price (the
  /// last pricing phase). Never throws (empty = store unavailable).
  Future<Map<String, String>> offers(String productId);

  /// Buy one base plan (offerId empty) or one offer of it. A running
  /// subscription of the SAME product is replaced (WITH_TIME_PRORATION:
  /// immediate, unused time credited) — never one of another product.
  Future<StoreBuyResult> buyOffer({
    required String productId,
    required String basePlanId,
    String offerId = '',
    required String accountId,
  });
}

abstract class StoreBilling {
  /// Buy one product. `basePlanId` is set for subscriptions; `accountId` is
  /// the server's obfuscated account id (binds the purchase to this account).
  Future<StoreBuyResult> buy({
    required String productId,
    required String basePlanId,
    required bool isSubscription,
    required String accountId,
  });

  /// Tell the store we are done with a purchase the server verified.
  Future<void> finish(String purchaseToken);

  /// pay-e2e: every purchase Play still holds for this Google account
  /// (restore on a new phone / reinstall, a purchase that finished while the
  /// app was killed, a slow-card purchase that completed later). Each token
  /// goes to OUR server, which decides who owns it — never the device.
  Future<List<StoreOwned>> owned();

  /// credout: the store's own localized price (what the Play sheet will
  /// charge). Keys: `productId` for one-time packs, `productId/basePlanId`
  /// for a subscription base plan (its base offer's first pricing phase).
  /// Missing ids are left out; never throws (empty = store unavailable).
  Future<Map<String, String>> prices(Set<String> productIds);

  /// credout: consume a credit-pack purchase the SERVER already verified and
  /// granted, when the server could not consume it itself — so the same
  /// pack can be bought again. Never throws.
  Future<void> consume(String purchaseToken);

  /// Set by tests to inject a fake client on any flavour.
  static StoreBilling? debugOverride;

  /// The Play client for this build, or null on the direct APK. Loading is
  /// lazy and crash-guarded: a failure returns null (gateway still works).
  static Future<StoreBilling?> forThisBuild() async {
    if (debugOverride != null) return debugOverride;
    if (!AppConfig.playStore) return null;
    try {
      await play_impl.loadLibrary();
      return play_impl.createPlayBilling();
    } catch (_) {
      return null;
    }
  }
}
