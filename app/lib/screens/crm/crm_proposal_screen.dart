import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/skeleton.dart';
import 'crm_common.dart';

/// Proposal screen (CRM_SPEC): build from requirement sheet + the configured
/// module price list (NEVER invent prices or tax — show "TO REVIEW BY OWNER"
/// when unreviewed), preview, send via WhatsApp/email AFTER approval, with full
/// status tracking (draft / pending / approved / sent / viewed / accepted).
///
/// The AI proposal body needs a key — without one the backend returns a clean
/// needs-key state, surfaced here honestly.
class CrmProposalScreen extends StatefulWidget {
  final int org;
  final Map<String, dynamic> lead;
  const CrmProposalScreen({super.key, required this.org, required this.lead});
  @override
  State<CrmProposalScreen> createState() => _CrmProposalScreenState();
}

class _CrmProposalScreenState extends State<CrmProposalScreen> {
  List<Map<String, dynamic>> _proposals = [];
  List<Map<String, dynamic>> _products = [];
  bool _loading = true, _error = false;

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
      final api = CrmApi.of(context);
      _proposals = await api.proposals(widget.org, lead: (widget.lead['id'] as num).toInt());
      _products = await api.products(widget.org);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _draftWithAi(AppLocalizations t) async {
    final req = TextEditingController(text: widget.lead['notes'] ?? '');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.crmRequirements),
        content: TextField(controller: req, maxLines: 4, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.crmDraftWithAi)),
        ],
      ),
    );
    if (go != true) return;
    try {
      final r = await CrmApi.of(context).leadProposal((widget.lead['id'] as num).toInt(), req.text.trim());
      if (!mounted) return;
      if (r['ok'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text((r['message'] ?? t.crmAiLocked).toString())));
      } else {
        _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _transition(AppLocalizations t, Map<String, dynamic> p, String to) async {
    try {
      await CrmApi.of(context).proposalTransition((p['id'] as num).toInt(), to);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.crmProposals)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _draftWithAi(t),
        icon: const Icon(Icons.auto_awesome_outlined),
        label: Text(t.crmDraftWithAi),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  action: FilledButton.tonalIcon(onPressed: _load, icon: const Icon(Icons.refresh), label: Text(t.retry)))
              : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                  // Price-book awareness note (never invent prices/tax).
                  if (_products.any((p) => p['price_reviewed'] != true))
                    NeedsKeyBanner(t.crmPricesToReview, icon: Icons.price_change_outlined),
                  if (_proposals.isEmpty)
                    StateMessage(icon: Icons.description_outlined, title: t.crmNoProposals, message: t.crmNoProposalsHint)
                  else
                    for (final p in _proposals) _proposalCard(t, p),
                ]),
    );
  }

  Widget _proposalCard(AppLocalizations t, Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final status = (p['status'] ?? 'draft').toString();
    final reviewed = p['prices_reviewed'] == true;
    final total = (p['total'] as num?) ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(p['title']?.toString().isNotEmpty == true ? p['title'] : '${t.crmProposals} v${p['version']}', style: const TextStyle(fontWeight: FontWeight.w800))),
            _statusChip(status),
          ]),
          const SizedBox(height: Gap.xs),
          if (total > 0) ...[
            _line(t.crmSubtotal, bdt(p['subtotal'] as num?)),
            if ((p['discount_amount'] as num? ?? 0) > 0) _line(t.crmDiscount, '- ${bdt(p['discount_amount'] as num?)}'),
            _line('${t.crmTax} (${p['tax_pct']}%)', bdt(p['tax_amount'] as num?)),
            const Divider(),
            _line(t.crmTotal, bdt(total), bold: true),
          ],
          if (!reviewed)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Row(children: [
                const Icon(Icons.flag_outlined, size: 16, color: Brand.warning),
                const SizedBox(width: 4),
                Text(t.crmToReview, style: const TextStyle(color: Brand.warning, fontWeight: FontWeight.w700, fontSize: 12)),
              ]),
            ),
          if ((p['body'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(p['body'], maxLines: 6, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.xs, children: [
            if (status == 'draft' || status == 'pending')
              OutlinedButton(onPressed: reviewed ? () => _transition(t, p, 'approved') : null, child: Text(t.crmApprove)),
            if (status == 'approved')
              FilledButton.tonal(onPressed: () => _transition(t, p, 'sent'), child: Text(t.send)),
            if (status == 'sent')
              OutlinedButton(onPressed: () => _transition(t, p, 'viewed'), child: Text(t.crmMarkViewed)),
            if (status == 'sent' || status == 'viewed')
              OutlinedButton(onPressed: () => _transition(t, p, 'accepted'), child: Text(t.crmMarkAccepted)),
          ]),
        ]),
      ),
    );
  }

  Widget _line(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
        ]),
      );

  Widget _statusChip(String status) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(999)),
      child: Text(status, style: TextStyle(fontSize: 11, color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700)),
    );
  }
}
