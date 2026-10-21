import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'ladder_common.dart' show fmtInt;
import '../ads/ads_bridge.dart';
import '../ads/ads_service.dart';

/// REWARDED-AD UNLOCK FLOW (Business Model Build 3, item 4).
///
/// A reusable "watch ads to earn credits" sheet for FREE users. It reads
/// `ads/wallet` for the current ad-wallet balance + caps, then calls
/// `ads/event {kind:'rewarded'}` when the user opts in.
///
/// HONESTY (hard rule): no fake ad / fake reward. The ad is played through
/// [AdsService] (AdMob, under AdRules: rewarded only from the Credits screen,
/// always user-initiated). `ads/event` is posted ONLY after the SDK reported
/// the reward; no SDK / no AdMob ids -> the honest "ads not set up yet" state.
/// The server is still the authority on what is credited (caps, fraud).
///
/// Free users earn into the ad wallet; Premium/Business users see no ads
/// unless they open this sheet themselves (opt-in) — their whole credits go
/// straight to their balance (server side).
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

  /// (used today, daily cap) for rewarded. Server shape:
  /// caps: {rewarded: {cap, used, remaining}}; older flat keys tolerated.
  (int, int) _rewardedCaps(Map<String, dynamic> w) {
    final caps = (w['caps'] as Map?)?.cast<String, dynamic>() ?? const {};
    final r = caps['rewarded'];
    if (r is Map) return (_int(r['used']), _int(r['cap']));
    return (_int(caps['rewarded_today']), _int(caps['rewarded_cap']));
  }

  String? _note;

  Future<void> _load() async {
    setState(() => _state = _AdState.loading);
    try {
      final w = await context.read<AppState>().api.adsWallet();
      if (!mounted) return;
      final (done, cap) = _rewardedCaps(w);
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

  /// HONEST reward path: play a real rewarded ad first; only a completed ad
  /// (SDK reward callback) is reported to the server, which decides the credit.
  Future<void> _watch() async {
    final app = context.read<AppState>();
    final t = AppLocalizations.of(context);
    setState(() {
      _state = _AdState.running;
      _note = null;
    });
    try {
      final outcome =
          await AdsService.instance.showRewarded(app, screen: 'credits');
      if (!mounted) return;
      if (outcome == RewardOutcome.unavailable) {
        setState(() {
          _state = _AdState.notConfigured;
          _error = AdsService.instance.config.configured
              ? t.adsUnavailableBody
              : null;
        });
        return;
      }
      if (outcome == RewardOutcome.dismissed) {
        setState(() {
          _state = _AdState.ready;
          _note = t.adsDismissedBody;
        });
        return;
      }
      final r = await app.api.adsEvent('rewarded');
      if (!mounted) return;
      if (r['reason'] == 'capped') {
        setState(() => _state = _AdState.capReached);
        return;
      }
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
    final balance = _int(_wallet['balance_credits']);
    final (done, cap) = _rewardedCaps(_wallet);

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
                      // (cap, done) — gen-l10n metadata order
                      fmtInt(context, cap), fmtInt(context, done)),
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
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: _honestNote(
                scheme,
                icon: Icons.info_outline,
                tint: scheme.secondary,
                title: t.adWatchNow,
                body: _note!,
              ),
            ),
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
