import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'entitlement_service.dart';

/// AdMob integration for the free tier. Pro users never see ads.
///
/// NOTE: the IDs below are Google's official TEST ad units. Replace them with
/// your real AdMob unit IDs (and set the real app id in AndroidManifest.xml /
/// Info.plist) before publishing, or Google may suspend the account.
class AdsService {
  AdsService._();
  static final AdsService instance = AdsService._();

  bool _initialized = false;
  InterstitialAd? _interstitial;
  int _actionsSinceAd = 0;

  // --- TEST unit ids (replace for production) ---
  static String get bannerUnitId => Platform.isIOS
      ? 'ca-app-pub-3940256099942544/2934735716'
      : 'ca-app-pub-3940256099942544/6300978111';
  static String get interstitialUnitId => Platform.isIOS
      ? 'ca-app-pub-3940256099942544/4411468910'
      : 'ca-app-pub-3940256099942544/1033173712';

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await MobileAds.instance.initialize();
      _preloadInterstitial();
    } catch (_) {
      // Ads are non-critical; ignore init failures.
    }
  }

  void _preloadInterstitial() {
    if (!EntitlementService.instance.showAds) return;
    try {
      InterstitialAd.load(
        adUnitId: interstitialUnitId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) => _interstitial = ad,
          onAdFailedToLoad: (_) => _interstitial = null,
        ),
      );
    } catch (_) {/* ignore */}
  }

  /// Show an interstitial occasionally (every 3rd gated action) for free users.
  void maybeShowInterstitial() {
    if (!EntitlementService.instance.showAds) return;
    _actionsSinceAd++;
    if (_actionsSinceAd < 3 || _interstitial == null) return;
    _actionsSinceAd = 0;
    final ad = _interstitial!;
    _interstitial = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _preloadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        _preloadInterstitial();
      },
    );
    ad.show();
  }
}

/// A banner that renders only for free (ad-supported) users and collapses to
/// nothing for Pro. Listens to entitlement changes so it disappears instantly
/// when the user upgrades.
class ConFriKaAdBanner extends StatefulWidget {
  const ConFriKaAdBanner({super.key});

  @override
  State<ConFriKaAdBanner> createState() => _ConFriKaAdBannerState();
}

class _ConFriKaAdBannerState extends State<ConFriKaAdBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    EntitlementService.instance.notifier.addListener(_onEntitlements);
    _maybeLoad();
  }

  void _onEntitlements() {
    if (!EntitlementService.instance.showAds) {
      _dispose();
      if (mounted) setState(() {});
    } else {
      _maybeLoad();
    }
  }

  void _maybeLoad() {
    if (_ad != null || !EntitlementService.instance.showAds) return;
    try {
      _ad = BannerAd(
        adUnitId: AdsService.bannerUnitId,
        size: AdSize.banner,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (_) {
            if (mounted) setState(() => _loaded = true);
          },
          onAdFailedToLoad: (ad, _) {
            ad.dispose();
            _ad = null;
          },
        ),
      )..load();
    } catch (_) {
      _ad = null;
    }
  }

  void _dispose() {
    _ad?.dispose();
    _ad = null;
    _loaded = false;
  }

  @override
  void dispose() {
    EntitlementService.instance.notifier.removeListener(_onEntitlements);
    _dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!EntitlementService.instance.showAds || !_loaded || _ad == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: _ad!.size.width.toDouble(),
      height: _ad!.size.height.toDouble(),
      child: AdWidget(ad: _ad!),
    );
  }
}
