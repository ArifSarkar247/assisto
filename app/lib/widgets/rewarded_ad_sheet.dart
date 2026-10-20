import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'ladder_common.dart' show fmtInt;

/// REWARDED-AD UNLOCK FLOW (Business Model Build 3, item 4).
///
/// A reusable "watch ads to earn credits" sheet for FREE users. It reads
/// `ads/wallet` for the current ad-wallet balance + caps, then calls
/// `ads/event {kind:'rewarded'}` when the user opts in.
///
/// HONESTY (hard rule): there is NO AdMob SDK dependency here and NO fake ad /
/// fake reward. The real SDK is key-gated server-side; when ads are not enabled
/// `ads/event` comes back not-configured ({enabled:false} / {ok:false} /
/// state:'needs_provider') and we show the honest "ads not set up yet" message
/// — we never credit anything the server didn't. When the server DOES credit
/// (ads enabled + under the daily cap) we show the new balance.
///
/// Callers MUST only show this to FREE users and NEVER on safety screens
/// (helper [RewardedAdSheet.show] is the single entry point; it is the caller's
/// job to gate on plan — see e.g. the Credits screen).
class RewardedAdSheet extends StatefulWidget {
  const RewardedAdSheet({super.key});

  /// Convenience launcher. Returns true if the ad wallet was credited (so the
  /// caller can refresh balances), false/null otherwise.
  static Future<bool?> show(BuildContext context) => showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const RewardedAdSheet(),
      );

  @override
  State<RewardedAdSheet> createState() => _RewardedAdSheetState();
}

enum _AdState { loading, ready, running, notConfigured, capReached, error }

class _RewardedAdSheetState extends State<RewardedAdSheet> {
  _AdState _state = _AdState.loading;
  Map<String, dynamic> _wallet = const {};
  bool _credited = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  Future<void> _load() async {
    setState(() => _state = _AdState.loading);
    try {
      final w = await context.read<AppState>().api.adsWallet();
      if (!mounted) return;
      final caps = (w['caps'] as Map?)?.cast<String, dynamic>() ?? const {};
      final done = _int(caps['rewarded_today']);
      final cap = _int(caps['rewarded_cap']);
      setState(() {
        _wallet = w;
        _state = (cap > 0 && done >= cap) ? _AdState.capReached : _AdState.ready;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // A not-configured gate may come back as a 4xx/501 — treat it as the
      // honest "ads not set up" state rather than a hard error.
      setState(() {
        _state = _AdState.notConfigured;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _AdState.error);
    }
  }

  /// HONEST reward path. We do NOT render an ad (no SDK). We simply report the
  /// intent to the server; the server either credits (ads enabled) or tells us
  /// it is not configured — we reflect exactly that.
  Future<void> _watch() async {
    setState(() => _state = _AdState.running);
    try {
      final r = await context.read<AppState>().api.adsEvent('rewarded');
      if (!mounted) return;
      // Decide the outcome from the honest server shape.
      final notConfigured = r['enabled'] == false ||
          r['ok'] == false ||
          r['state'] == 'needs_provider' ||
          r['state'] == 'not_configured' ||
          r['configured'] == false;
      if (notConfigured) {
        setState(() {
          _state = _AdState.notConfigured;
          _error = (r['message'] ?? r['detail'])?.toString();
        });
        return;
      }
      // Credited — refresh the wallet to show the new balance honestly.
      _credited = true;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _AdState.notConfigured;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _AdState.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final caps = (_wallet['caps'] as Map?)?.cast<String, dynamic>() ?? const {};
    final balance = _int(_wallet['balance_credits']);
    final done = _int(caps['rewarded_today']);
    final cap = _int(caps['rewarded_cap']);

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.xs,
        bottom: Gap.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.ondemand_video_outlined, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.adUnlockTitle,
                  style: Theme.of(context).textTheme.titleLarge),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.adUnlockBody,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.lg),

          // Ad-wallet balance (always honest — straight from the server).
          if (_state != _AdState.loading)
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(children: [
                Icon(Icons.account_balance_wallet_outlined,
                    size: 20, color: scheme.secondary),
                const SizedBox(width: Gap.md),
                Expanded(
                    child: Text(t.adWalletBalance(fmtInt(context, balance)),
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                if (cap > 0)
                  Text(t.adRewardedTodayCap(
                      fmtInt(context, done), fmtInt(context, cap)),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
            ),
          const SizedBox(height: Gap.lg),

          _stateBlock(t, scheme),
          const SizedBox(height: Gap.md),
          Text(t.adUnlockDisclaimer,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _stateBlock(AppLocalizations t, ColorScheme scheme) {
    switch (_state) {
      case _AdState.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: Gap.lg),
          child: Center(child: CircularProgressIndicator()),
        );
      case _AdState.running:
        return Column(children: [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: Gap.md),
          Text(t.adChecking, style: TextStyle(color: scheme.onSurfaceVariant)),
        ]);
      case _AdState.notConfigured:
        // The single most important honest state: no AdMob key -> no ad, no
        // reward, and we SAY so plainly.
        return _honestNote(
          scheme,
          icon: Icons.info_outline,
          tint: Brand.warning,
          title: t.adNotSetUpTitle,
          body: _error?.isNotEmpty == true ? _error! : t.adNotSetUpBody,
        );
      case _AdState.capReached:
        return _honestNote(
          scheme,
          icon: Icons.hourglass_bottom,
          tint: scheme.secondary,
          title: t.adCapTitle,
          body: t.adCapBody,
        );
      case _AdState.error:
        return Column(children: [
          _honestNote(
            scheme,
            icon: Icons.cloud_off_outlined,
            tint: Brand.danger,
            title: t.loadFailed,
            body: t.adLoadError,
          ),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry)),
        ]);
      case _AdState.ready:
        return Column(children: [
          if (_credited)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: _honestNote(
                scheme,
                icon: Icons.check_circle_outline,
                tint: Brand.success,
                title: t.adRewardedTitle,
                body: t.adRewardedBody,
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _watch,
              icon: const Icon(Icons.play_circle_outline),
              label: Text(t.adWatchNow),
            ),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(_credited),
              child: Text(_credited ? t.done : t.adMaybeLater),
            ),
          ),
        ]);
    }
  }

  Widget _honestNote(ColorScheme scheme,
      {required IconData icon,
      required Color tint,
      required String title,
      required String body}) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: tint, size: 22),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(body,
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}
