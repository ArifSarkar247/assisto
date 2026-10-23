import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ads/sponsor_api.dart';
import '../l10n/app_localizations.dart';
import '../screens/plans_screen.dart';
import '../state.dart';
import '../theme.dart';
import 'ladder_common.dart' show fmtInt;

/// p2-money: the PAYWALL at the moment of need. It says WHY it opened (out of
/// credits, video call, family circle full, ad-free, storage full), lists
/// ONLY real Premium-only benefits (built by the server from the live
/// config — nothing Free also gets, nothing not enforced), shows the monthly
/// and the yearly price (the yearly discount is always the SAFE one the
/// server clamps to), and offers the 3-day free trial once per account (no
/// card; the server enforces "once"). Buying happens on the Plans screen
/// through the existing checkout. Never shown over a call / SOS / payment.
enum PaywallReason { outOfCredits, videoCall, familyLimit, adFree, storageFull, generic }

extension PaywallReasonWire on PaywallReason {
  String get wire => switch (this) {
        PaywallReason.outOfCredits => 'out_of_credits',
        PaywallReason.videoCall => 'video_call',
        PaywallReason.familyLimit => 'family_limit',
        PaywallReason.adFree => 'ad_free',
        PaywallReason.storageFull => 'storage_full',
        PaywallReason.generic => 'generic',
      };
}

/// (headline, body) for a reason. Pure lookup, unit-tested.
(String, String) paywallReasonText(AppLocalizations t, PaywallReason r) =>
    switch (r) {
      PaywallReason.outOfCredits => (t.p2PayReasonCredits, t.p2PayReasonCreditsBody),
      PaywallReason.videoCall => (t.p2PayReasonVideo, t.p2PayReasonVideoBody),
      PaywallReason.familyLimit => (t.p2PayReasonFamily, t.p2PayReasonFamilyBody),
      PaywallReason.adFree => (t.p2PayReasonAdFree, t.p2PayReasonAdFreeBody),
      PaywallReason.storageFull => (t.p2PayReasonStorage, t.p2PayReasonStorageBody),
      PaywallReason.generic => (t.p2PayTitle, t.p2PayReasonGenericBody),
    };

IconData _icon(PaywallReason r) => switch (r) {
      PaywallReason.outOfCredits => Icons.bolt_outlined,
      PaywallReason.videoCall => Icons.videocam_outlined,
      PaywallReason.familyLimit => Icons.diversity_3_outlined,
      PaywallReason.adFree => Icons.block_outlined,
      PaywallReason.storageFull => Icons.cloud_outlined,
      PaywallReason.generic => Icons.workspace_premium_outlined,
    };

class PaywallSheet extends StatefulWidget {
  const PaywallSheet({super.key, required this.reason, this.backend, this.offer});

  final PaywallReason reason;
  final SponsorBackend? backend;

  /// Gallery / tests: a ready offer (skips the network).
  final Map<String, dynamic>? offer;

  /// Returns true when a trial was started.
  static Future<bool?> show(BuildContext context, PaywallReason reason,
          {SponsorBackend? backend}) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => PaywallSheet(reason: reason, backend: backend),
      );

  @override
  State<PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<PaywallSheet> {
  Map<String, dynamic>? _offer;
  bool _failed = false;
  bool _busy = false;
  String? _trialMsg;
  bool _trialOk = false;

  SponsorBackend? get _backend {
    try {
      return widget.backend ?? ApiSponsorBackend(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _offer = widget.offer;
    if (_offer == null) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final b = _backend;
    if (b == null) {
      setState(() => _failed = true);
      return;
    }
    try {
      final o = await b.premiumOffer(widget.reason.wire);
      if (mounted) setState(() => _offer = o);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  Future<void> _trial() async {
    final t = AppLocalizations.of(context);
    final b = _backend;
    if (b == null) return;
    setState(() => _busy = true);
    final r = await b.startTrial();
    if (!mounted) return;
    final ok = r['ok'] == true;
    setState(() {
      _busy = false;
      _trialOk = ok;
      _trialMsg = ok
          ? t.p2PayTrialStarted(fmtInt(context, _i(r['days'] ?? _offer?['trial_days'])))
          : ((r['msg'] ?? '').toString().isNotEmpty ? '${r['msg']}' : t.p2PayTrialUsed);
    });
    if (ok) {
      try {
        // refresh the user's plan everywhere (ads switch off at once)
        final app = context.read<AppState>();
        await app.api.plan();
      } catch (_) {}
    }
  }

  void _plans() {
    final nav = Navigator.of(context);
    nav.pop(_trialOk);
    nav.push(MaterialPageRoute(builder: (_) => const PlansScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (head, body) = paywallReasonText(t, widget.reason);
    final o = _offer;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(_icon(widget.reason), color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                  child: Text(head,
                      key: const Key('p2-paywall-head'),
                      style: Theme.of(context).textTheme.titleLarge)),
            ]),
            const SizedBox(height: Gap.sm),
            Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.lg),
            if (o == null && !_failed)
              const Padding(
                padding: EdgeInsets.all(Gap.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (o == null)
              Text(t.p2PayLoadFail, style: TextStyle(color: scheme.error))
            else ...[
              Text(t.p2PayOnlyPremium,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.sm),
              for (final b in ((o['benefits'] as List?) ?? const []).whereType<Map>())
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.check_circle, size: 20, color: Brand.success),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: Text('${b['text'] ?? ''}')),
                  ]),
                ),
              const SizedBox(height: Gap.md),
              _prices(t, scheme, o),
              const SizedBox(height: Gap.lg),
              if (_trialMsg != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: Text(_trialMsg!,
                      style: TextStyle(
                          color: _trialOk
                              ? Brand.onTint(context, Brand.success)
                              : scheme.error,
                          fontWeight: FontWeight.w600)),
                ),
              if (o['trial_available'] == true && !_trialOk) ...[
                FilledButton.icon(
                  key: const Key('p2-trial'),
                  onPressed: _busy ? null : _trial,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  icon: const Icon(Icons.card_giftcard_outlined),
                  label: Text(t.p2PayTrial(fmtInt(context, _i(o['trial_days'])))),
                ),
                const SizedBox(height: Gap.xs),
                Text(t.p2PayTrialNote,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.md),
              ],
              OutlinedButton(
                onPressed: _plans,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: Text(t.p2PaySeePlans),
              ),
            ],
            const SizedBox(height: Gap.xs),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context, _trialOk),
                child: Text(t.p2PayNotNow),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _prices(AppLocalizations t, ColorScheme scheme, Map<String, dynamic> o) {
    final monthly = _i(o['monthly_price']);
    final yearly = _i(o['yearly_price']);
    final pct = _i(o['yearly_discount_pct']);
    final equiv = o['yearly_monthly_equiv'];
    final eq = equiv is num ? equiv.round() : 0;
    Widget box(String a, String? b) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (b != null)
                Text(b, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
          ),
        );
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      box(t.p2PayMonthly(fmtInt(context, monthly)), null),
      if (yearly > 0) ...[
        const SizedBox(width: Gap.sm),
        box(
            pct > 0
                ? t.p2PayYearly(fmtInt(context, yearly), fmtInt(context, pct))
                : t.p2PayYearlyPlain(fmtInt(context, yearly)),
            t.p2PayYearlyEquiv(fmtInt(context, eq))),
      ],
    ]);
  }
}
