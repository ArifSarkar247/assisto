import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../plans_v2/plans_v2.dart' show planName;
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../widgets/skeleton.dart';
import 'billing_api.dart';
import 'billing_format.dart';

/// billapp — "Request a refund" (owner order 27 Oct, rules J/K).
///
/// Lists the account's purchases of the last 60 days from GET
/// /credits/refunds. A purchase inside the window gets "Ask for a refund":
/// a sheet that shows the SERVER's suggested amount and the usage behind it
/// (credits used, days used), the policy text, an optional reason and an
/// honest "this is a request, not a promise" line. Submitting POSTs
/// /credits/refunds; every refusal (outside window, already requested, not
/// refundable, too many tries, no internet) is shown in plain words. Each
/// request shows its status (waiting / approved / approved-by-hand / not
/// approved) with the owner's note. Nothing is refunded on the device.
class RefundScreen extends StatefulWidget {
  const RefundScreen({super.key, this.backend});

  /// Tests: a ready backend (default: the signed-in [ApiClient]).
  final BillingApi? backend;

  @override
  State<RefundScreen> createState() => _RefundScreenState();
}

class _RefundScreenState extends State<RefundScreen> {
  RefundsPage? _page;
  bool _loading = true;
  Object? _fail;

  BillingApi get _api =>
      widget.backend ?? BillingApi(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      final p = await _api.refunds();
      if (mounted) setState(() => _page = p);
    } catch (e) {
      if (mounted) setState(() => _fail = e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _ask(Purchase p) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => RefundRequestSheet(
          purchase: p, api: _api, policyText: _page?.policyText ?? '',
          windowHours: _page?.windowHours ?? 0),
    );
    if (sent == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).billRefundSent)));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final page = _page;
    return Scaffold(
      appBar: AppBar(title: Text(t.billRefundTitle), actions: [
        IconButton(
            tooltip: t.refresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      body: _loading && page == null
          ? const SkeletonList()
          : (_fail != null && page == null)
              ? StateMessage(
                  key: const Key('refund-error'),
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: honestFailText(t, _fail, otherwise: t.loadFailedBody),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
                    children: _body(t, scheme, page!),
                  )),
    );
  }

  List<Widget> _body(AppLocalizations t, ColorScheme scheme, RefundsPage page) {
    final pending = page.requests;
    return [
      if (page.policyText.isNotEmpty)
        _Box(
          key: const Key('refund-policy'),
          tint: scheme.primary,
          icon: Icons.policy_rounded,
          title: t.billRefundPolicyTitle,
          body: uiDigits(context, page.policyText),
        ),
      const SizedBox(height: Gap.lg),
      if (pending.isNotEmpty) ...[
        _title(t.billRefundRequestsTitle),
        for (final r in pending) RefundStatusTile(request: r, purchases: page.purchases),
        const SizedBox(height: Gap.lg),
      ],
      _title(t.billRefundPurchases),
      if (page.purchases.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.md),
          child: Text(t.billRefundNoPurchases,
              key: const Key('refund-empty'),
              style: TextStyle(color: scheme.onSurfaceVariant)),
        )
      else
        for (final p in page.purchases) _purchaseCard(t, scheme, p, page.windowHours),
    ];
  }

  Widget _title(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Semantics(
          header: true,
          child: Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
        ),
      );

  Widget _purchaseCard(
      AppLocalizations t, ColorScheme scheme, Purchase p, int windowHours) {
    final what = purchaseName(t, p);
    String? why;
    if (!p.eligible) {
      why = switch (p.reason) {
        'already_requested' => t.billRefundNotEligibleRequested,
        'refunded' => t.billRefundNotEligibleRefunded,
        _ => t.billRefundNotEligibleWindow(fmtInt(context, windowHours)),
      };
    }
    return Card(
      key: ValueKey('refund-purchase-${p.id}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(what,
                  style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: Gap.sm),
            Text(money(context, p.price, p.currency),
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: Gap.xxs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xxs, children: [
            if (p.purchasedAt != null)
              Text(t.billRefundBoughtOn(billDateTime(context, p.purchasedAt!)),
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            if (p.test)
              Text(t.billRefundTest,
                  style: AType.bodySmall.copyWith(
                      color: scheme.tertiary, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.sm),
          if (p.eligible) ...[
            if (p.windowEndsAt != null)
              Text(t.billRefundWindowLeft(billDateTime(context, p.windowEndsAt!)),
                  style: AType.bodySmall),
            const SizedBox(height: Gap.sm),
            FilledButton.tonalIcon(
              key: ValueKey('refund-ask-${p.id}'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => _ask(p),
              icon: const Icon(Icons.undo_rounded),
              label: Text(t.billRefundAsk),
            ),
          ] else
            Text(why!,
                key: ValueKey('refund-why-${p.id}'),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// "Premium (monthly)" style name of a purchase.
String purchaseName(AppLocalizations t, Purchase p) {
  if (p.kind == 'pack') return t.billRefundPack;
  final plan = p.plan.isNotEmpty ? p.plan : p.sku.split('_').first;
  return planName(t, plan == 'business' ? 'business' : (plan == 'free' ? 'free' : 'premium'));
}

/// One refund request and its decision, with the owner's note.
class RefundStatusTile extends StatelessWidget {
  const RefundStatusTile({super.key, required this.request, this.purchases = const []});
  final RefundRequestInfo request;
  final List<Purchase> purchases;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = request;
    Purchase? p;
    for (final x in purchases) {
      if (x.id == r.order) p = x;
    }
    final cur = p?.currency ?? 'BDT';
    final (String label, Color c, IconData icon) = switch (r.status) {
      'approved' => (t.billRefundStatusApproved(money(context, r.approvedAmount, cur)),
          Brand.onTint(context, Brand.success), Icons.check_circle_rounded),
      'manual' => (t.billRefundStatusManual(money(context, r.approvedAmount, cur)),
          Brand.onTint(context, Brand.success), Icons.schedule_send_rounded),
      'rejected' => (t.billRefundStatusRejected, scheme.error, Icons.cancel_rounded),
      _ => (t.billRefundStatusPending, scheme.primary, Icons.hourglass_top_rounded),
    };
    return Card(
      key: ValueKey('refund-req-${r.id}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: c),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (p != null)
                Text(purchaseName(t, p),
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              Text(label,
                  key: ValueKey('refund-status-${r.id}'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: c)),
              if (r.requestedAt != null)
                Text(t.billRefundRequestedOn(billDateTime(context, r.requestedAt!)),
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              if (r.note.trim().isNotEmpty) ...[
                const SizedBox(height: Gap.xxs),
                Text(t.billRefundOwnerNote(r.note.trim())),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The request sheet: server numbers, policy, optional reason, honest send.
class RefundRequestSheet extends StatefulWidget {
  const RefundRequestSheet(
      {super.key,
      required this.purchase,
      required this.api,
      this.policyText = '',
      this.windowHours = 0});
  final Purchase purchase;
  final BillingApi api;
  final String policyText;
  final int windowHours;

  @override
  State<RefundRequestSheet> createState() => _RefundRequestSheetState();
}

class _RefundRequestSheetState extends State<RefundRequestSheet> {
  final _reason = TextEditingController();
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return; // double tap
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = '';
    });
    final r = await widget.api.requestRefund(widget.purchase.id, _reason.text.trim());
    if (!mounted) return;
    if (r.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = switch (r.reason) {
        'network' => t.billRefundNetwork,
        'rate_limited' => r.message.isNotEmpty ? r.message : t.billRefundRateLimited,
        'outside_window' || 'already_requested' || 'not_refundable' || 'not_found' =>
          r.message.isNotEmpty ? r.message : t.billRefundFailed,
        _ => r.message.isNotEmpty ? r.message : t.billRefundFailed,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = widget.purchase;
    final u = p.usage;
    int n(Object? v) => v is num ? v.round() : 0;
    final planned = n(u['credits_planned']);
    final daysTotal = n(u['days_total']);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.billRefundAsk,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.xxs),
          Text('${purchaseName(t, p)} · ${money(context, p.price, p.currency)}',
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          if (p.suggested != null)
            Text(t.billRefundSuggested(money(context, p.suggested!, p.currency)),
                key: const Key('refund-suggested'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          if (planned > 0)
            Text(t.billRefundUsageCredits(
                fmtInt(context, n(u['credits_used'])), fmtInt(context, planned))),
          if (p.kind == 'sub' && daysTotal > 0)
            Text(t.billRefundUsageDays(
                fmtInt(context, n(u['days_used'])), fmtInt(context, daysTotal))),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('refund-reason'),
            controller: _reason,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: t.billRefundReasonLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(t.billRefundNoPromise,
                key: const Key('refund-no-promise'),
                style: AType.bodySmall.copyWith(height: 1.4)),
          ),
          if (widget.policyText.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(uiDigits(context, widget.policyText),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
          if (_error.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Container(
              key: const Key('refund-error-note'),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Semantics(
                liveRegion: true,
                child: Text(_error, style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ),
          ],
          const SizedBox(height: Gap.md),
          FilledButton(
            key: const Key('refund-send'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _send,
            child: _busy
                ? const SizedBox(
                    width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                : Text(t.billRefundSend),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: Text(t.cancel),
          ),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box(
      {super.key,
      required this.tint,
      required this.icon,
      required this.title,
      required this.body});
  final Color tint;
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: tint),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xxs),
            Text(body,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}
