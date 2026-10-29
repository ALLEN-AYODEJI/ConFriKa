import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../../core/services/entitlement_service.dart';
import '../../core/session.dart';
import '../../core/theme/confrika_theme.dart';
import '../billing/pro_paywall_screen.dart';

/// Teach & Earn: learn from native speakers, and — if you're a native speaker —
/// teach your language and earn rewards. Two tabs:
///  • Find a teacher — browse/search teachers, open a page, rate & confirm.
///  • My teaching    — become a teacher, see ratings/reward, request a payout.
class TeachAndEarnScreen extends StatelessWidget {
  const TeachAndEarnScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Teach & Earn'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Find a teacher'),
              Tab(text: 'My teaching'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _FindTeacherTab(),
            _MyTeachingTab(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Find a teacher: search + top-rated list.
// ─────────────────────────────────────────────────────────────────────────────
class _FindTeacherTab extends StatefulWidget {
  const _FindTeacherTab();

  @override
  State<_FindTeacherTab> createState() => _FindTeacherTabState();
}

class _FindTeacherTabState extends State<_FindTeacherTab> {
  final _api = ConFriKaApiClient.instance;
  final _search = TextEditingController();

  List<dynamic> _teachers = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _api.teachers(q: _search.text);
      if (!mounted) return;
      setState(() {
        _teachers = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: 'Search name, @username or language',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _load,
              ),
            ),
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _teachers.isEmpty) {
      return _ErrorRetry(message: _error!, onRetry: _load);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _teachers.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 80),
                _EmptyTeachers(),
              ],
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              itemCount: _teachers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _TeacherCard(
                data: _teachers[i] as Map<String, dynamic>,
                onTap: () => _open(_teachers[i] as Map<String, dynamic>),
              ),
            ),
    );
  }

  Future<void> _open(Map<String, dynamic> t) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _TeacherDetailScreen(username: t['username'] as String),
      ),
    );
    if (changed == true) _load();
  }
}

class _EmptyTeachers extends StatelessWidget {
  const _EmptyTeachers();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(Icons.school_outlined, size: 44, color: Theme.of(context).hintColor),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'No teachers yet. Native speakers who open the “My teaching” tab show up '
            'here for learners to find and learn from.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      ],
    );
  }
}

class _TeacherCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  const _TeacherCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final langs = (data['languages'] as List?)?.cast<String>() ?? const [];
    final verified = data['is_verified'] == true;
    final avg = (data['avg_rating'] as num?)?.toDouble() ?? 0.0;
    final ratingCount = (data['rating_count'] as num?)?.toInt() ?? 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(data: data),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            (data['full_name'] as String?)?.trim().isNotEmpty == true
                                ? data['full_name'] as String
                                : data['username'] as String? ?? '',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (verified) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.verified,
                              size: 16, color: ConFriKaColors.oceanBlue),
                        ],
                      ],
                    ),
                    if ((data['headline'] as String?)?.trim().isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          data['headline'] as String,
                          style: const TextStyle(fontSize: 12.5, color: Colors.grey),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _RatingPill(avg: avg, count: ratingCount),
                        for (final l in langs.take(3)) _LangChip(label: l),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final Map<String, dynamic> data;
  final double size;
  const _Avatar({required this.data, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final url = data['avatar_url'] as String?;
    final name = (data['full_name'] as String?)?.trim();
    final initial = (name?.isNotEmpty == true
            ? name!
            : (data['username'] as String? ?? '?').replaceAll('@', ''))
        .characters
        .first
        .toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: ConFriKaColors.oceanBlue,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: url != null && url.trim().isNotEmpty
          ? Image.network(
              ConFriKaApiClient.instance.mediaUrl(url),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _initialAvatar(initial),
            )
          : _initialAvatar(initial),
    );
  }

  Widget _initialAvatar(String initial) => Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: size * 0.4,
          ),
        ),
      );
}

class _RatingPill extends StatelessWidget {
  final double avg;
  final int count;
  const _RatingPill({required this.avg, required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count == 0 ? 'New' : '${avg.toStringAsFixed(1)} ($count)';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ConFriKaColors.amberHighlight.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 13, color: ConFriKaColors.amberHighlight),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFB45309))),
        ],
      ),
    );
  }
}

class _LangChip extends StatelessWidget {
  final String label;
  const _LangChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ConFriKaColors.savannaGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: ConFriKaColors.savannaGreen)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Teacher page: full bio (Pro) / blurred teaser (free) + rate & confirm.
// ─────────────────────────────────────────────────────────────────────────────
class _TeacherDetailScreen extends StatefulWidget {
  final String username;
  const _TeacherDetailScreen({required this.username});

  @override
  State<_TeacherDetailScreen> createState() => _TeacherDetailScreenState();
}

class _TeacherDetailScreenState extends State<_TeacherDetailScreen> {
  final _api = ConFriKaApiClient.instance;
  Map<String, dynamic>? _teacher;
  bool _loading = true;
  String? _error;
  bool _changed = false; // did the viewer's rating change? (refresh the list)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final t = await _api.teacher(widget.username);
      if (!mounted) return;
      setState(() {
        _teacher = t;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Teacher')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorRetry(message: _error!, onRetry: _load)
                : _content(_teacher!),
      ),
    );
  }

  Widget _content(Map<String, dynamic> t) {
    final langs = (t['languages'] as List?)?.cast<String>() ?? const [];
    final verified = t['is_verified'] == true;
    final avg = (t['avg_rating'] as num?)?.toDouble() ?? 0.0;
    final ratingCount = (t['rating_count'] as num?)?.toInt() ?? 0;
    final confirmedCount = (t['confirmed_count'] as num?)?.toInt() ?? 0;
    final bioLocked = t['bio_locked'] == true;
    final bio = t['bio'] as String?;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(data: t, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          (t['full_name'] as String?)?.trim().isNotEmpty == true
                              ? t['full_name'] as String
                              : t['username'] as String? ?? '',
                          style: const TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w900),
                        ),
                      ),
                      if (verified) ...[
                        const SizedBox(width: 5),
                        const Icon(Icons.verified,
                            size: 18, color: ConFriKaColors.oceanBlue),
                      ],
                    ],
                  ),
                  Text(t['username'] as String? ?? '',
                      style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _RatingPill(avg: avg, count: ratingCount),
                      for (final l in langs) _LangChip(label: l),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if ((t['headline'] as String?)?.trim().isNotEmpty == true)
          Text(t['headline'] as String,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),

        // Bio — locked (blurred teaser) for non-Pro learners.
        _BioSection(bio: bio, locked: bioLocked),

        const SizedBox(height: 10),
        Text('$confirmedCount learners confirmed this pronunciation is correct.',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 20),

        _RateSection(
          teacher: t,
          onRated: () {
            _changed = true;
            _load();
          },
        ),
      ],
    );
  }
}

class _BioSection extends StatelessWidget {
  final String? bio;
  final bool locked;
  const _BioSection({required this.bio, required this.locked});

  @override
  Widget build(BuildContext context) {
    if (bio == null || bio!.trim().isEmpty) {
      return const Text('This teacher hasn’t written a bio yet.',
          style: TextStyle(color: Colors.grey));
    }
    if (!locked) {
      return Text(bio!, style: const TextStyle(fontSize: 14, height: 1.4));
    }
    // Blurred teaser + upgrade nudge.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Text(bio!,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: Colors.grey.withValues(alpha: 0.55),
                )),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Theme.of(context).scaffoldBackgroundColor,
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: ConFriKaColors.sunsetOrange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: ConFriKaColors.sunsetOrange.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              const Row(
                children: [
                  Icon(Icons.lock_outline,
                      size: 18, color: ConFriKaColors.sunsetOrange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Learning from teachers is a ConFriKa Pro feature.',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ProPaywallScreen(),
                  )),
                  style: FilledButton.styleFrom(
                      backgroundColor: ConFriKaColors.sunsetOrange),
                  icon: const Icon(Icons.workspace_premium, size: 18),
                  label: const Text('Unlock with Pro'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RateSection extends StatefulWidget {
  final Map<String, dynamic> teacher;
  final VoidCallback onRated;
  const _RateSection({required this.teacher, required this.onRated});

  @override
  State<_RateSection> createState() => _RateSectionState();
}

class _RateSectionState extends State<_RateSection> {
  final _api = ConFriKaApiClient.instance;
  final _comment = TextEditingController();
  late int _stars;
  late bool _confirmed;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final mine = widget.teacher['my_rating'] as Map<String, dynamic>?;
    _stars = (mine?['stars'] as num?)?.toInt() ?? 5;
    _confirmed = mine?['confirmed'] as bool? ?? true;
    _comment.text = mine?['comment'] as String? ?? '';
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  bool get _isSelf =>
      (widget.teacher['username'] as String?) == ConFriKaSession.instance.username;

  Future<void> _submit() async {
    if (!EntitlementService.instance.isPro) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const ProPaywallScreen(),
      ));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.rateTeacher(
        widget.teacher['username'] as String,
        stars: _stars,
        confirmed: _confirmed,
        comment: _comment.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks! Your rating helps this teacher.')),
      );
      widget.onRated();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isSelf) {
      return const SizedBox.shrink(); // you can't rate yourself
    }
    final existing = widget.teacher['my_rating'] != null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(existing ? 'Your rating' : 'Rate this teacher',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  onPressed: _saving ? null : () => setState(() => _stars = i),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  icon: Icon(
                    i <= _stars ? Icons.star : Icons.star_border,
                    color: ConFriKaColors.amberHighlight,
                    size: 30,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _confirmed,
            onChanged: _saving ? null : (v) => setState(() => _confirmed = v),
            title: const Text('Pronunciation is correct',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text(
                'Confirming rewards the teacher and builds their credibility.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _comment,
            maxLength: 500,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'Comment (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _submit,
              style: FilledButton.styleFrom(
                  backgroundColor: ConFriKaColors.savannaGreen,
                  padding: const EdgeInsets.symmetric(vertical: 13)),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(existing ? 'Update rating' : 'Submit rating',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// My teaching: dashboard + become/edit a teacher + request payout.
// ─────────────────────────────────────────────────────────────────────────────
class _MyTeachingTab extends StatefulWidget {
  const _MyTeachingTab();

  @override
  State<_MyTeachingTab> createState() => _MyTeachingTabState();
}

class _MyTeachingTabState extends State<_MyTeachingTab> {
  final _api = ConFriKaApiClient.instance;
  Map<String, dynamic>? _dash;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await _api.myTeacherDashboard();
      if (!mounted) return;
      setState(() {
        _dash = d;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _ErrorRetry(message: _error!, onRetry: _load);
    final isTeacher = _dash?['is_teacher'] == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: isTeacher ? _teacherDashboard(_dash!) : _becomeTeacher(),
      ),
    );
  }

  // ── Not yet a teacher ──────────────────────────────────────────────────
  List<Widget> _becomeTeacher() {
    return [
      const SizedBox(height: 8),
      const Icon(Icons.volunteer_activism,
          size: 48, color: ConFriKaColors.sunsetOrange),
      const SizedBox(height: 12),
      const Center(
        child: Text('Teach your language. Earn rewards.',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      ),
      const SizedBox(height: 8),
      const Text(
        'Are you a native speaker? Set up your teaching page so learners across '
        'Africa can find you and learn real pronunciation from you. Every time a '
        'learner confirms your pronunciation is correct, you earn — and reach a '
        'verified badge once enough learners confirm you.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey, height: 1.4),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _openEditor,
        style: FilledButton.styleFrom(
            backgroundColor: ConFriKaColors.savannaGreen,
            padding: const EdgeInsets.symmetric(vertical: 14)),
        icon: const Icon(Icons.add),
        label: const Text('Become a teacher'),
      ),
    ];
  }

  // ── Existing teacher dashboard ─────────────────────────────────────────
  List<Widget> _teacherDashboard(Map<String, dynamic> d) {
    final verified = d['is_verified'] == true;
    final confirmed = (d['confirmed_count'] as num?)?.toInt() ?? 0;
    final toVerify = (d['confirmations_to_verify'] as num?)?.toInt() ?? 0;
    final threshold = (d['verify_threshold'] as num?)?.toInt() ?? 1000;
    final avg = (d['avg_rating'] as num?)?.toDouble() ?? 0.0;
    final ratingCount = (d['rating_count'] as num?)?.toInt() ?? 0;
    final reward = d['reward_display'] as String? ?? '0.00';
    final active = d['is_active'] == true;
    final progress = threshold == 0 ? 1.0 : (confirmed / threshold).clamp(0.0, 1.0);

    return [
      // Reward card.
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [ConFriKaColors.savannaGreen, ConFriKaColors.oceanBlue],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your rewards',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 4),
            Text(reward,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _withdraw,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: ConFriKaColors.oceanBlue,
                ),
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: const Text('Request payout'),
              ),
            ),
            const SizedBox(height: 4),
            const Text('Payouts are coming soon — your rewards keep accruing.',
                style: TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      ),
      const SizedBox(height: 14),

      // Verified / progress.
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(verified ? Icons.verified : Icons.verified_outlined,
                    size: 20,
                    color: verified
                        ? ConFriKaColors.oceanBlue
                        : Colors.grey),
                const SizedBox(width: 8),
                Text(verified ? 'Verified teacher' : 'Working toward verified',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: Colors.grey.withValues(alpha: 0.2),
                color: ConFriKaColors.savannaGreen,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              verified
                  ? '$confirmed confirmations — you’re verified and monetized.'
                  : '$confirmed of $threshold confirmations • $toVerify to go',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),

      // Stats row.
      Row(
        children: [
          _StatTile(
              label: 'Rating',
              value: ratingCount == 0 ? '—' : avg.toStringAsFixed(1),
              icon: Icons.star,
              color: ConFriKaColors.amberHighlight),
          const SizedBox(width: 10),
          _StatTile(
              label: 'Ratings',
              value: '$ratingCount',
              icon: Icons.people_outline,
              color: ConFriKaColors.oceanBlue),
          const SizedBox(width: 10),
          _StatTile(
              label: 'Confirmed',
              value: '$confirmed',
              icon: Icons.check_circle_outline,
              color: ConFriKaColors.savannaGreen),
        ],
      ),
      const SizedBox(height: 16),

      // Availability toggle + edit.
      Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: SwitchListTile(
          value: active,
          onChanged: (v) => _toggleActive(d, v),
          title: const Text('Accepting learners',
              style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(active
              ? 'You appear in the teacher directory.'
              : 'You’re hidden from the directory.'),
        ),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: _openEditor,
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Edit teaching profile'),
      ),
    ];
  }

  Future<void> _toggleActive(Map<String, dynamic> d, bool value) async {
    try {
      final updated = await _api.upsertTeacherProfile(
        headline: d['headline'] as String?,
        bio: d['bio'] as String?,
        languages: ((d['languages'] as List?)?.cast<String>() ?? const []).join(', '),
        isActive: value,
      );
      if (!mounted) return;
      setState(() => _dash = updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _withdraw() async {
    try {
      final res = await _api.requestTeacherWithdrawal();
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Payout requested'),
          content: Text(res['message'] as String? ??
              'Payouts are coming soon. Your rewards are safe.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _openEditor() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TeacherProfileSheet(existing: _dash),
    );
    if (saved == true) _load();
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.w900, fontSize: 17, color: color)),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _TeacherProfileSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _TeacherProfileSheet({this.existing});

  @override
  State<_TeacherProfileSheet> createState() => _TeacherProfileSheetState();
}

class _TeacherProfileSheetState extends State<_TeacherProfileSheet> {
  final _api = ConFriKaApiClient.instance;
  final _headline = TextEditingController();
  final _bio = TextEditingController();
  final _languages = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null && e['is_teacher'] == true) {
      _headline.text = e['headline'] as String? ?? '';
      _bio.text = e['bio'] as String? ?? '';
      _languages.text =
          ((e['languages'] as List?)?.cast<String>() ?? const []).join(', ');
    } else {
      // Pre-fill with the user's own dialect as a convenient starting point.
      _languages.text = ConFriKaSession.instance.primaryDialect;
    }
  }

  @override
  void dispose() {
    _headline.dispose();
    _bio.dispose();
    _languages.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_languages.text.trim().isEmpty) {
      setState(() => _error = 'Add at least one language you teach.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.upsertTeacherProfile(
        headline: _headline.text.trim(),
        bio: _bio.text.trim(),
        languages: _languages.text.trim(),
        isActive: true,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing?['is_teacher'] == true;
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(editing ? 'Edit teaching profile' : 'Become a teacher',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
                'Tell learners what you teach and why they should learn from you.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 14),
            TextField(
              controller: _languages,
              decoration: const InputDecoration(
                labelText: 'Languages / dialects you teach',
                helperText: 'Comma-separated, e.g. Yorùbá, Igbo',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _headline,
              maxLength: 160,
              decoration: const InputDecoration(
                labelText: 'Headline',
                hintText: 'Native Yorùbá speaker • tones made simple',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _bio,
              maxLength: 2000,
              maxLines: 5,
              minLines: 3,
              decoration: const InputDecoration(
                labelText: 'Bio',
                hintText: 'Your background, how you teach, what learners gain…',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                  backgroundColor: ConFriKaColors.savannaGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(editing ? 'Save changes' : 'Create my teaching page',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
