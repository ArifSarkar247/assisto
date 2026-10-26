// credout: pure Play Billing logic (no device): which offer is bought (base
// plans monthly | annual, never the inactive "yearly"), Play's formatted
// prices per product / base plan, and a monthly -> annual change REPLACES the
// running subscription with WITH_TIME_PRORATION.
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'package:assisto/payments/play_billing_impl.dart';

PricingPhaseWrapper _phase(String f) => PricingPhaseWrapper(
    billingCycleCount: 0,
    billingPeriod: 'P1M',
    formattedPrice: f,
    priceAmountMicros: 1,
    priceCurrencyCode: 'BDT',
    recurrenceMode: RecurrenceMode.infiniteRecurring);

SubscriptionOfferDetailsWrapper _offer(String base, String price, {String? offerId}) =>
    SubscriptionOfferDetailsWrapper(
        basePlanId: base,
        offerId: offerId,
        offerTags: const [],
        offerIdToken: '$base-$offerId',
        pricingPhases: [_phase(price)]);

List<GooglePlayProductDetails> _premium() =>
    GooglePlayProductDetails.fromProductDetails(ProductDetailsWrapper(
      description: '',
      name: 'Premium',
      productId: 'assisto_premium',
      productType: ProductType.subs,
      title: 'Premium',
      subscriptionOfferDetails: [
        _offer('monthly', 'BDT 199.00'),
        _offer('annual', 'BDT 1,990.00'),
        _offer('annual', 'BDT 990.00', offerId: 'intro'), // a promo, not base
        _offer('yearly', 'BDT 9.00'), // legacy, inactive in Play Console
      ],
    ));

List<GooglePlayProductDetails> _pack(String id, String price) =>
    GooglePlayProductDetails.fromProductDetails(ProductDetailsWrapper(
      description: '',
      name: id,
      productId: id,
      productType: ProductType.inapp,
      title: id,
      oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetailsWrapper(
          formattedPrice: price, priceAmountMicros: 1, priceCurrencyCode: 'BDT'),
    ));

void main() {
  test('prices: packs by product id, plans by product/base plan (base offer only)',
      () {
    final m = playPriceMap([
      ..._premium(),
      for (final p in ['credits_p20', 'credits_p50', 'credits_p100', 'credits_p200'])
        ..._pack(p, 'BDT ${p.substring(9)}.00'),
    ]);
    expect(m['assisto_premium/monthly'], 'BDT 199.00');
    expect(m['assisto_premium/annual'], 'BDT 1,990.00'); // never the promo
    expect(m['credits_p20'], 'BDT 20.00');
    expect(m['credits_p200'], 'BDT 200.00');
    expect(m.keys.where((k) => k.startsWith('assisto_premium/')).toSet(),
        {'assisto_premium/monthly', 'assisto_premium/annual', 'assisto_premium/yearly'});
  });

  test('buy: the server-named base plan only, never a fallback', () {
    final l = _premium();
    final annual = pickPlayProduct(l, isSubscription: true, basePlanId: 'annual')
        as GooglePlayProductDetails;
    final o = annual.productDetails.subscriptionOfferDetails![annual.subscriptionIndex!];
    expect((o.basePlanId, o.offerId), ('annual', null));
    final monthly = pickPlayProduct(l, isSubscription: true, basePlanId: 'monthly')
        as GooglePlayProductDetails;
    expect(
        monthly.productDetails.subscriptionOfferDetails![monthly.subscriptionIndex!]
            .basePlanId,
        'monthly');
    expect(pickPlayProduct(l, isSubscription: true, basePlanId: 'weekly'), isNull);
    final pack = pickPlayProduct(_pack('credits_p50', 'BDT 50.00'),
        isSubscription: false, basePlanId: '');
    expect(pack?.id, 'credits_p50');
  });

  test('monthly -> annual on the same product replaces with time proration', () {
    final old = GooglePlayPurchaseDetails.fromPurchase(const PurchaseWrapper(
      orderId: 'GPA.1',
      packageName: 'com.assisto.assisto',
      purchaseTime: 0,
      purchaseToken: 'old-monthly-token',
      signature: '',
      products: ['assisto_premium'],
      isAutoRenewing: true,
      originalJson: '{}',
      isAcknowledged: true,
      purchaseState: PurchaseStateWrapper.purchased,
    )).first;
    final p = playChangeParam(old)!;
    expect(p.replacementMode, ReplacementMode.withTimeProration);
    expect(p.oldPurchaseDetails.verificationData.serverVerificationData,
        'old-monthly-token');
    expect(playChangeParam(null), isNull); // first purchase: no replacement
  });
}
