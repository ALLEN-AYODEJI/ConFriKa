import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/crypto/e2ee_service.dart';
import '../../core/network/api_client.dart';
import '../../core/services/ads_service.dart';
import '../../core/services/billing_service.dart';
import '../../core/services/entitlement_service.dart';
import '../../core/services/push_messaging_service.dart';
import '../../core/session.dart';
import '../../core/widgets/confrika_brand_widgets.dart';
import '../billing/pro_paywall_screen.dart';
import '../connect/active_call_screen.dart';
import '../connect/connect_call_screen.dart';
import '../home/home_screen.dart';
import '../learn/learn_and_tone_coach_screen.dart';
import '../messages/direct_messages_screen.dart';
import '../profile/profile_and_trust_screen.dart';
import '../sign/sign_mode_screen.dart';
import '../spaces/communities_screen.dart';
import '../translate/translate_screen.dart';

/// Quick "reading language" options for the top-bar selector.
/// [key, menu label, short code shown in the compact chip].
const List<List<String>> _kReadingLanguages = [
  ['English', '🎧 English', 'EN'],
  ['Français', '🎧 Français', 'FR'],
  ['Português', '🎧 Português', 'PT'],
  ['Arabic', '🎧 العربية', 'AR'],
  ['Swahili', '🎧 🇰🇪 Swahili', 'SW'],
  ['Yorùbá', '🎧 🇳🇬 Yorùbá', 'YO'],
  ['Igbo', '🎧 🇳🇬 Igbo', 'IG'],
  ['Hausa', '🎧 🇳🇬 Hausa', 'HA'],
  ['Zulu', '🎧 🇿🇦 isiZulu', 'ZU'],
  ['Amharic', '🎧 🇪🇹 Amharic', 'AM'],
];

class ConFriKaShell extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleThemeMode;

  const ConFriKaShell({
    super.key,
    required this.isDarkMode,
    required this.onToggleThemeMode,
  });

  @override
  State<ConFriKaShell> createState() => _ConFriKaShellState();
}

class _ConFriKaShellState extends State<ConFriKaShell> {
  final _api = ConFriKaApiClient.instance;

  int _currentIndex = 0;

  // Live connection / presence (polled from /health — real values).
  bool _connected = false;
  int? _onlineCount;
  Timer? _healthTimer;

  @override
  void initState() {
    super.initState();
    ConFriKaSession.instance.addListener(_onSessionChanged);
    _pollHealth();
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pollHealth());
    _bootstrapEncryptionKey();
    _bootstrapPush();
    // Load the user's plan (free/Pro) so ads + feature gates reflect reality.
    EntitlementService.instance.refresh();
    BillingService.instance.init();
    _api.recordAppOpen(); // reach metric (best-effort)
  }

  /// Register this device for push notifications and route incoming-call pushes
  /// straight into the full-screen call UI.
  Future<void> _bootstrapPush() async {
    PushMessagingService.instance.onIncomingCall = (from, name) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ActiveCallScreen(
          calleeUsername: from,
          displayName: name,
          incoming: true,
        ),
      ));
    };
    await PushMessagingService.instance.init();
  }

  /// Generate (once) and publish this device's E2E public key so other users
  /// can encrypt direct messages to us. Fails silently — DMs fall back to
  /// plaintext when a key isn't available.
  Future<void> _bootstrapEncryptionKey() async {
    try {
      final pub = await E2eeService.instance.ensureKeyPair();
      await _api.uploadPublicKey(pub);
    } catch (_) {}
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    ConFriKaSession.instance.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pollHealth() async {
    // Heartbeat so other users see us as online (drives their caller status:
    // "Ringing" when we're reachable, "Calling" when we're not). Best-effort.
    _api.presencePing().catchError((_) {});
    try {
      final h = await _api.health();
      if (!mounted) return;
      setState(() {
        _connected = true;
        _onlineCount = (h['online_users'] as num?)?.toInt();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _connected = false);
    }
  }

  void _startCall(String username) {
    final handle = username.startsWith('@') ? username : '@$username';
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ActiveCallScreen(calleeUsername: handle),
    ));
  }

  /// Opens the Sign Mode accessibility screen (split-screen signer for
  /// Deaf / non-speaking users).
  void _openSignMode() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SignModeScreen(),
    ));
  }

  void _openDirectMessage(Map<String, dynamic> contact) {
    setState(() {
      _currentIndex = 1; // Switches to the private Chats (Direct Messages) tab
    });
  }

  /// Opens the Communities hub (joinable public spaces), kept cleanly distinct
  /// from the private Chats list.
  void _openGlobalSpaces() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommunitiesScreen(onStartCall: _startCall),
    ));
  }

  /// The reading-language entry currently selected, resolved from the stored
  /// session preference. Always returns an entry present in [_kReadingLanguages].
  List<String> _currentReading() {
    final pref = ConFriKaSession.instance.preferredLanguage.toLowerCase();
    for (final entry in _kReadingLanguages) {
      final key = entry[0].toLowerCase();
      if (pref == key || pref.contains(key) || key.contains(pref.split(' ').first)) {
        return entry;
      }
    }
    return _kReadingLanguages.first;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;

    final screens = [
      HomeScreen(
        onOpenGlobalSpaces: _openGlobalSpaces,
        onOpenToneCoach: () => setState(() => _currentIndex = 3),
        onOpenTranslate: () => setState(() => _currentIndex = 4),
        onOpenSignMode: _openSignMode,
        onStartCall: _startCall,
        onOpenDirectMessage: _openDirectMessage,
      ),
      DirectMessagesScreen(
        onStartCall: _startCall,
        onOpenGlobalSpaces: _openGlobalSpaces,
      ),
      const ConnectCallScreen(),
      const LearnAndToneCoachScreen(),
      const TranslateScreen(),
      const ProfileAndTrustScreen(),
    ];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
        title: Row(
          children: [
            // Brand — takes the remaining space so the wordmark is never
            // squeezed on small screens; the trailing controls keep their size.
            const Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConFriKaAppLogo(size: 30),
                  SizedBox(width: 6),
                  Flexible(child: ConFriKaWordmark(fontSize: 17)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _proButton(),
            _themeToggle(isDark),
            const SizedBox(width: 8),
            _languageChip(isDark),
            const SizedBox(width: 8),
            _connectionDot(isDark),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: screens[_currentIndex]),
            const ConFriKaAdBanner(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.phone_in_talk_outlined),
            selectedIcon: Icon(Icons.phone_in_talk),
            label: 'Calls',
          ),
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school),
            label: 'Learn',
          ),
          NavigationDestination(
            icon: Icon(Icons.translate_outlined),
            selectedIcon: Icon(Icons.translate),
            label: 'Translate',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  /// Crown shortcut to the Pro paywall. Hidden for users already on Pro.
  Widget _proButton() {
    return ValueListenableBuilder<Entitlements>(
      valueListenable: EntitlementService.instance.notifier,
      builder: (context, ent, _) {
        if (ent.isPro) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ProPaywallScreen(),
            )),
            borderRadius: BorderRadius.circular(20),
            child: const Tooltip(
              message: 'Upgrade to ConFriKa Pro',
              child: Icon(Icons.workspace_premium, color: Color(0xFFE87722)),
            ),
          ),
        );
      },
    );
  }

  Widget _themeToggle(bool isDark) {
    return InkWell(
      onTap: widget.onToggleThemeMode,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: isDark ? Colors.white12 : const Color(0xFFF1F5F9),
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark ? Colors.white24 : Colors.black.withValues(alpha: 0.08),
          ),
        ),
        child: Center(
          child: Text(isDark ? '🌙' : '☀️', style: const TextStyle(fontSize: 14)),
        ),
      ),
    );
  }

  /// Compact language chip: globe + 2-letter code, opens a popup menu.
  Widget _languageChip(bool isDark) {
    final current = _currentReading();
    return PopupMenuButton<String>(
      tooltip: 'Reading language',
      position: PopupMenuPosition.under,
      onSelected: (v) => ConFriKaSession.instance.setPreferredLanguage(v),
      itemBuilder: (_) => _kReadingLanguages
          .map((e) => PopupMenuItem<String>(
                value: e[0],
                child: Row(
                  children: [
                    if (e[0] == current[0])
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.check, size: 16, color: Color(0xFF2D8A4E)),
                      ),
                    Text(e[1], style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ))
          .toList(),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isDark ? Colors.white10 : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark ? Colors.white24 : Colors.black.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 15),
            const SizedBox(width: 4),
            Text(
              current[2],
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, size: 15),
          ],
        ),
      ),
    );
  }

  /// Compact live connection indicator: a dot plus the online count.
  Widget _connectionDot(bool isDark) {
    final online = _connected;
    final color = online ? const Color(0xFF10B981) : Colors.grey;
    final count = _onlineCount ?? 0;
    // Show a count only when there's actually someone online; a bare "0" is
    // noise, so online-with-nobody shows just the green dot.
    final label = online ? (count > 0 ? '$count' : '') : 'off';
    return Tooltip(
      message: online
          ? '${_onlineCount ?? 0} people online'
          : 'Reconnecting…',
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('●', style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: online ? const Color(0xFF047857) : Colors.grey.shade700,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
