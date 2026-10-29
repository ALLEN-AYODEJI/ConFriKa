import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../../core/session.dart';
import '../../core/widgets/confrika_brand_widgets.dart';
import 'change_password_screen.dart';
import '../../core/widgets/user_avatar.dart';
import 'edit_profile_screen.dart';
import 'privacy_settings_screen.dart';

class ProfileAndTrustScreen extends StatefulWidget {
  const ProfileAndTrustScreen({super.key});

  @override
  State<ProfileAndTrustScreen> createState() => _ProfileAndTrustScreenState();
}

class _ProfileAndTrustScreenState extends State<ProfileAndTrustScreen> {
  final _api = ConFriKaApiClient.instance;
  double _f0 = 138.0;
  bool _savingBaseline = false;

  @override
  void initState() {
    super.initState();
    _f0 = ConFriKaSession.instance.f0BaselineHz;
    _refreshProfile();
  }

  Future<void> _refreshProfile() async {
    try {
      final me = await _api.me();
      await ConFriKaSession.instance.updateUser(me);
      if (mounted) setState(() => _f0 = ConFriKaSession.instance.f0BaselineHz);
    } on ApiException {
      // Keep cached profile on failure.
    }
  }

  Future<void> _saveBaseline() async {
    setState(() => _savingBaseline = true);
    try {
      await _api.updateTonalBaseline(_f0);
      final me = await _api.me();
      await ConFriKaSession.instance.updateUser(me);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice baseline updated.')),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _savingBaseline = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ConFriKaSession.instance;
    final user = s.user ?? const {};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const ConFriKaTriColorBar(height: 6),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    UserAvatar(
                      name: s.displayName,
                      avatarUrl: s.user?['avatar_url'] as String?,
                      radius: 28,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.displayName,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          Text(s.username, style: const TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              _row(Icons.mail_outline, 'Email', user['email']?.toString() ?? 'Not set'),
              _row(Icons.public, 'Country', '${user['country_code'] ?? ''}'),
              _row(Icons.place_outlined, 'Origin', user['origin_region']?.toString() ?? 'Not set'),
              _row(Icons.record_voice_over_outlined, 'Dialect',
                  user['primary_dialect']?.toString() ?? 'Not set'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.manage_accounts_outlined),
                title: const Text('Edit profile'),
                subtitle: const Text('Name, country, origin, dialect'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const EditProfileScreen(),
                  ));
                  if (mounted) setState(() {});
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Privacy'),
                subtitle: const Text('Who can call or message you · images'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PrivacySettingsScreen(),
                  ));
                  if (mounted) setState(() {});
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.lock_reset),
                title: const Text('Change password'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ChangePasswordScreen(),
                )),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Voice pitch baseline (F0)',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const Text('Used to calibrate tonal coaching to your natural pitch.',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                Slider(
                  value: _f0,
                  min: 70,
                  max: 350,
                  divisions: 280,
                  label: '${_f0.round()} Hz',
                  onChanged: (v) => setState(() => _f0 = v),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${_f0.round()} Hz',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    FilledButton(
                      onPressed: _savingBaseline ? null : _saveBaseline,
                      child: _savingBaseline
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Privacy Policy'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showDoc(context, 'Privacy Policy', _privacy),
              ),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Terms of Service'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showDoc(context, 'Terms of Service', _terms),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => ConFriKaSession.instance.signOut(),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => _confirmDeleteAccount(context),
          child: const Text('Delete my account',
              style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final pwCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This permanently deletes your account, messages and '
                'contacts. This cannot be undone.'),
            const SizedBox(height: 12),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Confirm your password', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || pwCtrl.text.isEmpty) return;
    try {
      await ConFriKaApiClient.instance.deleteAccount(pwCtrl.text);
      await ConFriKaSession.instance.signOut();
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Widget _row(IconData icon, String label, String value) => ListTile(
        leading: Icon(icon, size: 20),
        title: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        subtitle: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        dense: true,
      );

  void _showDoc(BuildContext context, String title, String body) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: controller,
            children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(body, style: const TextStyle(fontSize: 13, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }

  static const _privacy =
      'ConFriKa collects only the data needed to provide translation, messaging, '
      'and calling: your account details, messages you send, and (if you opt in) '
      'voice samples used for tonal coaching. Translation is processed on our own '
      'servers using open neural models; we do not sell your data. Call audio is '
      'peer-to-peer and does not pass through our servers. You can delete your '
      'account at any time. See the full policy at confrika.online/privacy.';

  static const _terms =
      'By using ConFriKa you agree to use the service lawfully and respectfully. '
      'Automatic translation is provided on a best-effort basis and may contain '
      'errors; do not rely on it for legal, medical, or safety-critical use. '
      'No-App (PSTN) calling is not yet available. See the full terms at '
      'confrika.online/terms.';
}
