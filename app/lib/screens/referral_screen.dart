import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/referral_balance_card.dart';
import '../widgets/referral_history_tile.dart';

/// Referral points — invite people into your Connected Circle; when an invitee
/// installs, signs up AND accepts your relationship invite you earn points that
/// redeem for Premium days. This screen shows the balance, how-it-works, an
/// invite/share action, a redeem action, and the points history (ledger).
///
/// Data (api):
///   referralBalance()  -> {points, redeemable_days, points_per_day,
///                          min_redeem, can_redeem, invite_link?}
///   referralHistory()  -> {history: [{kind, points, reason, label,
///                          created_at}, ...]}
///   referralRedeem(points) -> {ok, days, spent, points, ...}
/// Redeem APPLIES Premium days server-side via the plan mechanism; the client
/// just reloads the (now higher) balance and shows the days granted.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});
  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  Map<String, dynamic>? _bal;
  List<Map<String, dynamic>> _history = [];
  bool _loading = true, _error = false, _busy = false;

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
      final api = context.read<AppState>().api;
      final res = await Future.wait([api.referralBalance(), api.referralHistory()]);
      _bal = res[0];
      _history =
          (((res[1])['history'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  Future<void> _invite() async {
    final t = AppLocalizations.of(context);
    final link = (_bal?['invite_link'] ?? '').toString();
    final msg = link.isNotEmpty ? '${t.referralShareMessage}\n$link' : t.referralShareMessage;
    await Share.share(msg);
  }

  Future<void> _redeem() async {
    final t = AppLocalizations.of(context);
    final b = _bal;
    if (b == null) return;
    final points = _int(b['points']);
    final perDay = _int(b['points_per_day']);
    final maxDays = perDay > 0 ? points ~/ perDay : 0;
    if (maxDays < 1) return;

    final days = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RedeemSheet(maxDays: maxDays, pointsPerDay: perDay),
    );
    if (days == null || days < 1) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final r = await context
          .read<AppState>()
          .api
          .referralRedeem(days * perDay);
      final granted = _int(r['days']);
      messenger.showSnackBar(SnackBar(
          content: Text(r['ok'] == true
              ? t.referralRedeemedDays(granted)
              : t.referralRedeemFailed)));
      await _load();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.referralRedeemFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.referralTitle)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)))
              : RefreshIndicator(onRefresh: _load, child: _body(t, scheme)),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    final b = _bal ?? const {};
    final points = _int(b['points']);
    final days = _int(b['redeemable_days']);
    final perDay = _int(b['points_per_day']);
    final canRedeem = b['can_redeem'] == true;

    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      ReferralBalanceCard(
          points: points, redeemableDays: days, pointsPerDay: perDay),
      const SizedBox(height: Gap.lg),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _invite,
            icon: const Icon(Icons.person_add_alt, size: 18),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            label: Text(t.referralInvite),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: (_busy || !canRedeem) ? null : _redeem,
            icon: const Icon(Icons.workspace_premium, size: 18),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            label: Text(t.referralRedeem),
          ),
        ),
      ]),
      const SizedBox(height: Gap.lg),
      _howItWorks(t, scheme),
      const SizedBox(height: Gap.lg),
      Text(t.referralHistoryTitle,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      const SizedBox(height: Gap.sm),
      if (_history.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xl),
          child: Column(children: [
            Icon(Icons.history, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.sm),
            Text(t.referralHistoryEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ]),
        )
      else
        for (final e in _history) ReferralHistoryTile(entry: e),
      const SizedBox(height: Gap.md),
      Text(t.referralRateReviewNote,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }

  Widget _howItWorks(AppLocalizations t, ColorScheme scheme) {
    final steps = [
      (Icons.ios_share, t.referralStep1),
      (Icons.download_done, t.referralStep2),
      (Icons.handshake, t.referralStep3),
      (Icons.workspace_premium, t.referralStep4),
    ];
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.referralHowTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        for (final s in steps)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(s.$1, size: 18, color: scheme.primary),
              const SizedBox(width: Gap.md),
              Expanded(
                  child: Text(s.$2,
                      style: const TextStyle(fontSize: 13, height: 1.35))),
            ]),
          ),
      ]),
    );
  }
}

/// Bottom sheet to pick how many Premium days to redeem (1..maxDays).
class _RedeemSheet extends StatefulWidget {
  final int maxDays;
  final int pointsPerDay;
  const _RedeemSheet({required this.maxDays, required this.pointsPerDay});
  @override
  State<_RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends State<_RedeemSheet> {
  late int _days = 1;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cost = _days * widget.pointsPerDay;
    final maxD = widget.maxDays < 1 ? 1 : widget.maxDays;
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.referralRedeem,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(t.referralRedeemPickDays,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            Text(t.referralRedeemDaysChosen(_days),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Slider(
              value: _days.toDouble(),
              min: 1,
              max: maxD.toDouble(),
              divisions: maxD > 1 ? maxD - 1 : null,
              label: '$_days',
              onChanged: (v) => setState(() => _days = v.round()),
            ),
            Text(t.referralRedeemCost(cost),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_days),
                child: Text(t.referralRedeemConfirm),
              ),
            ),
          ]),
    );
  }
}
