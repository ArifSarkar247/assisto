import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_aftersale_api.dart';
import '../../widgets/crm_aftersale_widgets.dart';
import 'crm_common.dart';

/// q1-seams: true only once a customer-facing acceptance PAGE exists (an
/// absolute https link that renders accept / decline), not a JSON API path.
const bool kQuoteAcceptPageWired = false;

/// ADVANCED proposal/quote surface (CRM_SPEC §6): version history (v1/v2…),
/// discount-approval workflow, validity/expiry, branded-PDF data model (honest
/// preview when no PDF lib), tokenized customer acceptance link (mock) and
/// convert-accepted-quote → order.
///
/// NEVER invents a price or a tax rate — every amount is shown exactly as the
/// backend computed it from the price list / owner input, in integer poisha.
class CrmProposalAdvancedScreen extends StatefulWidget {
  final int org;
  final Map<String, dynamic> lead;
  const CrmProposalAdvancedScreen(
      {super.key, required this.org, required this.lead});
  @override
  State<CrmProposalAdvancedScreen> createState() =>
      _CrmProposalAdvancedScreenState();
}

class _CrmProposalAdvancedScreenState extends State<CrmProposalAdvancedScreen> {
  List<Map<String, dynamic>> _versions = [];
  bool _loading = true;
  CrmError? _error;

  int get _leadId => (widget.lead['id'] as num).toInt();

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
      _versions = await CrmAfterSaleApi.of(context).quoteVersions(_leadId);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() op) async {
    try {
      await op();
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  Future<void> _setValidity(AppLocalizations t, Map<String, dynamic> p) async {
    final ctl = TextEditingController(
        text: (p['valid_days'] ?? 30).toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.crmQuoteValidity),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: t.crmQuoteValidDays, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
        ],
      ),
    );
    if (ok != true) return;
    final days = int.tryParse(ctl.text.trim()) ?? 30;
    _run(() => CrmAfterSaleApi.of(context)
        .setValidity((p['id'] as num).toInt(), days));
  }

  Future<void> _showAcceptanceLink(
      AppLocalizations t, Map<String, dynamic> p) async {
    try {
      final r =
          await CrmAfterSaleApi.of(context).acceptanceLink((p['id'] as num).toInt());
      if (!mounted) return;
      final link = (r['url'] ?? r['link'] ?? '').toString();
      final state = (r['link_state'] ?? 'issued').toString();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.crmAcceptanceLink),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.crmAcceptanceLinkHint),
            const SizedBox(height: Gap.sm),
            SelectableText(link.isEmpty ? '—' : link,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            CrmStatusPill(_acceptLabel(t, state),
                tone: state == 'accepted'
                    ? CrmStatusTone.success
                    : state == 'declined'
                        ? CrmStatusTone.danger
                        : CrmStatusTone.info),
          ]),
          actions: [
            TextButton(
                onPressed: link.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: link));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(t.copied)));
                      },
                child: Text(t.copy)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: Text(t.close)),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  String _acceptLabel(AppLocalizations t, String s) {
    switch (s) {
      case 'viewed':
        return t.crmAcceptViewed;
      case 'accepted':
        return t.crmAcceptAccepted;
      case 'declined':
        return t.crmAcceptDeclined;
      case 'expired':
        return t.crmQuoteExpired;
      default:
        return t.crmAcceptIssued;
    }
  }

  Future<void> _showPdfPreview(
      AppLocalizations t, Map<String, dynamic> p) async {
    try {
      final m = await CrmAfterSaleApi.of(context).pdfModel((p['id'] as num).toInt());
      if (!mounted) return;
      final rendered = m['rendered'] == true;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, sc) => ListView(
            controller: sc,
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              Row(children: [
                Expanded(
                    child: Text(t.crmBrandedPdf,
                        style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800))),
                CrmStatusPill(rendered ? t.crmPdfReady : t.crmPdfPreviewOnly,
                    tone: rendered
                        ? CrmStatusTone.success
                        : CrmStatusTone.warning),
              ]),
              if (!rendered) ...[
                const SizedBox(height: Gap.sm),
                NeedsKeyBanner(t.crmPdfNoLibNote,
                    icon: Icons.picture_as_pdf_outlined),
              ],
              const SizedBox(height: Gap.sm),
              Text((m['brand']?['name'] ?? '').toString(),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              Text((m['title'] ?? '').toString(),
                  style: Theme.of(context).textTheme.bodyMedium),
              const Divider(),
              for (final li in (m['lines'] as List? ?? []))
                CrmMoneyRow(
                    '${li['label']} × ${li['qty']}', '৳${li['amount_taka']}'),
              const Divider(),
              CrmMoneyRow(t.crmSubtotal, '৳${m['subtotal_taka']}'),
              CrmMoneyRow('${t.crmDiscount} (${m['discount_pct']}%)',
                  '- ৳${m['discount_taka']}'),
              CrmMoneyRow('${t.crmTax} (${m['tax_pct']}%)', '৳${m['tax_taka']}'),
              CrmMoneyRow(t.crmTotal, '৳${m['total_taka']}', bold: true),
              if (m['tax_review_required'] == true) ...[
                const SizedBox(height: Gap.sm),
                NeedsKeyBanner(t.crmTaxToReview,
                    icon: Icons.flag_outlined),
              ],
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.crmQuoteVersions)),
      body: _loading
          ? const CrmStateView.loading()
          : _error != null
              ? CrmStateView.error(
                  error: _error!, title: t.loadFailed, onRetry: _load)
              : _versions.isEmpty
                  ? CrmStateView.empty(
                      icon: Icons.history_outlined,
                      title: t.crmNoVersions,
                      message: t.crmNoVersionsHint)
                  : ListView(
                      padding: const EdgeInsets.all(Gap.md),
                      children: [
                        for (final p in _versions) _versionCard(t, p),
                      ]),
    );
  }

  Widget _versionCard(AppLocalizations t, Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final status = (p['status'] ?? 'draft').toString();
    final reviewed = p['prices_reviewed'] == true;
    final discountNeedsApproval = p['discount_needs_approval'] == true;
    final discountApproved = p['discount_approved'] == true;
    final expired = p['is_expired'] == true;
    final daysLeft = p['days_left'];
    final total = (p['total_poisha'] as num?) ??
        (((p['total'] as num?) ?? 0) * 100);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('v${p['version']} · ${p['title'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            CrmStatusPill(status, tone: _statusTone(status)),
          ]),
          const SizedBox(height: Gap.xs),
          CrmMoneyRow(t.crmTotal, bdtFromPoisha(total), bold: true),

          // ---- validity / expiry ----
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Row(children: [
              Icon(Icons.event_outlined,
                  size: 16, color: expired ? Theme.of(context).colorScheme.error : scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  expired
                      ? t.crmQuoteExpired
                      : daysLeft == null
                          ? t.crmQuoteNoExpiry
                          : t.crmQuoteDaysLeft(daysLeft.toString()),
                  style: AType.labelMedium.copyWith(color: expired ? Theme.of(context).colorScheme.error : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ]),
          ),

          // ---- discount-approval workflow ----
          if (discountNeedsApproval)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Row(children: [
                Icon(Icons.verified_user_outlined,
                    size: 16,
                    color: discountApproved ? AssistoTokens.of(context).success : AssistoTokens.of(context).warning),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    discountApproved
                        ? t.crmDiscountApproved
                        : t.crmDiscountNeedsApproval,
                    style: AType.labelMedium.copyWith(fontWeight: FontWeight.w700,
                        color:
                            discountApproved ? AssistoTokens.of(context).success : AssistoTokens.of(context).warning),
                  ),
                ),
              ]),
            ),

          if (!reviewed)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.crmToReview,
                  style: AType.labelMedium.copyWith(color: AssistoTokens.of(context).warning,
                      fontWeight: FontWeight.w700)),
            ),

          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            OutlinedButton.icon(
                onPressed: () => _setValidity(t, p),
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(t.crmQuoteValidity)),
            OutlinedButton.icon(
                onPressed: () => _showPdfPreview(t, p),
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: Text(t.crmBrandedPdf)),
            if (discountNeedsApproval && !discountApproved)
              FilledButton.tonalIcon(
                  onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                      .approveDiscount((p['id'] as num).toInt())),
                  icon: const Icon(Icons.gavel_outlined, size: 18),
                  label: Text(t.crmApproveDiscount)),
            // q1-seams: hidden — the server hands back a RELATIVE JSON API
            // path (/api/crm/accept/<token>/), not a page a customer can open,
            // so sharing it could never get a real acceptance.
            if (kQuoteAcceptPageWired &&
                (status == 'sent' || status == 'viewed' || status == 'approved'))
              OutlinedButton.icon(
                  onPressed: () => _showAcceptanceLink(t, p),
                  icon: const Icon(Icons.link_outlined, size: 18),
                  label: Text(t.crmAcceptanceLink)),
            if (status == 'accepted' && !expired)
              FilledButton.icon(
                  onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                      .convertToOrder((p['id'] as num).toInt())),
                  icon: const Icon(Icons.shopping_cart_checkout_outlined, size: 18),
                  label: Text(t.crmConvertToOrder)),
          ]),
        ]),
      ),
    );
  }

  CrmStatusTone _statusTone(String s) {
    switch (s) {
      case 'accepted':
        return CrmStatusTone.success;
      case 'declined':
        return CrmStatusTone.danger;
      case 'pending':
        return CrmStatusTone.warning;
      case 'sent':
      case 'viewed':
      case 'approved':
        return CrmStatusTone.info;
      default:
        return CrmStatusTone.neutral;
    }
  }
}
