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
