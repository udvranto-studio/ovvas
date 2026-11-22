import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:ovvas/data/ads/pro_manager.dart';

PricingPhaseWrapper _phase(int micros, String price) => PricingPhaseWrapper(
      billingCycleCount: 1,
      billingPeriod: 'P1Y',
      formattedPrice: price,
      priceAmountMicros: micros,
      priceCurrencyCode: 'USD',
      recurrenceMode: RecurrenceMode.infiniteRecurring,
    );

void main() {
  test('a subscription with a free-trial offer is offered once, at its base price', () {
    final yearly = GooglePlayProductDetails.fromProductDetails(ProductDetailsWrapper(
      description: '',
      name: 'Pro yearly',
      productId: 'ovvas_pro_yearly',
      productType: ProductType.subs,
      title: 'Pro yearly',
      subscriptionOfferDetails: [
        SubscriptionOfferDetailsWrapper(
          basePlanId: 'yearly',
          offerId: 'trial',
          offerTags: const [],
          offerIdToken: 't1',
          pricingPhases: [_phase(0, 'Free'), _phase(9990000, r'$9.99')],
        ),
        SubscriptionOfferDetailsWrapper(
          basePlanId: 'yearly',
          offerTags: const [],
          offerIdToken: 't2',
          pricingPhases: [_phase(9990000, r'$9.99')],
        ),
      ],
    ));
    final lifetime = GooglePlayProductDetails.fromProductDetails(const ProductDetailsWrapper(
      description: '',
      name: 'Pro lifetime',
      productId: 'ovvas_pro_lifetime',
      productType: ProductType.inapp,
      title: 'Pro lifetime',
      oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetailsWrapper(
        formattedPrice: r'$24.99',
        priceAmountMicros: 24990000,
        priceCurrencyCode: 'USD',
      ),
    ));
    expect(yearly, hasLength(2), reason: 'Play lists the trial offer separately');

    final shown = ProManager.onePerProduct([...lifetime, ...yearly]);
    expect(shown.map((p) => (p.id, p.price)), [('ovvas_pro_yearly', r'$9.99'), ('ovvas_pro_lifetime', r'$24.99')]);
  });
}
