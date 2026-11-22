import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import '../local/database.dart';

/// Ovvas Pro, sold through Google Play Billing (FR-ADS-08).
///
/// The status is saved on the phone, so it stays valid offline and after a
/// restart (FR-ADS-05.1). It only changes when Google Play answers.
// shortcut: purchases are trusted as Google Play reports them on the phone,
// with no server-side receipt check. Upgrade with a Play Developer API check
// in a Supabase function if refunds abuse shows up.
class ProManager extends ChangeNotifier {
  ProManager(this._db);

  final AppDatabase? _db;

  /// Product IDs to create in the Play Console: a yearly subscription and a
  /// one-time purchase. Whichever exist are offered.
  static const productIds = {'ovvas_pro_yearly', 'ovvas_pro_lifetime'};
  static const _key = 'pro.active';

  // shortcut: Android only, the platform the SRS covers. Add StoreKit for iOS.
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool _active = false;
  bool get active => _active;

  /// What the store sells, cheapest first. Empty until loaded.
  List<ProductDetails> products = const [];

  /// True while a purchase is in progress.
  bool buying = false;

  /// Set when the last purchase failed, until [takePurchaseFailed] reads it.
  bool purchaseFailed = false;

  /// Whether a purchase failed since the last call, so the UI says it once.
  bool takePurchaseFailed() {
    final failed = purchaseFailed;
    purchaseFailed = false;
    return failed;
  }

  StreamSubscription<List<PurchaseDetails>>? _sub;

  Future<void> start() async {
    _active = await _db?.readValue(_key) == 'true';
    notifyListeners();
    if (!supported) return;
    try {
      final iap = InAppPurchase.instance;
      _sub = iap.purchaseStream.listen(_onPurchases, onError: (Object e) => debugPrint('Purchase stream: $e'));
      if (!await iap.isAvailable()) return;
      await refresh();
      final r = await iap.queryProductDetails(productIds);
      products = [...r.productDetails]..sort((a, b) => a.rawPrice.compareTo(b.rawPrice));
      notifyListeners();
    } catch (e, s) {
      debugPrint('Billing unavailable: $e\n$s');
    }
  }

  /// Asks Google Play what this account owns. Returns false, keeping the
  /// saved status, when Play can't be reached. Also used to restore
  /// purchases on a new phone.
  Future<bool> refresh() async {
    if (!supported) return false;
    try {
      final r = await InAppPurchase.instance
          .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>()
          .queryPastPurchases();
      if (r.error != null) return false;
      final owned = r.pastPurchases
          .where((p) => productIds.contains(p.productID) && p.status == PurchaseStatus.purchased)
          .toList();
      for (final p in owned) {
        if (p.pendingCompletePurchase) await InAppPurchase.instance.completePurchase(p);
      }
      await _setActive(owned.isNotEmpty);
      return true;
    } catch (e) {
      debugPrint('Checking purchases failed: $e');
      return false;
    }
  }

  /// Opens Google Play's purchase sheet. The result arrives on the purchase stream.
  Future<void> buy(ProductDetails product) async {
    buying = true;
    purchaseFailed = false;
    notifyListeners();
    try {
      await InAppPurchase.instance.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
    } catch (e) {
      debugPrint('Purchase failed to start: $e');
      buying = false;
      purchaseFailed = true;
      notifyListeners();
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (!productIds.contains(p.productID)) continue;
      switch (p.status) {
        case PurchaseStatus.purchased || PurchaseStatus.restored:
          await _setActive(true);
          buying = false;
        case PurchaseStatus.error:
          buying = false;
          purchaseFailed = true;
        case PurchaseStatus.canceled:
          buying = false;
        case PurchaseStatus.pending:
          break;
      }
      // Unacknowledged Play purchases are refunded after 3 days.
      if (p.pendingCompletePurchase) await InAppPurchase.instance.completePurchase(p);
    }
    notifyListeners();
  }

  Future<void> _setActive(bool value) async {
    if (value == _active) return;
    _active = value;
    await _db?.writeValue(_key, value ? 'true' : null);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
