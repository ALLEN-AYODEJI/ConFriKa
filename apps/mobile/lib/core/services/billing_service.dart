import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../network/api_client.dart';
import 'entitlement_service.dart';

/// Wraps store billing (Google Play / App Store) for ConFriKa Pro.
///
/// Flow: the store completes a purchase, we hand its verification token to the
/// backend ([ConFriKaApiClient.verifyPurchase]) which verifies it with the
/// store and grants Pro, then we refresh entitlements and complete the purchase.
class BillingService {
  BillingService._();
  static final BillingService instance = BillingService._();

  static const String monthlyId = 'confrika_pro_monthly';
  static const String yearlyId = 'confrika_pro_yearly';
  static const Set<String> _ids = {monthlyId, yearlyId};

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// Last status surfaced to the paywall UI (null while idle).
  final ValueNotifier<String?> status = ValueNotifier<String?>(null);
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  bool _started = false;

  Future<void> init() async {
    if (_started) return;
    _started = true;
    _sub = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (e) => status.value = 'The store is unavailable right now.',
    );
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _started = false;
  }

  Future<bool> available() async {
    try {
      return await _iap.isAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Fetch the purchasable Pro products (empty list if the store is offline or
  /// the products are not yet configured in the console).
  Future<List<ProductDetails>> loadProducts() async {
    try {
      if (!await available()) return const [];
      final resp = await _iap.queryProductDetails(_ids);
      final list = resp.productDetails.toList()
        ..sort((a, b) => a.rawPrice.compareTo(b.rawPrice));
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> buy(ProductDetails product) async {
    busy.value = true;
    status.value = null;
    try {
      final param = PurchaseParam(productDetails: product);
      // Subscriptions are non-consumable.
      await _iap.buyNonConsumable(purchaseParam: param);
    } catch (e) {
      status.value = 'Couldn\'t start the purchase. Please try again.';
      busy.value = false;
    }
  }

  Future<void> restore() async {
    busy.value = true;
    status.value = 'Restoring purchases…';
    try {
      await _iap.restorePurchases();
    } catch (e) {
      status.value = 'Couldn\'t restore purchases. Please try again.';
    } finally {
      busy.value = false;
    }
  }

  String get _platform => Platform.isIOS ? 'app_store' : 'google_play';

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          status.value = 'Purchase pending…';
          break;
        case PurchaseStatus.canceled:
          status.value = 'Purchase canceled.';
          busy.value = false;
          break;
        case PurchaseStatus.error:
          status.value = p.error?.message ?? 'Purchase failed.';
          busy.value = false;
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verify(p);
          break;
      }
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (_) {/* best effort */}
      }
    }
  }

  Future<void> _verify(PurchaseDetails p) async {
    status.value = 'Verifying purchase…';
    try {
      final token = p.verificationData.serverVerificationData;
      await ConFriKaApiClient.instance.verifyPurchase(
        platform: _platform,
        productId: p.productID,
        token: token,
      );
      await EntitlementService.instance.refresh();
      status.value = EntitlementService.instance.isPro
          ? 'You are now on ConFriKa Pro 🎉'
          : 'Purchase received; activation pending.';
    } on ApiException catch (e) {
      status.value = 'Verification failed: ${e.message}';
    } catch (e) {
      status.value = 'Couldn\'t verify the purchase. Please try again.';
    } finally {
      busy.value = false;
    }
  }
}
