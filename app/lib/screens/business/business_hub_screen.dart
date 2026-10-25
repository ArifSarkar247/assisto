import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../business_khata_api.dart';
import '../../widgets/skeleton.dart';
import 'business_common.dart';
import 'business_setup_screen.dart';
import 'khata_screen.dart';
import 'cashbox_screen.dart';
// Sibling-agent screens (selling + AI, already present at integration). These
// take a businessId / handle their own gating. See the routing contract in the
// integrator report.
import 'products_screen.dart';
import 'quick_sell_screen.dart';
import 'orders_screen.dart';
import 'customers_screen.dart';
import 'reports_screen.dart';
import 'payments_screen.dart';
import 'ai_assistant_screen.dart';
import 'supplier_market_screen.dart';
import 'demand_map_screen.dart';
import 'bargain_rules_screen.dart';
import 'business_plans_screen.dart';
import 'bizagent/seller_agent_screen.dart'; // p1-bizagent
import '../../services/action_feedback.dart'; // db1
import '../../services/error_report.dart'; // db1
import '../../services/error_kind.dart' show honestFailText; // qa2

/// Business HUB — the new home for Assisto Business v2 (replaces the old
/// name/price/stock business screen). Shows the selected business, a switcher
/// when the user owns several, and cards into Khata, Selling, Reports, Cashbox,
/// AI Assistant (Premium-locked when unpaid) and Setup. First run routes
/// straight into setup. Everything is bilingual via ARB; dynamic business
/// fields come from the server.
class BusinessHubScreen extends StatefulWidget {
  const BusinessHubScreen({super.key});
  @override
  State<BusinessHubScreen> createState() => _BusinessHubScreenState();
}

class _BusinessHubScreenState extends State<BusinessHubScreen> {
  List<Map<String, dynamic>> _businesses = [];
  Map<String, dynamic>? _selected;
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final r = await context.read<AppState>().api.businessList();
      _businesses =
          ((r['businesses'] ?? []) as List).cast<Map<String, dynamic>>();
      final selId = r['selected_id'];
      _selected = _businesses.isEmpty
          ? null
          : _businesses.firstWhere(
              (b) => b['id'] == selId,
              orElse: () => _businesses.first,
            );
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openSetup({bool addMore = false}) async {
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => const BusinessSetupScreen(),
    ));
    if (created == true) await _load();
  }

  Future<void> _switch(Map<String, dynamic> b) async {
    final id = (b['id'] as num?)?.toInt();
    if (id == null) return;
    setState(() => _selected = b);
    try {
      await context.read<AppState>().api.businessSelect(id);
    } catch (e) {
      showActionFailed(context, 'bizhub.switch', e); // db1
    }
  }

  void _showSwitcher() {
    final t = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t.businessSwitch,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
          ),
          for (final b in _businesses)
            ListTile(
              leading: _TypeAvatar(type: (b['type'] ?? '').toString()),
              title: Text((b['name'] ?? '').toString()),
              subtitle: Text(_typeLabel(t, (b['type'] ?? '').toString())),
              trailing: b['id'] == _selected?['id']
                  ? Icon(Icons.check_circle_rounded, color: Theme.of(ctx).colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _switch(b);
              },
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add_business_rounded),
            title: Text(t.businessAddAnother),
            onTap: () {
              Navigator.pop(ctx);
              _openSetup(addMore: true);
            },
          ),
          const SizedBox(height: Gap.sm),
        ]),
      ),
    );
  }

  void _showSelling(int bizId) {
    final t = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t.businessSelling,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.flash_on_rounded),
            title: Text(t.sellQuickSell),
            onTap: () {
              Navigator.pop(ctx);
              _go(QuickSellScreen(businessId: bizId));
            },
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_rounded),
            title: Text(t.sellProducts),
            onTap: () {
              Navigator.pop(ctx);
              _go(ProductsScreen(businessId: bizId));
            },
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_rounded),
            title: Text(t.sellOrders),
            onTap: () {
              Navigator.pop(ctx);
              _go(const OrdersScreen());
            },
          ),
          ListTile(
            leading: const Icon(Icons.people_outline_rounded),
            title: Text(t.sellCustomers),
            onTap: () {
              Navigator.pop(ctx);
              _go(CustomersScreen(businessId: bizId));
            },
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_2_rounded),
            title: Text(t.sellPayments),
            onTap: () {
              Navigator.pop(ctx);
              _go(const PaymentsScreen());
            },
          ),
          const SizedBox(height: Gap.sm),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.business)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.business)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          title: t.business,
          message: honestFailText(t, _failCause, otherwise: t.businessLoadFailed),
          action: FilledButton(onPressed: _load, child: Text(t.retry)),
        ),
      );
    }
    if (_businesses.isEmpty || _selected == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.business)),
        body: StateMessage(
          icon: Icons.storefront_rounded,
          title: t.businessWelcomeTitle,
          message: t.businessWelcomeBody,
          action: FilledButton.icon(
            icon: const Icon(Icons.add_rounded),
            onPressed: () => _openSetup(),
            label: Text(t.businessCreateFirst),
          ),
        ),
      );
    }
    return _buildHub(context, t, _selected!);
  }

  Widget _buildHub(
      BuildContext context, AppLocalizations t, Map<String, dynamic> biz) {
    final scheme = Theme.of(context).colorScheme;
    final premium = biz['is_premium'] == true;
    final role = (biz['role'] ?? 'owner').toString();
    final isStaff = role == 'staff';
    final bizId = (biz['id'] as num?)?.toInt() ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.business),
        actions: [
          IconButton(
            tooltip: t.businessSetupTitle,
            icon: const Icon(Icons.settings_rounded),
            onPressed: () => _openSetup(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            // Selected business + switcher.
            BrandBand(
              child: Row(children: [
                _TypeAvatar(
                    type: (biz['type'] ?? '').toString(), onGradient: true),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((biz['name'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: Gap.xxs),
                        Text(_typeLabel(t, (biz['type'] ?? '').toString()),
                            style: AType.bodyMedium),
                      ]),
                ),
                if (_businesses.length > 1)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    icon: const Icon(Icons.unfold_more_rounded, size: 18),
                    label: Text(t.businessSwitch),
                    onPressed: _showSwitcher,
                  )
                else
                  IconButton(
                    tooltip: t.businessAddAnother,
                    icon: const Icon(Icons.add_business_rounded),
                    onPressed: () => _openSetup(addMore: true),
                  ),
              ]),
            ),
            const SizedBox(height: Gap.lg),

            // Net-position snapshot (receivable vs payable).
            _NetPositionCard(businessId: bizId, isStaff: isStaff),
            const SizedBox(height: Gap.lg),

            Text(t.businessManage,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.md),

            _HubCard(
              icon: Icons.menu_book_rounded,
              tint: scheme.primary,
              title: t.khataTitle,
              subtitle: t.businessKhataSub,
              onTap: () => _go(KhataScreen(business: biz)),
            ),
            const SizedBox(height: Gap.md),
            _HubCard(
              icon: Icons.point_of_sale_rounded,
              tint: scheme.secondary,
              title: t.businessSelling,
              subtitle: t.businessSellingSub,
              onTap: () => _showSelling(bizId),
            ),
            const SizedBox(height: Gap.md),
            _HubCard(
              icon: Icons.account_balance_wallet_rounded,
              tint: AssistoTokens.of(context).success,
              title: t.cashboxTitle,
              subtitle: t.businessCashboxSub,
              onTap: () => _go(CashboxScreen(business: biz)),
            ),
            if (!isStaff) ...[
              const SizedBox(height: Gap.md),
              _HubCard(
                icon: Icons.insights_rounded,
                tint: scheme.tertiary,
                title: t.businessReports,
                subtitle: t.businessReportsSub,
                onTap: () => _go(ReportsScreen(businessId: bizId)),
              ),
              const SizedBox(height: Gap.md),
              _HubCard(
                icon: Icons.inventory_2_rounded,
                tint: Brand.cyan,
                title: t.supTitle,
                subtitle: t.supHubSub,
                onTap: () => _go(const SupplierMarketScreen()),
              ),
              const SizedBox(height: Gap.md),
              _HubCard(
                icon: Icons.insights_rounded,
                tint: Theme.of(context).colorScheme.error,
                title: t.demandTitle,
                subtitle: t.demandHubSub,
                onTap: () => _go(const DemandMapScreen()),
              ),
              const SizedBox(height: Gap.md),
              // Bargaining rules (Premium). The screen enforces the price floor
              // in code and shows its own gate/upgrade when unpaid; the hub just
              // mirrors the Premium badge when the business is unpaid.
              _HubCard(
                icon: Icons.handshake_rounded,
                tint: Brand.purple,
                title: t.bizBargainTitle,
                subtitle: t.bizBargainHubSub,
                locked: !premium,
                lockedLabel: t.premium,
                onTap: () => _go(const BargainRulesScreen()),
              ),
            ],
            const SizedBox(height: Gap.md),
            // AI assistant handles its own Premium gate + upgrade screen; the
            // hub just shows the Premium badge when the business is unpaid.
            _HubCard(
              icon: Icons.smart_toy_rounded,
              tint: Brand.purple,
              title: t.businessAiAssistant,
              subtitle: t.businessAiAssistantSub,
              locked: !premium,
              lockedLabel: t.premium,
              onTap: () => _go(const AiAssistantScreen()),
            ),
            const SizedBox(height: Gap.md),
            // p1-bizagent: the 24/7 AI sales agent for Page / Instagram /
            // WhatsApp (own seller plans + trial; honest setup states).
            _HubCard(
              icon: Icons.support_agent_rounded,
              tint: Brand.blue,
              title: t.baHubTitle,
              subtitle: t.baHubSub,
              onTap: () => _go(const SellerAgentScreen()),
            ),
            const SizedBox(height: Gap.md),
            // Plans comparison (Free vs Premium) — informational, open to all.
            _HubCard(
              icon: Icons.workspace_premium_rounded,
              tint: Brand.cyan,
              title: t.bizPlansTitle,
              subtitle: t.bizPlansHubSub,
              onTap: () => _go(const BusinessPlansScreen()),
            ),
            const SizedBox(height: Gap.md),
            _HubCard(
              icon: Icons.tune_rounded,
              tint: scheme.onSurfaceVariant,
              title: t.businessSetupTitle,
              subtitle: t.businessSetupSub,
              onTap: () => _openSetup(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _go(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  String _typeLabel(AppLocalizations t, String type) {
    switch (type) {
      case 'online_seller':
        return t.bizTypeOnlineSeller;
      case 'small_shop':
        return t.bizTypeSmallShop;
      case 'service':
        return t.bizTypeService;
      case 'food':
        return t.bizTypeFood;
      case 'wholesaler':
        return t.bizTypeWholesaler;
      case 'b2b':
        return t.bizTypeB2b;
      default:
        return t.business;
    }
  }
}

/// Net position header: total receivable vs payable, net + ahead/behind.
class _NetPositionCard extends StatefulWidget {
  final int businessId;
  final bool isStaff;
  const _NetPositionCard({required this.businessId, required this.isStaff});
  @override
  State<_NetPositionCard> createState() => _NetPositionCardState();
}

class _NetPositionCardState extends State<_NetPositionCard> {
  Map<String, dynamic>? _np;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _np = await context
          .read<AppState>()
          .api
          .khataNetPosition(widget.businessId);
    } catch (e) {
      // db1: automatic load (not a tap). On failure the card is HIDDEN —
      // never a fake ৳0 net position.
      reportNonFatal('bizhub.netPosition', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(Gap.lg),
          child: Skeleton(width: 180, height: 16),
        ),
      );
    }
    if (_np == null) return const SizedBox.shrink(); // db1: load failed
    final np = _np ?? const {};
    final ahead = np['ahead'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.netPositionTitle,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: _Stat(
                label: t.netReceivable,
                value: pair(context, np['receivable_display'], fallback: '৳0'),
                color: AssistoTokens.of(context).success,
              ),
            ),
            if (!widget.isStaff)
              Expanded(
                child: _Stat(
                  label: t.netPayable,
                  value: pair(context, np['payable_display'], fallback: '৳0'),
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
          ]),
          if (!widget.isStaff) ...[
            const Divider(height: Gap.xl),
            Row(children: [
              Icon(ahead ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                  color: ahead ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error, size: 20),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  '${ahead ? t.netYouAreAhead : t.netYouAreBehind} · ${pair(context, np['net_display'], fallback: '৳0')}',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: ahead ? AssistoTokens.of(context).success : scheme.onSurface),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.xxs),
      Text(value,
          style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700, color: color)),
    ]);
  }
}

class _HubCard extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool locked;
  final String? lockedLabel;
  const _HubCard({
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.locked = false,
    this.lockedLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Container(
              height: 46,
              width: 46,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(icon, color: tint),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      if (locked) ...[
                        const SizedBox(width: Gap.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: Gap.sm, vertical: Gap.xxs),
                          decoration: BoxDecoration(
                            color: Brand.purple.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.workspace_premium_rounded,
                                size: 13, color: Brand.purple),
                            const SizedBox(width: 3),
                            Text(lockedLabel ?? '',
                                style: AType.labelSmall.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: Brand.onTint(
                                        context, Brand.purple))),
                          ]),
                        ),
                      ],
                    ]),
                    const SizedBox(height: Gap.xxs),
                    Text(subtitle,
                        style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
            ),
            Icon(locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

/// Small round icon representing the business type.
class _TypeAvatar extends StatelessWidget {
  final String type;
  final bool onGradient;
  const _TypeAvatar({required this.type, this.onGradient = false});

  IconData get _icon {
    switch (type) {
      case 'online_seller':
        return Icons.shopping_bag_rounded;
      case 'small_shop':
        return Icons.storefront_rounded;
      case 'service':
        return Icons.handyman_rounded;
      case 'food':
        return Icons.restaurant_rounded;
      case 'wholesaler':
        return Icons.warehouse_rounded;
      case 'b2b':
        return Icons.business_center_rounded;
      default:
        return Icons.store_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 46,
      width: 46,
      decoration: BoxDecoration(
        color: onGradient
            ? Colors.white.withValues(alpha: 0.22)
            : scheme.secondaryContainer,
        shape: BoxShape.circle,
      ),
      child: Icon(_icon,
          color: onGradient ? Colors.white : scheme.onSecondaryContainer),
    );
  }
}
