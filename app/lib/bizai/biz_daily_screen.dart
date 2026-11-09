import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../screens/business/bizagent/seller_agent_screen.dart' show baErrorText, bd;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/business_ui.dart';
import '../widgets/chatnav.dart' show ChatNav;
import '../widgets/skeleton.dart';

/// bizai2 — "Today's shop summary" (server: GET/POST bizai/daily). Today's
/// sales next to last week, khata collected / given / owed, the customers to
/// chase tomorrow, items that will run out soon (from real sales speed),
/// what reminders and win-back messages really brought back, and one next
/// step. The same summary arrives as one notification at 9 pm; the switch
/// here turns that off. Every line comes from the server in the user's
/// language with Bangla digits — nothing is computed or guessed here.
class BizDailyScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? load;
  final Future<Map<String, dynamic>> Function(bool on)? setOn;
  final int? businessId;
  const BizDailyScreen({super.key, this.load, this.setOn, this.businessId});
  @override
  State<BizDailyScreen> createState() => _BizDailyScreenState();
}

class _BizDailyScreenState extends State<BizDailyScreen> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _busy = false;

  String get _q => widget.businessId == null ? '' : '?business=${widget.businessId}';

  @override
  void initState() {
    super.initState();
    _get();
  }

  Future<void> _get() async {
    setState(() => _error = null);
    try {
      final f = widget.load ?? () => context.read<AppState>().api.getJson('/bizai/daily$_q');
      final d = await f();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggle(bool on) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final f = widget.setOn ??
          (bool v) => context.read<AppState>().api.postJson('/bizai/daily$_q', {'on': v});
      final r = await f(on);
      if (mounted) setState(() => _d = {...?_d, 'enabled': r['enabled'] == true});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> _rows(Object? v) =>
      [for (final x in (v as List? ?? const [])) (x as Map).cast<String, dynamic>()];

  Widget _line(String s, {IconData? icon}) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: Gap.xs)],
          Expanded(child: Text(bd(context, s))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.bizai2DailyTitle)), body: _body(t));
  }

  Widget _body(AppLocalizations t) {
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _get, child: Text(t.bizRetry)),
      );
    }
    final d = _d;
    if (d == null) return const SkeletonList();
    final chase = _rows(d['chase']);
    final stock = _rows(d['stock']);
    final outcomes = [for (final x in (d['outcomes'] as List? ?? const [])) '$x'];
    return RefreshIndicator(
      onRefresh: _get,
      child: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        BizCard(
          title: '${d['title'] ?? t.bizai2DailyTitle}',
          icon: Icons.today_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final l in (d['lines'] as List? ?? const [])) _line('$l'),
            if (d['empty'] == true) ...[
              const SizedBox(height: Gap.sm),
              Text(t.bizai2DailyEmptyHow),
              const SizedBox(height: Gap.sm),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => ChatNav.push(context, 'khata'),
                icon: const Icon(Icons.menu_book_rounded),
                label: Text(t.bizai2OpenKhata),
              ),
            ],
          ]),
        ),
        if (chase.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          BizCard(
            title: t.bizai2ChaseTitle,
            icon: Icons.payments_rounded,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final c in chase) _line('${c['line'] ?? ''}', icon: Icons.person_rounded),
              const SizedBox(height: Gap.xs),
              Text(t.bizai2ChaseHint),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                key: const ValueKey('bizai2-chase-open'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => ChatNav.push(context, 'khata'),
                icon: const Icon(Icons.send_rounded),
                label: Text(t.bizai2OpenKhata),
              ),
            ]),
          ),
        ],
        if (stock.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          BizCard(
            title: t.bizai2StockTitle,
            icon: Icons.inventory_2_rounded,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final s in stock)
                _line('${s['line'] ?? ''}', icon: Icons.warning_amber_rounded),
              Text(t.bizai2StockHow, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ],
        if (outcomes.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          BizCard(
            title: t.bizai2OutcomesTitle,
            icon: Icons.verified_rounded,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final o in outcomes) _line(o, icon: Icons.check_rounded),
            ]),
          ),
        ],
        const SizedBox(height: Gap.md),
        BizNote(text: bd(context, '${d['next'] ?? ''}'), icon: Icons.flag_rounded),
        const SizedBox(height: Gap.md),
        SwitchListTile(
          key: const ValueKey('bizai2-daily-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(t.bizai2DailySwitch),
          subtitle: Text('${d['switch_note'] ?? ''}'),
          value: d['enabled'] == true,
          onChanged: _busy ? null : _toggle,
        ),
      ]),
    );
  }
}
