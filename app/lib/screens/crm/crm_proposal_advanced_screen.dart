import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:flutter/services.dart';
import '../../theme.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_aftersale_api.dart';
import '../../widgets/crm_aftersale_widgets.dart';
import 'crm_common.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../widgets/num_input.dart'; // savesweep

/// q1-seams: true only once a customer-facing acceptance PAGE exists (an
/// absolute https link that renders accept / decline), not a JSON API path.
/// crm100: wired — the server now returns https://lifeassisto.com/qp/<token>
/// (random token, noindex, rate-limited, bn/en, expiry enforced).
const bool kQuoteAcceptPageWired = true;

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
        scrollable: true, // insets: 200% text / keyboard
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
    final days = parseIntInput(ctl.text.trim()) ?? 30;
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
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
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
      await showAppSheet<void>(
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
                    icon: Icons.picture_as_pdf_rounded),
              ],
              const SizedBox(height: Gap.sm),
              Text((m['brand']?['name'] ?? '').toString(),
                  style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w800)),
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
                    icon: Icons.flag_rounded),
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
                  ? ListView(padding: const EdgeInsets.all(Gap.md), children: [
                      DsEmptyState(
                          icon: Icons.history_rounded,
                          title: t.crmNoVersions,
                          benefit: t.crmNoVersionsHint),
                    ])
                  : ListView(
                      padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
                      children: [
                        for (final p in _versions)
                          Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: _versionCard(t, p)),
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

    return DsCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Text(localDigits('v${p['version']} · ${p['title'] ?? ''}', _lang),
                    style: AType.bodyLarge.copyWith(color: scheme.ds.text, fontWeight: FontWeight.w800))),
            const SizedBox(width: Gap.sm),
            // the status in the user's language (was the raw server code)
            CrmStatusPill(_statusLabel(t, status), tone: _statusTone(status)),
          ]),
          const SizedBox(height: Gap.xs),
          // the total, big and tight (Bangla digits in bn)
          DsNumber(localDigits(bdtFromPoisha(total), _lang), small: true),

          // ---- validity / expiry ----
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Row(children: [
              Icon(Icons.event_rounded,
                  size: 16, color: expired ? scheme.ds.dangerInk : scheme.ds.muted),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  expired
                      ? t.crmQuoteExpired
                      : daysLeft == null
                          ? t.crmQuoteNoExpiry
                          : t.crmQuoteDaysLeft(localDigits(daysLeft.toString(), _lang)),
                  style: AType.labelMedium.copyWith(color: expired ? scheme.ds.dangerInk : scheme.ds.muted,
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
                Icon(Icons.verified_user_rounded,
                    size: 16,
                    color: discountApproved ? AssistoTokens.of(context).success : AssistoTokens.of(context).warning),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    discountApproved
                        ? t.crmDiscountApproved
                        : t.crmDiscountNeedsApproval,
                    style: AType.labelMedium.copyWith(fontWeight: FontWeight.w700,
                        color: discountApproved
                            ? scheme.ds.successInk
                            : Brand.onTint(context, AssistoTokens.of(context).warning)),
                  ),
                ),
              ]),
            ),

          if (!reviewed)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.crmToReview,
                  style: AType.labelMedium.copyWith(
                      color: Brand.onTint(context, AssistoTokens.of(context).warning),
                      fontWeight: FontWeight.w700)),
            ),

          const SizedBox(height: Gap.sm),
          // the main next step first (convert / approve), then the rest
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (status == 'accepted' && !expired)
              DsButton.secondary(
                  onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                      .convertToOrder((p['id'] as num).toInt())),
                  icon: Icons.shopping_cart_checkout_rounded,
                  label: t.crmConvertToOrder),
            if (discountNeedsApproval && !discountApproved)
              DsButton.secondary(
                  onPressed: () => _run(() => CrmAfterSaleApi.of(context)
                      .approveDiscount((p['id'] as num).toInt())),
                  icon: Icons.gavel_rounded,
                  label: t.crmApproveDiscount),
            DsButton.secondary(
                onPressed: () => _setValidity(t, p),
                icon: Icons.event_rounded,
                label: t.crmQuoteValidity),
            DsButton.secondary(
                onPressed: () => _showPdfPreview(t, p),
                icon: Icons.picture_as_pdf_rounded,
                label: t.crmBrandedPdf),
            // crm100: the server hands back the customer's web page
            // (/qp/<token>); before, it was a relative JSON path (hidden).
            if (kQuoteAcceptPageWired &&
                (status == 'sent' || status == 'viewed' || status == 'approved'))
              DsButton.secondary(
                  onPressed: () => _showAcceptanceLink(t, p),
                  icon: Icons.link_rounded,
                  label: t.crmAcceptanceLink),
          ]),
        ]),
    );
  }

  String get _lang => Localizations.localeOf(context).languageCode;

  String _statusLabel(AppLocalizations t, String s) {
    switch (s) {
      case 'draft': return t.shopQaPropDraft;
      case 'pending': return t.shopQaPropPending;
      case 'approved': return t.shopQaPropApproved;
      case 'sent': return t.shopQaPropSent;
      case 'viewed': return t.shopQaPropViewed;
      case 'accepted': return t.shopQaPropAccepted;
      case 'declined': return t.shopQaPropDeclined;
      default: return s;
    }
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
