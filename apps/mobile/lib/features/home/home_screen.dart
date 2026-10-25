import 'package:flutter/material.dart';

import '../../core/constants/african_countries.dart';
import '../../core/network/api_client.dart';
import '../../core/session.dart';
import '../../core/theme/confrika_theme.dart';
import '../../core/widgets/confrika_brand_widgets.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback onOpenGlobalSpaces;
  final VoidCallback onOpenToneCoach;
  final VoidCallback onOpenTranslate;
  final ValueChanged<String> onStartCall;
  final ValueChanged<Map<String, dynamic>>? onOpenDirectMessage;

  const HomeScreen({
    super.key,
    required this.onOpenGlobalSpaces,
    required this.onOpenToneCoach,
    required this.onOpenTranslate,
    required this.onStartCall,
    this.onOpenDirectMessage,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ConFriKaApiClient.instance;
  final _usernameCtrl = TextEditingController();

  List<dynamic> _contacts = [];
  bool _loadingContacts = true;
  String? _contactsError;
  String _welcomeWord = 'WELCOME';
  int? _onlineCount;
  bool _adding = false;

  // Selected Country, Spoken Language, and Dialect (Defaulting to Nigeria / Yoruba)
  late AfricanCountryInfo _selectedCountry;
  String _selectedSpokenLang = '🌍 English';
  late String _selectedDialect;

  // Real learning progress, loaded from /api/v1/auth/me/stats (never fabricated).
  int _streakDays = 0;
  int _xp = 0;
  int _wordsLearned = 0;
  bool _isCalibrated = false;

  final List<String> _spokenLanguages = const [
    '🌍 English',
    '🌍 Français (French)',
    '🌍 Português (Portuguese)',
    '🌍 العربية (Arabic)',
    '🌍 Kiswahili',
    '🌍 Hausa',
    '🌍 Yorùbá',
    '🌍 Igbo',
    '🌍 isiZulu',
    '🌍 Amharic',
  ];

  @override
  void initState() {
    super.initState();
    // Reflect the signed-in user's real country & dialect (falls back to NG
    // only if the profile code is unrecognised).
    final s = ConFriKaSession.instance;
    _selectedCountry = kAll54AfricanCountries.firstWhere(
      (c) => c.code == s.countryCode,
      orElse: () => kAll54AfricanCountries.firstWhere(
        (c) => c.code == 'NG',
        orElse: () => kAll54AfricanCountries.first,
      ),
    );
    final mineFirst = s.primaryDialect.split(' ').first;
    final dialect = _selectedCountry.dialects.firstWhere(
      (d) => s.primaryDialect.contains(d) || d.contains(mineFirst),
      orElse: () => _selectedCountry.dialects.first,
    );
    _selectedDialect = '${_selectedCountry.flag} $dialect';
    _refresh();
    _loadWelcome();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loadingContacts = true;
      _contactsError = null;
    });
    // Contacts is the critical call — load it on its own so a hiccup in the
    // presence/stats calls can never make the contacts list look "failed".
    try {
      final c = await _api.contacts();
      if (mounted) setState(() => _contacts = c);
    } on ApiException catch (e) {
      if (mounted) setState(() => _contactsError = e.message);
    } finally {
      if (mounted) setState(() => _loadingContacts = false);
    }
    // Presence + learning stats are best-effort; they never block or error the
    // contacts view.
    _api.health().then((h) {
      if (mounted) {
        setState(() => _onlineCount = (h['online_users'] as num?)?.toInt());
      }
    }).catchError((_) {});
    _api.meStats().then((stats) {
      if (!mounted) return;
      setState(() {
        _streakDays = (stats['streak_days'] as num?)?.toInt() ?? 0;
        _xp = (stats['xp'] as num?)?.toInt() ?? 0;
        _wordsLearned = (stats['words_learned'] as num?)?.toInt() ?? 0;
        _isCalibrated = stats['is_calibrated'] == true;
      });
    }).catchError((_) {});
  }

  /// Translate the "WELCOME" eyebrow into the user's registration dialect
  /// (best-effort; falls back to English). Non-English dialects only.
  Future<void> _loadWelcome() async {
    final dialect = ConFriKaSession.instance.primaryDialect.trim();
    if (dialect.isEmpty || dialect.toLowerCase().contains('english')) return;
    try {
      final res = await _api.translate(
        text: 'Welcome',
        sourceDialect: 'English',
        targetDialect: dialect,
      );
      final t = (res['translated_text'] as String?)?.trim();
      if (t != null && t.isNotEmpty && mounted) {
        setState(() => _welcomeWord = t.toUpperCase());
      }
    } catch (_) {
      // keep the English fallback
    }
  }

  Future<void> _addContact() async {
    final raw = _usernameCtrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _adding = true);
    try {
      await _api.addContact(raw);
      _usernameCtrl.clear();
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Contact added.')),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _onCountryChanged(AfricanCountryInfo? country) {
    if (country == null) return;
    setState(() {
      _selectedCountry = country;
      _selectedDialect = '${country.flag} ${country.dialects.first}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ConFriKaSession.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // ================= 1. HERO WELCOME CARD =================
          Card(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08),
              ),
            ),
            elevation: 0,
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ConFriKaTriColorBar(height: 6),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header Row: Welcome + Streak / XP
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      _welcomeWord,
                                      style: const TextStyle(
                                        color: ConFriKaColors.sunsetOrange,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: ConFriKaColors.sunsetOrange,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                RichText(
                                  text: TextSpan(
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      color: isDark ? Colors.white : Colors.black87,
                                    ),
                                    children: [
                                      TextSpan(
                                        text: '${_selectedCountry.greeting}, ',
                                      ),
                                      TextSpan(
                                        text: '${session.displayName}!',
                                        style: const TextStyle(
                                          color: ConFriKaColors.oceanBlue,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'Speak your language. Connect across Africa.',
                                  style: TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: ConFriKaColors.sunsetOrange.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: ConFriKaColors.sunsetOrange.withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Text(
                                  _streakDays > 0
                                      ? '🔥 $_streakDays-day streak'
                                      : '🔥 Start your streak',
                                  style: const TextStyle(
                                    color: ConFriKaColors.sunsetOrange,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$_xp XP',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // MY COUNTRY Card with Region Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'MY COUNTRY',
                                  style: TextStyle(
                                    color: ConFriKaColors.oceanBlue,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                Text(
                                  _selectedCountry.region,
                                  style: const TextStyle(
                                    color: ConFriKaColors.savannaGreen,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            DropdownButtonHideUnderline(
                              child: DropdownButton<AfricanCountryInfo>(
                                value: _selectedCountry,
                                isExpanded: true,
                                icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                                onChanged: _onCountryChanged,
                                items: kAll54AfricanCountries.map((c) {
                                  return DropdownMenuItem<AfricanCountryInfo>(
                                    value: c,
                                    child: Text(
                                      '${c.flag} ${c.name} • ${c.region}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Two-Column Grid: I SPEAK & MY DIALECT
                      Row(
                        children: [
                          // Left: I SPEAK
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'I SPEAK',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: _selectedSpokenLang,
                                      isExpanded: true,
                                      icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: isDark ? Colors.white : Colors.black87,
                                      ),
                                      onChanged: (val) {
                                        if (val != null) setState(() => _selectedSpokenLang = val);
                                      },
                                      items: _spokenLanguages.map((l) {
                                        return DropdownMenuItem<String>(
                                          value: l,
                                          child: Text(l, overflow: TextOverflow.ellipsis),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),

                          // Right: MY DIALECT (With active blue accent border)
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: ConFriKaColors.oceanBlue.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: ConFriKaColors.oceanBlue,
                                  width: 2,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'MY DIALECT',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      color: ConFriKaColors.oceanBlue,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: _selectedCountry.dialects.any((d) => _selectedDialect.contains(d))
                                          ? _selectedDialect
                                          : '${_selectedCountry.flag} ${_selectedCountry.dialects.first}',
                                      isExpanded: true,
                                      icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: isDark ? Colors.white : Colors.black87,
                                      ),
                                      onChanged: (val) {
                                        if (val != null) setState(() => _selectedDialect = val);
                                      },
                                      items: _selectedCountry.dialects.map((d) {
                                        final full = '${_selectedCountry.flag} $d';
                                        return DropdownMenuItem<String>(
                                          value: full,
                                          child: Text(full, overflow: TextOverflow.ellipsis),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Voice & Tone Profile Card
                      InkWell(
                        onTap: widget.onOpenToneCoach,
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: ConFriKaColors.oceanBlue,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Center(
                                  child: Text(
                                    'ılı',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Text(
                                          'Voice & Tone Profile',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(width: 5),
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            color: _isCalibrated
                                                ? const Color(0xFF10B981)
                                                : Colors.grey,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _isCalibrated
                                          ? 'Calibrated • $_wordsLearned words learned'
                                          : 'Not calibrated yet • Tap to start',
                                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                              const Text(
                                'Open →',
                                style: TextStyle(
                                  color: ConFriKaColors.oceanBlue,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ================= 2. GLOBAL CHAT BANNER CARD =================
          Card(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: ConFriKaColors.oceanBlue.withValues(alpha: 0.25),
                width: 1.5,
              ),
            ),
            elevation: 0,
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            child: InkWell(
              onTap: widget.onOpenGlobalSpaces,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: ConFriKaColors.oceanBlue,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: Text('🌍', style: TextStyle(fontSize: 20)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Global Chat',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _onlineCount != null ? '$_onlineCount online' : 'Live',
                                style: const TextStyle(
                                  color: Color(0xFF10B981),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Chat and share voice notes across Africa',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    const Text(
                      'Join →',
                      style: TextStyle(
                        color: ConFriKaColors.oceanBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // ================= 3. CONTACTS & CALLS SECTION =================
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Contacts & Calls',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                  ),
                  Text(
                    'Add people by @username or select a contact to call',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ConFriKaColors.oceanBlue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'In-App Call',
                  style: TextStyle(
                    color: ConFriKaColors.oceanBlue,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Quick Add by @Username Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 0,
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '@',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: ConFriKaColors.oceanBlue,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _usernameCtrl,
                      onSubmitted: (_) => _addContact(),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Enter @username (e.g. @amaka_enugu)...',
                        hintStyle: TextStyle(fontSize: 12),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _adding ? null : _addContact,
                    style: FilledButton.styleFrom(
                      backgroundColor: ConFriKaColors.savannaGreen,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _adding
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('+ Add', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Contacts List
          if (_loadingContacts)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_contactsError != null)
            _infoCard(_contactsError!, Colors.redAccent)
          else if (_contacts.isEmpty)
            _emptyContacts()
          else
            ..._contacts.map(_contactCard),

          const SizedBox(height: 10),

          // 3. NO-APP CALL (COMING SOON)
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: Colors.amber.shade600.withValues(alpha: 0.4),
                style: BorderStyle.solid,
              ),
            ),
            elevation: 0,
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: Text('☎️', style: TextStyle(fontSize: 20)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'No-App Mobile Call',
                              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                            ),
                            Text(
                              'Call regular mobile numbers without the app',
                              style: TextStyle(fontSize: 11, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Coming Soon',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Colors.amber.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'No-App Mobile Call is Coming Soon! Use In-App Call today.',
                            ),
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text(
                        '📞 No-App Call · Coming Soon',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // + Add Contact Outline Button
          OutlinedButton.icon(
            onPressed: () => _usernameCtrl.text = '@',
            icon: const Icon(Icons.add, size: 18),
            label: const Text(
              '+ Add Contact by @Username',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: ConFriKaColors.oceanBlue,
              side: BorderSide(color: ConFriKaColors.oceanBlue.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _emptyContacts() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      child: const Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            Text('👋', style: TextStyle(fontSize: 28)),
            SizedBox(height: 8),
            Text(
              'No contacts yet',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
            ),
            SizedBox(height: 4),
            Text(
              'Add someone by their @username above to start calling and messaging.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoCard(String text, Color color) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(text, style: TextStyle(color: color, fontSize: 13)),
        ),
      );

  Color _avatarColor(Map<String, dynamic> m) {
    const palette = [
      ConFriKaColors.oceanBlue,
      ConFriKaColors.sunsetOrange,
      ConFriKaColors.savannaGreen,
    ];
    final key = (m['username'] ?? m['name'] ?? '').toString();
    return palette[key.hashCode.abs() % palette.length];
  }

  Widget _contactCard(dynamic c) {
    final m = c as Map<String, dynamic>;
    final online = m['is_online'] == true;
    final initials = m['initials']?.toString() ?? '·';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: ConFriKaColors.oceanBlue.withValues(alpha: 0.25),
            width: 1.5,
          ),
        ),
        elevation: 0,
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: _avatarColor(m).withValues(alpha: 0.15),
                        child: Text(
                          initials,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: _avatarColor(m),
                          ),
                        ),
                      ),
                      if (online)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              m['name']?.toString() ?? '',
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: ConFriKaColors.oceanBlue.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                m['username']?.toString() ?? '',
                                style: const TextStyle(
                                  color: ConFriKaColors.oceanBlue,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${m['flag'] ?? '🌍'} ${m['origin'] ?? ''} • ${m['dialect'] ?? ''}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: ConFriKaColors.oceanBlue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'In-App Call',
                      style: TextStyle(
                        color: ConFriKaColors.oceanBlue,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => widget.onStartCall(m['username'].toString()),
                      style: FilledButton.styleFrom(
                        backgroundColor: ConFriKaColors.oceanBlue,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      icon: const Icon(Icons.phone, size: 16),
                      label: const Text('Call', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      if (widget.onOpenDirectMessage != null) {
                        widget.onOpenDirectMessage!(m);
                      } else {
                        widget.onOpenGlobalSpaces();
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                    label: const Text('Message', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
