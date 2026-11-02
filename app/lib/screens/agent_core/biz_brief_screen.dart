import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/chatnav.dart';
import '../../widgets/offline_banner.dart';
import 'agent_core_source.dart';
import 'agent_core_widgets.dart';
import 'agent_run_panel.dart';
import 'biz_brief_source.dart';

/// bizops: the shop owner's MORNING BUSINESS CARD (Agent Core "business"
/// topic; flags agent_core + business). Every line is built on the server
/// from the shop's own rows — yesterday's sales/profit vs last week, who to
/// remind today, what is running out, CRM follow-ups, cash vs books — no AI
/// call, 0 credits (the cost math is on the card).
///
/// One-tap actions start a code-planned agent run: a reminder / supplier
/// reorder stops at the approval card (nothing leaves the phone before the
/// owner's Approve); after approval WhatsApp opens with the ready message.
/// Question chips ("আজ কত লাভ?") answer from one tool, free, with or without
/// an AI key.
class BizBriefScreen extends StatefulWidget {
  final BizBriefSource? source;
  final AgentCoreSource? agentSource;
  const BizBriefScreen({super.key, this.source, this.agentSource});

  @override
  State<BizBriefScreen> createState() => _BizBriefScreenState();
}

enum _St { loading, data, failed, offline, off }

class _BizBriefScreenState extends State<BizBriefScreen> {
  late final ApiClient? _api = _maybeApi();
  late final BizBriefSource _src = widget.source ?? ApiBizBriefSource(_api!);
  late final AgentCoreSource _ac = widget.agentSource ?? ApiAgentCoreSource(_api!);
  _St _st = _St.loading;
  BoCard? _card;
  String? _busy; // the action / question being started
  String? _actError;

  ApiClient? _maybeApi() {
    try {
      return Provider.of<AppState>(context, listen: false).api;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_st != _St.loading) setState(() => _st = _St.loading);
    try {
      final j = await _src.brief();
      if (!mounted) return;
      setState(() {
        _card = BoCard.fromJson(j);
        _st = _St.data;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _st = e.status == 403 ? _St.off : _St.failed);
    } on SocketException {
      if (mounted) setState(() => _st = _St.offline);
    } catch (_) {
      if (mounted) setState(() => _st = _St.failed);
    }
  }

  String _cid() => 'bo-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

  Future<void> _start(String busyKey, Map<String, dynamic> body) async {
    if (_busy != null) return;
    setState(() {
      _busy = busyKey;
      _actError = null;
    });
    try {
      final j = await _src.act({...body, 'client_id': _cid()});
      if (!mounted) return;
      final run = AcRun.fromJson(j);
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BizRunScreen(source: _ac, run: run)));
      if (mounted) unawaited(_load()); // numbers may have changed (task, reminder)
    } on SocketException {
      if (mounted) setState(() => _actError = AppLocalizations.of(context).boOffline);
    } catch (_) {
      if (mounted) setState(() => _actError = AppLocalizations.of(context).boActFailed);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _onAction(BoAction a) async {
    switch (a.kind) {
      case 'tagada':
        return _start('a:${a.kind}:${a.target}', {'kind': 'tagada', ...a.args});
      case 'followup':
        return _start('a:${a.kind}:${a.target}', {'kind': 'followup', ...a.args});
      case 'reorder':
        final sup = await _pickSupplier();
        if (sup == null || !mounted) return;
        return _start('a:reorder', {'kind': 'reorder', 'supplier': sup, ...a.args});
    }
  }

  Future<String?> _pickSupplier() {
    final t = AppLocalizations.of(context);
    final list = _card?.suppliers ?? const <String>[];
    return showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final s = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ListView(
            key: const ValueKey('bo_supplier_sheet'),
            shrinkWrap: true,
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              Semantics(
                  header: true,
                  child: Text(t.boPickSupplier, style: Theme.of(ctx).textTheme.titleMedium)),
              const SizedBox(height: Gap.sm),
              if (list.isEmpty) ...[
                Text(t.boNoSupplier, style: TextStyle(color: s.onSurfaceVariant, height: 1.4)),
                const SizedBox(height: Gap.md),
                FilledButton.icon(
                  key: const ValueKey('bo_open_khata'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    ChatNav.push(context, 'khata');
                  },
                  icon: const Icon(Icons.menu_book_rounded),
                  label: Text(t.boOpenKhata),
                ),
              ] else
                for (final n in list)
                  ListTile(
                    key: ValueKey('bo_supplier_$n'),
                    minTileHeight: 56,
                    leading: const Icon(Icons.local_shipping_outlined),
                    title: Text(n),
                    onTap: () => Navigator.of(ctx).pop(n),
                  ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.boTitle),
        actions: [
          if (_st == _St.data)
            IconButton(
                key: const ValueKey('bo_refresh'),
                tooltip: t.boRefresh,
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final t = AppLocalizations.of(context);
    switch (_st) {
      case _St.loading:
        return Center(
            child: Semantics(
                label: t.boLoading, child: const CircularProgressIndicator()));
      case _St.off:
        return Center(
            child: AcMessage(
                key: const ValueKey('bo_off'),
                icon: Icons.lock_outline_rounded,
                body: t.acFeatureOff));
      case _St.offline:
      case _St.failed:
        return Center(
            child: AcMessage(
                key: const ValueKey('bo_failed'),
                icon: _st == _St.offline ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
                body: _st == _St.offline ? t.boOffline : t.boLoadFailed,
                action: t.boRetry,
                onAction: _load));
      case _St.data:
        break;
    }
    final c = _card!;
    if (!c.hasBusiness) {
      return Center(
          child: AcMessage(
              key: const ValueKey('bo_no_business'),
              icon: Icons.storefront_outlined,
              title: t.boNoBusiness,
              body: t.boNoBusinessBody,
              action: t.boSetupShop,
              onAction: () => ChatNav.push(context, 'business')));
    }
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('bo_list'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          const OfflineBanner(),
          Text(t.boIntro, style: TextStyle(color: s.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.md),
          if (c.empty)
            Card(
              key: const ValueKey('bo_empty'),
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.boEmptyTitle, style: tt.titleMedium),
                  const SizedBox(height: Gap.sm),
                  Text(t.boEmptyBody, style: TextStyle(color: s.onSurfaceVariant, height: 1.4)),
                  const SizedBox(height: Gap.md),
                  FilledButton.icon(
                    key: const ValueKey('bo_open_shop'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => ChatNav.push(context, 'business'),
                    icon: const Icon(Icons.point_of_sale_rounded),
                    label: Text(t.boOpenShop),
                  ),
                ]),
              ),
            ),
          if (c.lines.isNotEmpty)
            Card(
              key: const ValueKey('bo_lines'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Column(children: [for (final l in c.lines) _line(context, l)]),
              ),
            ),
          if (c.actions.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            Semantics(header: true, child: Text(t.boActions, style: tt.titleSmall)),
            const SizedBox(height: Gap.xs),
            Text(t.boNeedsOk, style: TextStyle(color: s.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: Gap.sm),
            for (final a in c.actions) _actionButton(context, a),
          ],
          if (_actError != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(_actError!,
                  key: const ValueKey('bo_act_error'), style: TextStyle(color: s.error)),
            ),
          if (c.questions.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            Semantics(header: true, child: Text(t.boAsk, style: tt.titleSmall)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final q in c.questions)
                ActionChip(
                  key: ValueKey('bo_q_${q.key}'),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  avatar: _busy == 'q:${q.key}'
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.help_outline_rounded, size: 18),
                  label: Text(q.text),
                  onPressed: _busy != null
                      ? null
                      : () => _start('q:${q.key}', {'kind': 'question', 'key': q.key}),
                ),
            ]),
            if (!c.aiReady) ...[
              const SizedBox(height: Gap.xs),
              Text(t.boNoAiNote, style: TextStyle(color: s.onSurfaceVariant, fontSize: 13)),
            ],
          ],
          if (c.costLines.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            Card(
              key: const ValueKey('bo_cost'),
              color: s.surfaceContainerHighest,
              child: ExpansionTile(
                leading: Icon(Icons.calculate_outlined, color: s.onSurface),
                title: Text(t.boCost, style: TextStyle(color: s.onSurface)),
                childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in c.costLines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.xs),
                      child: Text('• $l', style: TextStyle(color: s.onSurface, height: 1.4)),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static const _icons = <String, IconData>{
    'sales': Icons.trending_up_rounded,
    'dues': Icons.account_balance_wallet_outlined,
    'stock': Icons.inventory_2_outlined,
    'followups': Icons.event_available_outlined,
    'cash': Icons.point_of_sale_rounded,
    'orders': Icons.receipt_long_outlined,
  };

  Widget _line(BuildContext context, BoLine l) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('bo_line_${l.key}'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(_icons[l.key] ?? Icons.circle_outlined, color: s.primary),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(l.text, style: const TextStyle(height: 1.45))),
      ]),
    );
  }

  Widget _actionButton(BuildContext context, BoAction a) {
    final busy = _busy == 'a:${a.kind}:${a.target}' || (a.kind == 'reorder' && _busy == 'a:reorder');
    final icon = switch (a.kind) {
      'tagada' => Icons.notifications_active_outlined,
      'reorder' => Icons.local_shipping_outlined,
      _ => Icons.task_alt_rounded,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: FilledButton.tonalIcon(
        key: ValueKey('bo_act_${a.kind}_${a.target}'),
        style: FilledButton.styleFrom(
            minimumSize: const Size(48, 52),
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm)),
        onPressed: _busy != null ? null : () => _onAction(a),
        icon: busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon),
        label: Row(children: [
          Expanded(child: Text(a.label)),
          if (a.approval) ...[
            const SizedBox(width: Gap.sm),
            Semantics(
                label: AppLocalizations.of(context).boNeedsOkShort,
                child: const Icon(Icons.front_hand_outlined, size: 18)),
          ],
        ]),
      ),
    );
  }
}

/// One card tap's run: the shared AcRunPanel (approval card, answer, the
/// prepared WhatsApp message after approval).
class BizRunScreen extends StatelessWidget {
  final AgentCoreSource source;
  final AcRun run;
  final List<Duration> pollSchedule;
  const BizRunScreen(
      {super.key,
      required this.source,
      required this.run,
      this.pollSchedule = AcRunPanel.defaultSchedule});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.boTitle)),
      body: SafeArea(
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            AcRunPanel(
                key: ValueKey('bo_run_${run.id}'),
                source: source,
                run: run,
                pollSchedule: pollSchedule),
          ],
        ),
      ),
    );
  }
}
