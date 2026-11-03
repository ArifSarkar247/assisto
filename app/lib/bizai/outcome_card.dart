import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../screens/business/bizagent/seller_agent_screen.dart'
    show SellerAgentScreen, baErrorText, bd;
import '../services/error_report.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/business_ui.dart';
import '../widgets/subs_common.dart' show fmtInt;
import 'bizai_source.dart';

/// Taka text from the server's decimal string ("1200.00") — whole taka with
/// grouping, Bangla digits in bn. Never rounds money UP.
String bizaiTaka(BuildContext context, Object? v) {
  final d = double.tryParse('${v ?? 0}') ?? 0;
  return '৳${fmtInt(context, d.truncate())}';
}

/// bizai — the Business-home OUTCOME CARD (owner order): what Assisto did for
/// the shop this week, in taka, from real rows only (orders the AI took,
/// customers brought back, dues collected after a reminder, risky COD orders
/// held). Each line says how it is counted. No data yet = the benefit line +
/// one big button to the AI sales agent (never a made-up number).
class OutcomeCard extends StatefulWidget {
  final int? businessId;
  final BizaiSource? source;
  final bool isStaff;
  const OutcomeCard({super.key, this.businessId, this.source, this.isStaff = false});
  @override
  State<OutcomeCard> createState() => _OutcomeCardState();
}

class _OutcomeCardState extends State<OutcomeCard> {
  late final BizaiSource _src = widget.source ?? ApiBizaiSource(context.read<AppState>().api);
  Map<String, dynamic>? _d;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _src.outcomes(widget.businessId);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      reportNonFatal('bizai.outcomes', e);
      if (mounted) setState(() => _failed = true);
    }
  }

  String _label(AppLocalizations t, String key) => switch (key) {
        'ai_orders' => t.bizaiOutAiOrders,
        'customers_back' => t.bizaiOutCustomersBack,
        'dues_collected' => t.bizaiOutDuesCollected,
        'losses_prevented' => t.bizaiOutLossesPrevented,
        _ => key,
      };

  IconData _icon(String key) => switch (key) {
        'ai_orders' => Icons.smart_toy_rounded,
        'customers_back' => Icons.replay_rounded,
        'dues_collected' => Icons.payments_rounded,
        _ => Icons.shield_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (_failed || d == null) return const SizedBox.shrink(); // hidden while loading / on failure
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final rows = bzList(d['rows']);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: BizCard(
        key: const ValueKey('bizai-outcome-card'),
        title: t.bizaiOutcomeTitle,
        icon: Icons.insights_rounded,
        child: d['empty'] == true
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(t.bizaiOutEmpty),
                const SizedBox(height: Gap.md),
                if (!widget.isStaff)
                  FilledButton.icon(
                    key: const ValueKey('bizai-outcome-start'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const SellerAgentScreen())),
                    icon: const Icon(Icons.smart_toy_rounded),
                    label: Text(t.bizaiOutEmptyBtn),
                  ),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.bizaiOutTotal(bizaiTaka(context, d['total_bdt'])),
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: Gap.sm),
                if (d['best_post'] is Map)
                  BizNote(
                    icon: Icons.campaign_rounded,
                    text: t.bizaiOutBestPost(
                        bd(context, (d['best_post'] as Map)['title']),
                        fmtInt(context, ((d['best_post'] as Map)['orders'] as num?)?.toInt() ?? 0),
                        bizaiTaka(context, (d['best_post'] as Map)['bdt'])),
                  ),
                for (final r in rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    minVerticalPadding: Gap.sm,
                    leading: Icon(_icon('${r['key']}')),
                    title: Text(_label(t, '${r['key']}')),
                    subtitle: Text(bd(context, bn ? r['how_bn'] : r['how_en'])),
                    trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(bizaiTaka(context, r['bdt']),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(t.bizaiOutCount(fmtInt(context, (r['count'] as num?)?.toInt() ?? 0))),
                        ]),
                  ),
              ]),
      ),
    );
  }
}

/// bizai — the seller's shop-chat link + the two switches (in-app chats on,
/// hold risky COD orders). Owner-only switches; staff see the link.
class ShopLinkCard extends StatefulWidget {
  final int? businessId;
  final BizaiSource? source;
  const ShopLinkCard({super.key, this.businessId, this.source});
  @override
  State<ShopLinkCard> createState() => _ShopLinkCardState();
}

class _ShopLinkCardState extends State<ShopLinkCard> {
  late final BizaiSource _src = widget.source ?? ApiBizaiSource(context.read<AppState>().api);
  Map<String, dynamic>? _d;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _src.shopLink(widget.businessId);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _set(String k, bool v) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final d = await _src.saveShopLink(widget.businessId, {k: v});
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final d = _d;
    if (_error != null) {
      return BizCard(
          title: t.bizaiShopLinkTitle,
          icon: Icons.storefront_rounded,
          child: BizNote(text: baErrorText(t, _error!)));
    }
    if (d == null) return const SizedBox.shrink();
    final on = d['app_chat_enabled'] == true;
    return BizCard(
      key: const ValueKey('bizai-shop-link'),
      title: t.bizaiShopLinkTitle,
      icon: Icons.storefront_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.bizaiShopLinkSub),
        const SizedBox(height: Gap.sm),
        SelectableText('${d['url'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
          key: const ValueKey('bizai-share'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: on
              ? () => Share.share(t.bizaiShareText('${d['shop'] ?? ''}', '${d['url'] ?? ''}'))
              : null,
          icon: const Icon(Icons.share_rounded),
          label: Text(t.bizaiShare),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: on,
          title: Text(t.bizaiAppChatSwitch),
          onChanged: _busy ? null : (v) => _set('app_chat_enabled', v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: d['cod_risk_guard'] == true,
          title: Text(t.bizaiCodGuardSwitch),
          subtitle: Text(t.bizaiCodGuardSub),
          onChanged: _busy ? null : (v) => _set('cod_risk_guard', v),
        ),
        if (d['ai_on'] != true) BizNote(text: t.bizaiAiOffNote, icon: Icons.info_outline_rounded),
      ]),
    );
  }
}
