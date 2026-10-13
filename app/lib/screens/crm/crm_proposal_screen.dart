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

  Future<void> _openQuoteBuilder(AppLocalizations t) async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => QuoteBuilderScreen(
            org: widget.org, lead: widget.lead, products: _products),
      ),
    );
    if (created == true) _load();
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
                  // G6: in-app quote builder — select products → line items → totals.
                  OutlinedButton.icon(
                    onPressed: () => _openQuoteBuilder(t),
                    icon: const Icon(Icons.calculate_outlined),
                    label: Text(t.crmBuildQuote),
                  ),
                  const SizedBox(height: Gap.sm),
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

/// G6 — In-app QUOTE BUILDER (CRM_SPEC §5). Pick price-book Products + qty,
/// build line items, preview subtotal/discount/tax/total, then create a
/// Proposal via the backend (quoting.make_quote). NEVER invents a price or a
/// tax rate: amounts come only from the owner-configured price book, and if any
/// selected product is not owner-reviewed the quote is stamped
/// "TO REVIEW BY OWNER" (the server also flags prices_reviewed=False so it
/// cannot be approved/sent until reviewed).
class QuoteBuilderScreen extends StatefulWidget {
  final int org;
  final Map<String, dynamic> lead;
  final List<Map<String, dynamic>> products;
  const QuoteBuilderScreen(
      {super.key, required this.org, required this.lead, required this.products});
  @override
  State<QuoteBuilderScreen> createState() => _QuoteBuilderScreenState();
}

class _QuoteBuilderScreenState extends State<QuoteBuilderScreen> {
  // sku -> qty (0 = not selected)
  final Map<String, int> _qty = {};
  final _discountCtl = TextEditingController(text: '0');
  final _taxCtl = TextEditingController(text: '0');
  bool _saving = false;

  @override
  void dispose() {
    _discountCtl.dispose();
    _taxCtl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _active =>
      widget.products.where((p) => p['active'] != false).toList();

  double _unit(Map<String, dynamic> p) => ((p['unit_price'] as num?) ?? 0).toDouble();

  double get _subtotal {
    double s = 0;
    for (final p in _active) {
      final q = _qty[p['sku']?.toString()] ?? 0;
      if (q > 0) s += _unit(p) * q;
    }
    return s;
  }

  double _pct(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    if (v == null || v < 0) return 0;
    return v;
  }

  /// True if every SELECTED product is owner-reviewed. An empty selection is
  /// treated as reviewed (there is nothing unreviewed yet).
  bool get _allReviewed {
    for (final p in _active) {
      final q = _qty[p['sku']?.toString()] ?? 0;
      if (q > 0 && p['price_reviewed'] != true) return false;
    }
    return true;
  }

  bool get _hasSelection => _qty.values.any((q) => q > 0);

  Future<void> _create(AppLocalizations t) async {
    final selections = <Map<String, dynamic>>[];
    for (final p in _active) {
      final sku = p['sku']?.toString() ?? '';
      final q = _qty[sku] ?? 0;
      if (q > 0) selections.add({'sku': sku, 'qty': q});
    }
    if (selections.isEmpty) return;
    setState(() => _saving = true);
    try {
      await CrmApi.of(context).leadQuote(
        (widget.lead['id'] as num).toInt(),
        selections,
        discountPct: _pct(_discountCtl),
        taxPct: _pct(_taxCtl),
        requirements: (widget.lead['notes'] ?? '').toString(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final subtotal = _subtotal;
    final discountPct = _pct(_discountCtl);
    final taxPct = _pct(_taxCtl);
    final discountAmount = subtotal * discountPct / 100;
    final taxable = subtotal - discountAmount;
    final taxAmount = taxable * taxPct / 100;
    final total = taxable + taxAmount;

    return Scaffold(
      appBar: AppBar(title: Text(t.crmBuildQuote)),
      body: _active.isEmpty
          ? StateMessage(icon: Icons.inventory_2_outlined, title: t.crmNoProducts, message: t.crmNoProductsHint)
          : ListView(padding: const EdgeInsets.all(Gap.md), children: [
              if (!_allReviewed)
                NeedsKeyBanner(t.crmPricesToReview, icon: Icons.price_change_outlined),
              _sectionTitle(t.crmSelectProducts),
              for (final p in _active) _productRow(t, p),
              const SizedBox(height: Gap.md),
              _sectionTitle(t.crmQuoteTotals),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _discountCtl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: '${t.crmDiscount} %', border: const OutlineInputBorder()),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: TextField(
                          controller: _taxCtl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: '${t.crmTax} %', border: const OutlineInputBorder()),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ]),
                    const SizedBox(height: Gap.sm),
                    _line(t.crmSubtotal, bdt(subtotal)),
                    if (discountAmount > 0) _line(t.crmDiscount, '- ${bdt(discountAmount)}'),
                    _line('${t.crmTax} (${taxPct.toStringAsFixed(taxPct == taxPct.roundToDouble() ? 0 : 2)}%)', bdt(taxAmount)),
                    const Divider(),
                    _line(t.crmTotal, bdt(total), bold: true),
                    if (!_allReviewed)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.xs),
                        child: Row(children: [
                          const Icon(Icons.flag_outlined, size: 16, color: Brand.warning),
                          const SizedBox(width: 4),
                          Expanded(child: Text(t.crmToReview, style: const TextStyle(color: Brand.warning, fontWeight: FontWeight.w700, fontSize: 12))),
                        ]),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: Gap.md),
              FilledButton.icon(
                onPressed: (!_hasSelection || _saving) ? null : () => _create(t),
                icon: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(t.crmCreateProposal),
              ),
              const SizedBox(height: Gap.xs),
              Text(t.crmQuotePriceBookNote, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ]),
    );
  }

  Widget _productRow(AppLocalizations t, Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final sku = p['sku']?.toString() ?? '';
    final q = _qty[sku] ?? 0;
    final reviewed = p['price_reviewed'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p['name']?.toString() ?? sku, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${bdt((p['unit_price'] as num?))} · $sku',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              if (!reviewed)
                Text(t.crmToReview, style: const TextStyle(color: Brand.warning, fontWeight: FontWeight.w700, fontSize: 11)),
            ]),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: q > 0 ? () => setState(() => _qty[sku] = q - 1) : null,
          ),
          Text('$q', style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => setState(() => _qty[sku] = q + 1),
          ),
        ]),
      ),
    );
  }

  Widget _line(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(k)),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
        ]),
      );

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs, top: Gap.sm),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
      );
}
