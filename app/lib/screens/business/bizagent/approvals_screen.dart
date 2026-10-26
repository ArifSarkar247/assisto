import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../bizagent_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/business_ui.dart';
import '../../../widgets/skeleton.dart';
import 'seller_agent_screen.dart' show baChannelLabel, baErrorText, bd;

/// P1 — the seller's approval queue: risky AI replies (a number not in the
/// catalog, discount below the minimum, complaint, refund, unknown product,
/// low confidence, big order, or "approve every reply" mode). The customer
/// already got an honest "someone will reply" line; here the seller sends the
/// draft as is, edits it, or rejects it.
class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({super.key});
  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

String baRiskLabel(AppLocalizations t, String r) {
  switch (r) {
    case 'unverified_number':
      return t.baRiskNumbers;
    case 'below_min':
      return t.baRiskBelowMin;
    case 'complaint':
      return t.baRiskComplaint;
    case 'refund':
      return t.baRiskRefund;
    case 'unknown_product':
      return t.baRiskUnknown;
    case 'big_order':
      return t.baRiskBigOrder;
    case 'seller_approves_all':
      return t.baRiskApproveAll;
    default:
      return t.baRiskLowConf;
  }
}

class _ApprovalsScreenState extends State<ApprovalsScreen> {
  bool _loading = true;
  Object? _error;
  List<Map<String, dynamic>> _items = const [];

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
      final r = await context.read<AppState>().api.bizAgentApprovals();
      if (!mounted) return;
      setState(() {
        _items = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.baApprovalsTitle)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    if (_items.isEmpty) {
      return StateMessage(
        icon: Icons.task_alt_rounded,
        title: t.baApprovalsEmptyTitle,
        message: t.baApprovalsEmptyBody,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) => _ApprovalCard(
          key: ValueKey(_items[i]['id']),
          item: _items[i],
          onDone: _load,
        ),
      ),
    );
  }
}

class _ApprovalCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final Future<void> Function() onDone;
  const _ApprovalCard({super.key, required this.item, required this.onDone});
  @override
  State<_ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<_ApprovalCard> {
  // bn: the draft is shown (and, when edited, sent) with Bangla digits
  late final TextEditingController _c =
      TextEditingController(text: bd(context, widget.item['text'] ?? ''));
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool get _edited => _c.text.trim() != bd(context, widget.item['text'] ?? '').trim();

  Future<void> _run(Future<Map<String, dynamic>> Function() f, String ok) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await f();
      if (!mounted) return;
      final sent = r['ok'] == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(bd(context, sent ? ok : t.baSendFailed('${r['status'] ?? ''}')))));
      await widget.onDone();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(bd(context, baErrorText(t, e)))));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final it = widget.item;
    final id = (it['id'] as num).toInt();
    final problems = ((it['problems'] as List?) ?? const []).cast<Map>();
    final api = context.read<AppState>().api;
    return BizCard(
      title: bd(context, '${it['customer_name'] ?? ''}'.isEmpty
          ? baChannelLabel(t, '${it['channel']}')
          : '${it['customer_name']} · ${baChannelLabel(t, '${it['channel']}')}'),
      icon: Icons.fact_check_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        BizStatusChip(label: baRiskLabel(t, '${it['risk_reason']}'), color: AssistoTokens.of(context).warning),
        const SizedBox(height: Gap.md),
        if ('${it['customer_text'] ?? ''}'.isNotEmpty) ...[
          Text(t.baCustomerSaid, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: Gap.xs),
          Text(bd(context, it['customer_text']), style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.md),
        ],
        if (problems.isNotEmpty) ...[
          BizNote(
            text: bd(context, t.baNumbersNotInCatalog(problems.map((p) => '${p['value']}').join(', '))),
            icon: Icons.error_outline_rounded,
            tint: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: Gap.md),
        ],
        TextField(
          controller: _c,
          minLines: 2,
          maxLines: 6,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
              labelText: t.baProposedReply, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, alignment: WrapAlignment.end, children: [
          TextButton(
            onPressed: _busy ? null : () => _run(() => api.bizAgentReject(id), t.baRejected),
            // a11y1: primary on the card tint was 4.48:1.
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurface),
            child: Text(t.baReject),
          ),
          FilledButton.icon(
            onPressed: _busy || _c.text.trim().isEmpty
                ? null
                : () => _run(
                    () => api.bizAgentApprove(id, text: _edited ? _c.text.trim() : null),
                    t.baSent),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: Text(_edited ? t.baSendEdited : t.baApprove),
          ),
        ]),
      ]),
    );
  }
}
