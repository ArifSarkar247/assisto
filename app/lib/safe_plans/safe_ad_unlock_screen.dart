import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ads/ads_bridge.dart';
import '../ads/ads_service.dart';
import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/ladder_common.dart' show fmtInt;
import 'safe_plans_api.dart';

/// safeplans PART 4 — "Watch ads to unlock" for GUARDIANS: 3 rewarded ads =
/// 1 day of Child Plan, 3 ads = 1 location request (owner-editable ratios and
/// daily caps). A page of its own with the ad screen key `credits` (the
/// rewarded allowlist) — never an SOS / safety screen. Honest: the server
/// issues one SSV ticket per ad and ONLY Google's signed callback counts it;
/// a child account, a non-guardian, a paid plan or no AdMob -> no ad, and
/// the server's reason is shown.
class SafeAdUnlockScreen extends StatefulWidget {
  final SafePlansApi? api;
  const SafeAdUnlockScreen({super.key, this.api});

  /// Test seam: what the rewarded ad "did".
  @visibleForTesting
  static Future<RewardOutcome> Function(Map<String, dynamic> ticket)? debugShow;

  @override
  State<SafeAdUnlockScreen> createState() => _SafeAdUnlockScreenState();
}

class _SafeAdUnlockScreenState extends State<SafeAdUnlockScreen> {
  late SafePlansApi _api;
  Map<String, dynamic>? _st;
  String? _note;
  bool _busy = false, _failed = false;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? SafePlansDeps.debugApi ?? ApiSafePlansApi(context.read<AppState>().api);
    _load();
  }

  Future<void> _load() async {
    try {
      final st = await _api.load();
      if (!mounted) return;
      setState(() {
        _st = st;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _watch(String goal) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final ticket = await _api.adTicket(goal);
      if (!mounted) return;
      if (ticket['ok'] != true) {
        setState(() {
          _busy = false;
          _note = '${ticket['msg'] ?? t.spAdUnavailable}';
        });
        return;
      }
      final show = SafeAdUnlockScreen.debugShow;
      final outcome = show != null
          ? await show(ticket)
          : await AdsService.instance.showRewardedSsv(app,
              screen: 'credits',
              userId: '${ticket['user_id'] ?? ''}',
              customData: '${ticket['custom_data'] ?? ticket['nonce']}',
              unit: '${ticket['rewarded_unit'] ?? ''}');
      if (!mounted) return;
      if (outcome != RewardOutcome.earned) {
        setState(() {
          _busy = false;
          _note = outcome == RewardOutcome.dismissed ? t.spAdDismissed : t.spAdUnavailable;
        });
        return;
      }
      var status = 'pending';
      for (var i = 0; i < 6 && status == 'pending'; i++) {
        if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        try {
          final s = await _api.adTicketState('${ticket['nonce']}');
          status = '${s['status'] ?? 'pending'}';
        } catch (_) {}
      }
      await _load();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = status == 'verified' ? t.spAdCounted : t.spAdPending;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = t.spAdUnavailable;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final st = _st;
    return Scaffold(
      appBar: AppBar(title: Text(t.spAdsTitle)),
      body: st == null
          ? Center(
              child: _failed
                  ? FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                      onPressed: _load,
                      child: Text(t.spRetry))
                  : const CircularProgressIndicator())
          : ListView(
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: _body(context, t, st),
            ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations t, Map<String, dynamic> st) {
    final ads = spMap(st['ads']);
    String n(dynamic v) => fmtInt(context, spInt(v));
    if (ads['eligible'] != true) {
      return [
        Icon(Icons.block, size: 48, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: Gap.md),
        Text(switch ('${ads['why']}') {
          'child_account' => t.spAdChild,
          'not_guardian' => t.spAdNotGuardian,
          'paid_plan' => t.spAdPaid,
          _ => t.spAdUnavailable,
        }, textAlign: TextAlign.center),
      ];
    }
    Widget goal(String key, String title, int done, int total, int left) => Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(t.spAdProgress(n(done), n(total))),
              const SizedBox(height: Gap.xs),
              LinearProgressIndicator(value: total > 0 ? done / total : 0),
              const SizedBox(height: Gap.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.play_circle_outline),
                  label: Text(left > 0 ? t.spAdWatch : t.spAdCapped),
                  onPressed: (_busy || left <= 0) ? null : () => _watch(key),
                ),
              ),
            ]),
          ),
        );
    return [
      Text(t.spAdIntro),
      const SizedBox(height: Gap.md),
      goal('request', t.spAdsReq(n(ads['for_request'])), spInt(ads['req_n']),
          spInt(ads['for_request']), spInt(ads['req_left'])),
      const SizedBox(height: Gap.sm),
      goal('day', t.spAdsDay(n(ads['for_day'])), spInt(ads['day_n']), spInt(ads['for_day']),
          spInt(ads['day_left'])),
      if (_note != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text(_note!, style: Theme.of(context).textTheme.bodyMedium),
        ),
      const SizedBox(height: Gap.md),
      Text(t.spAdNoClick, style: Theme.of(context).textTheme.bodySmall),
    ];
  }
}
