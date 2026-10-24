import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../core/services/billing_service.dart';
import '../../core/services/entitlement_service.dart';
import '../../core/theme/confrika_theme.dart';

/// ConFriKa Pro upgrade screen. Shows the benefits, the available
/// subscription products, and drives the store purchase flow.
class ProPaywallScreen extends StatefulWidget {
  const ProPaywallScreen({super.key, this.reason});

  /// Optional context line (e.g. the message from a 402 that brought the user
  /// here, such as "You've reached today's free translations limit.").
  final String? reason;

  @override
  State<ProPaywallScreen> createState() => _ProPaywallScreenState();
}

class _ProPaywallScreenState extends State<ProPaywallScreen> {
  List<ProductDetails> _products = const [];
  bool _loading = true;

  static const _benefits = <(IconData, String)>[
    (Icons.translate, 'Unlimited translations'),
    (Icons.record_voice_over, 'Unlimited call translation in your own voice'),
    (Icons.groups, 'Join & create unlimited communities'),
    (Icons.block, 'No ads'),
  ];

  @override
  void initState() {
    super.initState();
    BillingService.instance.init();
    _load();
  }

  Future<void> _load() async {
    final products = await BillingService.instance.loadProducts();
    if (!mounted) return;
    setState(() {
      _products = products;
      _loading = false;
    });
  }

  String _label(ProductDetails p) {
    if (p.id == BillingService.yearlyId) return 'Yearly';
    if (p.id == BillingService.monthlyId) return 'Monthly';
    return p.title.isNotEmpty ? p.title : p.id;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ConFriKa Pro')),
      body: ValueListenableBuilder<Entitlements>(
        valueListenable: EntitlementService.instance.notifier,
        builder: (context, ent, _) {
          if (ent.isPro) return _alreadyPro(context, ent);
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [
                      ConFriKaColors.oceanBlue,
                      ConFriKaColors.savannaGreen,
                    ]),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Go Pro, Connect Africa without limits',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700)),
                      SizedBox(height: 6),
                      Text('Unlock everything ConFriKa can do.',
                          style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
                if (widget.reason != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ConFriKaColors.sunsetOrange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(widget.reason!,
                        style: const TextStyle(
                            color: ConFriKaColors.sunsetOrange,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
                const SizedBox(height: 20),
                ..._benefits.map((b) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        Icon(b.$1, color: cs.tertiary),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(b.$2,
                                style: const TextStyle(fontSize: 15))),
                      ]),
                    )),
                const SizedBox(height: 20),
                if (_loading)
                  const Center(child: Padding(
                      padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                else if (_products.isEmpty)
                  _noProducts(context)
                else
                  ..._products.map((p) => _productCard(context, p)),
                const SizedBox(height: 12),
                ValueListenableBuilder<String?>(
                  valueListenable: BillingService.instance.status,
                  builder: (context, s, _) => s == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(s, textAlign: TextAlign.center),
                        ),
                ),
                TextButton(
                  onPressed: () => BillingService.instance.restore(),
                  child: const Text('Restore purchases'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Subscriptions renew automatically until canceled. Manage or '
                  'cancel anytime in your store account. Payment is charged to '
                  'your store account on confirmation.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withValues(alpha: 0.55)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _productCard(BuildContext context, ProductDetails p) {
    final best = p.id == BillingService.yearlyId;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        title: Row(children: [
          Text(_label(p),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          if (best) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: ConFriKaColors.savannaGreen,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('BEST VALUE',
                  style: TextStyle(color: Colors.white, fontSize: 10)),
            ),
          ],
        ]),
        subtitle: Text(p.price, style: const TextStyle(fontSize: 15)),
        trailing: ValueListenableBuilder<bool>(
          valueListenable: BillingService.instance.busy,
          builder: (context, busy, _) => FilledButton(
            onPressed: busy ? null : () => BillingService.instance.buy(p),
            child: const Text('Subscribe'),
          ),
        ),
      ),
    );
  }

  Widget _noProducts(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Pro plans are not available right now. This usually means the store '
          'is offline or the products are still being set up. Please try again '
          'later.',
          textAlign: TextAlign.center,
        ),
      );

  Widget _alreadyPro(BuildContext context, Entitlements ent) {
    final exp = ent.expiresAt;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.workspace_premium,
              size: 64, color: Theme.of(context).colorScheme.tertiary),
          const SizedBox(height: 16),
          const Text('You are on ConFriKa Pro',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (exp != null)
            Text('Renews / expires ${exp.toLocal().toString().split(' ').first}'),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ]),
      ),
    );
  }
}
