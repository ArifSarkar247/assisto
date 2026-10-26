import 'package:flutter/widgets.dart';

import 'payments_api.dart';
import 'store_billing.dart';

/// credout — Google Play's OWN prices for the Play build.
///
/// In the Play flavour every price the user sees (plans, checkout, credit
/// packs) is the store's formatted price — never a server taka number:
///  * packs (credits_p20/p50/p100/p200): ProductDetails.price
///  * subscriptions (assisto_premium / assisto_business): the base plan the
///    server names (`play_base_plan`: monthly | annual) — its base offer's
///    first pricing phase `formattedPrice`.
/// One query per app run (cached), lazy (the Play client is a deferred
/// import), crash-guarded. A failed query is retried on the next [ensure].
/// The website APK never calls this (server prices + EPS there).
class PlayPrices {
  PlayPrices._();

  static final Map<String, String> _cache = {};
  static Future<void>? _inflight;
  static Future<StoreBilling?> Function() billing = StoreBilling.forThisBuild;

  /// The cache key of a product: `productId` (pack) or `productId/basePlan`.
  static String keyFor(PayProduct p) =>
      p.isSub ? '${p.playProductId}/${p.playBasePlan}' : p.playProductId;

  /// The store price of [p] if it is known.
  static String? of(PayProduct p) =>
      p.playProductId.isEmpty ? null : _cache[keyFor(p)];

  /// Make sure the prices of [products] were asked from the store once.
  static Future<void> ensure(Iterable<PayProduct> products) async {
    final missing = <String>{
      for (final p in products)
        if (p.playProductId.isNotEmpty && !_cache.containsKey(keyFor(p)))
          p.playProductId,
    };
    if (missing.isEmpty) return;
    final running = _inflight;
    if (running != null) {
      await running;
      return;
    }
    final f = _query(missing);
    _inflight = f;
    try {
      await f;
    } finally {
      _inflight = null;
    }
  }

  static Future<void> _query(Set<String> ids) async {
    try {
      final b = await billing();
      if (b == null) return;
      _cache.addAll(await b.prices(ids));
    } catch (_) {
      // store unavailable: callers show "price unavailable — try again"
    }
  }

  @visibleForTesting
  static void debugReset() {
    _cache.clear();
    _inflight = null;
    billing = StoreBilling.forThisBuild;
  }
}

/// ASCII digits -> Bangla digits in the Bangla UI (by code point).
String localizeStoreDigits(BuildContext context, String s) {
  if (Localizations.localeOf(context).languageCode != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? 0x09E6 + (c - 0x30) : c);
  }
  return b.toString();
}
