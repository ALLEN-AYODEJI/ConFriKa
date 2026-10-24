import 'package:flutter/foundation.dart';

import '../network/api_client.dart';

/// A snapshot of the signed-in user's plan, limits and today's usage.
class Entitlements {
  final String tier; // 'free' | 'pro'
  final bool isPro;
  final bool showAds;
  final DateTime? expiresAt;
  final int dailyTranslations; // -1 = unlimited
  final int dailyCallSeconds; // -1 = unlimited
  final int maxCommunities; // -1 = unlimited
  final bool canCreateCommunities;
  final bool voiceClone;
  final int translationsToday;
  final int callSecondsToday;
  final int communitiesJoined;

  const Entitlements({
    required this.tier,
    required this.isPro,
    required this.showAds,
    required this.expiresAt,
    required this.dailyTranslations,
    required this.dailyCallSeconds,
    required this.maxCommunities,
    required this.canCreateCommunities,
    required this.voiceClone,
    required this.translationsToday,
    required this.callSecondsToday,
    required this.communitiesJoined,
  });

  /// Safe default before the first fetch: free tier with ads.
  static const Entitlements free = Entitlements(
    tier: 'free',
    isPro: false,
    showAds: true,
    expiresAt: null,
    dailyTranslations: 30,
    dailyCallSeconds: 900,
    maxCommunities: 2,
    canCreateCommunities: false,
    voiceClone: false,
    translationsToday: 0,
    callSecondsToday: 0,
    communitiesJoined: 0,
  );

  factory Entitlements.fromJson(Map<String, dynamic> j) {
    final limits = (j['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    final usage = (j['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
    int asInt(dynamic v, int fallback) =>
        v is int ? v : (v is num ? v.toInt() : fallback);
    return Entitlements(
      tier: (j['tier'] ?? 'free').toString(),
      isPro: j['is_pro'] == true,
      showAds: j['show_ads'] == true,
      expiresAt: j['subscription_expires_at'] != null
          ? DateTime.tryParse(j['subscription_expires_at'].toString())
          : null,
      dailyTranslations: asInt(limits['daily_translations'], 30),
      dailyCallSeconds: asInt(limits['daily_call_seconds'], 900),
      maxCommunities: asInt(limits['max_communities'], 2),
      canCreateCommunities: limits['can_create_communities'] == true,
      voiceClone: limits['voice_clone'] == true,
      translationsToday: asInt(usage['translations_today'], 0),
      callSecondsToday: asInt(usage['call_seconds_today'], 0),
      communitiesJoined: asInt(usage['communities_joined'], 0),
    );
  }

  int get translationsRemaining =>
      dailyTranslations < 0 ? -1 : (dailyTranslations - translationsToday).clamp(0, dailyTranslations);
}

/// App-wide entitlement state. Widgets listen to [notifier] to react to plan
/// changes (e.g. hide ads and unlock features the moment Pro is granted).
class EntitlementService {
  EntitlementService._();
  static final EntitlementService instance = EntitlementService._();

  final ValueNotifier<Entitlements> notifier =
      ValueNotifier<Entitlements>(Entitlements.free);

  Entitlements get current => notifier.value;
  bool get isPro => current.isPro;
  bool get showAds => current.showAds;

  /// Fetch the latest entitlements from the backend. Never throws; keeps the
  /// last known snapshot on failure so the UI stays stable offline.
  Future<void> refresh() async {
    try {
      final data = await ConFriKaApiClient.instance.entitlements();
      notifier.value = Entitlements.fromJson(data);
    } catch (_) {
      // keep last known value
    }
  }

  /// Reset to the default free snapshot (e.g. on sign-out).
  void reset() => notifier.value = Entitlements.free;
}
