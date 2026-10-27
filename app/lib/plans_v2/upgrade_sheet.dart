import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../payments/checkout_sheet.dart';
import '../payments/payments_api.dart';
import '../payments/play_prices.dart';
import '../screens/plans_screen.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'plans_v2.dart';

/// plans-v2 — the ONE honest upgrade sheet for a locked action.
///
///  * Says exactly WHY it opened ("CRM is view only on Free: upgrade to
///    Premium to add leads", "18/20 contacts", …) — the reason comes from
///    the server's structured 402 or from /plans/v2 before the tap.
///  * Price: on the Google Play build ONLY Play's own price from
///    ProductDetails (PlayPrices); on the website APK the server's ৳ price.
///  * NEVER a fake button: "Upgrade" exists only when a live payment channel
///    of this build sells the plan AND (Play) its store price is known; it
///    opens the shared CheckoutSheet. Otherwise only "See plans" is offered.
///  * The free trial (once per account, no card, clear end date, nothing is
///    charged when it ends) is offered only when the server says it is
///    available.
class UpgradeSheet extends StatefulWidget {
  final UpgradeReason reason;
  final PaymentsBackend? backend;
  final String? flavour;

  /// Tests / gallery: plan state + trial starter (default: the real API).
  final Future<PlansV2State> Function()? loadState;
  final Future<Map<String, dynamic>> Function()? startTrial;

  const UpgradeSheet({
    super.key,
    required this.reason,
    this.backend,
    this.flavour,
    this.loadState,
    this.startTrial,
  });

  /// Returns true when the user upgraded or started the trial (reload).
  static Future<bool?> show(BuildContext context, UpgradeReason reason,
          {PaymentsBackend? backend, String? flavour}) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) =>
            UpgradeSheet(reason: reason, backend: backend, flavour: flavour),
      );

  /// If [e] is a plans-v2 refusal, open the sheet and return true.
  static Future<bool> handle(BuildContext context, Object e) async {
    final r = UpgradeReason.fromError(e);
    if (r == null) return false;
    await show(context, r);
    return true;
  }

  @override
  State<UpgradeSheet> createState() => _UpgradeSheetState();
}

/// (title, body) of a reason. Pure, unit-tested.
(String, String) upgradeReasonText(AppLocalizations t, BuildContext context,
    UpgradeReason r) {
  final plan = planName(t, r.neededPlan);
  switch (r.feature) {
    case 'crm_contacts':
      return (
        t.pv2ReasonContactsTitle,
        t.pv2ReasonContactsBody(fmtInt(context, r.used ?? 0),
            fmtInt(context, r.limit ?? 0), plan)
      );
    case 'crm_write':
      return (t.pv2ReasonCrmWriteTitle, t.pv2ReasonCrmWriteBody(plan));
    case 'crm_followup_reminders':
      return (t.pv2ReasonFollowupTitle, t.pv2ReasonFollowupBody(plan));
    case 'automation':
      return (t.pv2ReasonAutomationTitle, t.pv2ReasonAutomationBody(plan));
    case 'ai_sales_agent':
      return (t.pv2ReasonAgentTitle, t.pv2ReasonAgentBody(plan));
    case 'booking_bot':
      return (t.pv2ReasonBookingTitle, t.pv2ReasonBookingBody(plan));
    case 'reports':
      return (t.pv2ReasonReportsTitle, t.pv2ReasonReportsBody(plan));
    case 'ledger_ai_addons':
      return (t.pv2ReasonLedgerAiTitle, t.pv2ReasonLedgerAiBody(plan));
  }
  return (t.pv2ReasonGenericTitle(plan),
      r.serverMessage.isNotEmpty ? r.serverMessage : t.pv2ReasonGenericBody(plan));
}

/// What the needed plan really adds — only built, LIVE features (owner
/// rule): the booking bot and retention messages are listed only while their
/// own feature flags are on for this user. No team members, no marketing.
List<String> upgradeBenefits(AppLocalizations t, String plan,
        {bool booking = false, bool retention = false}) =>
    plan == 'premium'
        ? [t.pv2BenefitPremiumContacts, t.pv2BenefitPremiumCrm, t.pv2BenefitPremiumFollowup]
        : [
            t.pv2BenefitBusinessContacts,
            t.pv2BenefitBusinessAutomation,
            if (retention) t.pv2BenefitBusinessRetention,
            t.pv2BenefitBusinessAgent,
            if (booking) t.pv2BenefitBusinessBooking,
            t.pv2BenefitBusinessReports,
          ];

IconData _icon(String feature) => switch (feature) {
      'crm_contacts' => Icons.contacts_rounded,
      'crm_write' => Icons.view_kanban_rounded,
      'crm_followup_reminders' => Icons.alarm_rounded,
      'automation' => Icons.bolt_rounded,
      'ai_sales_agent' => Icons.support_agent_rounded,
      'booking_bot' => Icons.event_available_rounded,
      'reports' => Icons.bar_chart_rounded,
      _ => Icons.workspace_premium_rounded,
    };

class _UpgradeSheetState extends State<UpgradeSheet> {
  PayConfig? _cfg;
  PlansV2State _state = PlansV2State.off;
  bool _loading = true, _pricesLoading = false, _busy = false;
  String? _trialMsg;
  bool _trialOk = false;

  String get _flavour => widget.flavour ?? payFlavour();
  String get _sku => '${widget.reason.neededPlan}_monthly';

  PaymentsBackend? _backend() {
    if (widget.backend != null) return widget.backend;
    try {
      return ApiPaymentsBackend(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final b = _backend();
    try {
      if (b != null) _cfg = await b.config(_flavour);
    } catch (_) {
      _cfg = null; // offline: no buy button, "See plans" still works
    }
    try {
      final ls = widget.loadState;
      if (ls != null) {
        _state = await ls();
      } else if (mounted) {
        _state = await loadPlansV2(context.read<AppState>().api);
      }
    } catch (_) {
      _state = PlansV2State.off;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    final p = _product();
    if (_flavour == 'play' && p != null) {
      setState(() => _pricesLoading = true);
      await PlayPrices.ensure([p]);
      if (mounted) setState(() => _pricesLoading = false);
    }
  }

  /// The product a LIVE channel of this build sells for the needed plan.
  PayProduct? _product() {
    final c = _cfg;
    if (c == null) return null;
    for (final ch in c.live(_flavour)) {
      final p = c.product(ch.id, _sku);
      if (p != null) return p;
    }
    return null;
  }

  /// Play: Play's own formatted price (null while unknown). APK: server ৳.
  String? _price(PayProduct p) {
    if (_flavour == 'play') {
      final s = PlayPrices.of(p);
      return s == null ? null : localizeStoreDigits(context, s);
    }
    return '৳${fmtInt(context, p.priceBdt)}';
  }

  Future<void> _buy() async {
    final nav = Navigator.of(context);
    final ok = await CheckoutSheet.show(context, _sku,
        backend: widget.backend, flavour: _flavour);
    if (ok == true && mounted) nav.pop(true);
  }

  Future<void> _trial() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      final st = widget.startTrial;
      r = st != null
          ? await st()
          : await context.read<AppState>().api.postJson('/plans/trial/start');
    } catch (_) {
      r = {'ok': false};
    }
    if (!mounted) return;
    final ok = r['ok'] == true;
    final until = DateTime.tryParse('${r['trial_until'] ?? ''}')?.toLocal();
    setState(() {
      _busy = false;
      _trialOk = ok;
      _trialMsg = ok
          ? t.pv2TrialStarted(planName(t, '${r['trial_plan'] ?? _state.trialPlan}'),
              until != null ? _date(until) : '')
          : t.pv2TrialUsed;
    });
  }

  String _date(DateTime d) =>
      trialDate(context, d);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = widget.reason;
    final (title, body) = upgradeReasonText(t, context, r);
    final p = _product();
    final price = p == null ? null : _price(p);
    final canBuy = p != null && price != null;
    final trialEnd = DateTime.now().add(Duration(days: _state.trialDays));
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(_icon(r.feature), color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title,
                    key: const Key('pv2-upgrade-title'),
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(body,
              key: const Key('pv2-upgrade-body'),
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          if (r.limit != null && r.used != null) ...[
            const SizedBox(height: Gap.md),
            _usage(t, scheme, r),
          ],
          const SizedBox(height: Gap.lg),
          Text(t.pv2WhatYouGet(planName(t, r.neededPlan)),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          for (final b in upgradeBenefits(t, r.neededPlan,
              booking: FeatureFlags.instance.isOn('booking_bot'),
              retention: FeatureFlags.instance.isOn('retention_auto')))
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check_circle_rounded,
                    size: 20, color: Brand.onTint(context, Brand.success)),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(b)),
              ]),
            ),
          const SizedBox(height: Gap.md),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (canBuy)
              FilledButton.icon(
                key: const Key('pv2-upgrade-buy'),
                onPressed: _busy ? null : _buy,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.workspace_premium_rounded),
                label: Text(t.pv2UpgradeTo(planName(t, r.neededPlan), price),
                    textAlign: TextAlign.center),
              )
            else if (p != null && _flavour == 'play')
              // Play build, store price not known yet: no button, honest line.
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Text(
                    _pricesLoading ? t.pv2PriceLoading : t.payPriceUnavailable,
                    key: const Key('pv2-price-unavailable'),
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            if (canBuy && _flavour == 'play')
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.pv2PlayNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            if (_trialMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.md),
                child: Text(_trialMsg!,
                    key: const Key('pv2-trial-msg'),
                    style: TextStyle(
                        color: _trialOk
                            ? Brand.onTint(context, Brand.success)
                            : scheme.error,
                        fontWeight: FontWeight.w600)),
              ),
            if (_state.on && _state.trialAvailable && !_trialOk) ...[
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                key: const Key('pv2-trial'),
                onPressed: _busy ? null : _trial,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                icon: const Icon(Icons.card_giftcard_rounded),
                label: Text(
                    t.pv2TrialButton(fmtInt(context, _state.trialDays),
                        planName(t, _state.trialPlan)),
                    textAlign: TextAlign.center),
              ),
              const SizedBox(height: Gap.xs),
              Text(t.pv2TrialNote(_date(trialEnd)),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: Gap.md),
            OutlinedButton(
              key: const Key('pv2-see-plans'),
              onPressed: () {
                final nav = Navigator.of(context);
                nav.pop(_trialOk);
                nav.push(MaterialPageRoute(builder: (_) => const PlansScreen()));
              },
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(t.pv2SeePlans),
            ),
          ],
          const SizedBox(height: Gap.xs),
          TextButton(
            onPressed: () => Navigator.pop(context, _trialOk),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(t.pv2NotNow),
          ),
        ],
      ),
    );
  }

  Widget _usage(AppLocalizations t, ColorScheme scheme, UpgradeReason r) {
    final lim = r.limit ?? 0;
    final used = r.used ?? 0;
    final frac = lim <= 0 ? 1.0 : (used / lim).clamp(0.0, 1.0);
    final label = t.pv2UsageContacts(fmtInt(context, used), fmtInt(context, lim));
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              key: const Key('pv2-usage'),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: LinearProgressIndicator(
              value: frac.toDouble(),
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              color: frac >= 1 ? scheme.error : scheme.primary,
            ),
          ),
        ]),
      ),
    );
  }
}
