import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../billing/cctv_plan_screen.dart';
import '../billing/cctv_plan_source.dart';
import '../l10n/app_localizations.dart';
import '../payments/play_prices.dart' show localizeStoreDigits;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'buy_inside.dart' show BuyOrigin;

/// buyinside — the locked CCTV screen, exactly as the owner approved it
/// (10 Nov): icon, name, 3 clear benefits, primary "Start 7 days free",
/// secondary price button ("৳500 a month for 2 cameras"), the small line
/// "then ৳500 a month · cancel any time · paid with Google Play" and a link
/// to all plans. The trial is Google Play's free-trial offer: shown ONLY when
/// our server says this shop / person never had it AND Play lists the offer
/// for this Google account (Play's "new customers" eligibility). Returns
/// true when the plan became active — the caller reloads the same screen,
/// now unlocked.
class CctvLockedSheet extends StatefulWidget {
  final String featureKey;
  final CctvPlanApi? api;
  final CctvPlanBuyer? buyer;

  /// Tests / gallery: show this payload + Play offers without the network.
  final Map<String, dynamic>? preview;
  final Map<String, String>? previewOffers;

  const CctvLockedSheet(
      {super.key,
      this.featureKey = 'cctv',
      this.api,
      this.buyer,
      this.preview,
      this.previewOffers});

  static Future<bool?> show(BuildContext context,
          {String featureKey = 'cctv', CctvPlanApi? api, CctvPlanBuyer? buyer}) =>
      showAppSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => CctvLockedSheet(featureKey: featureKey, api: api, buyer: buyer),
      );

  @override
  State<CctvLockedSheet> createState() => _CctvLockedSheetState();
}

class _CctvLockedSheetState extends State<CctvLockedSheet> {
  late final CctvPlanApi _api =
      widget.api ?? ApiCctvPlanApi(context.read<AppState>().api);
  late final CctvPlanBuyer _buyer = widget.buyer ?? CctvPlanBuyer(_api);

  Map<String, dynamic>? _d;
  Map<String, String> _offers = const {};
  bool _store = false, _loading = true, _busy = false, _failed = false;
  String _note = '';

  @override
  void initState() {
    super.initState();
    BuyOrigin.current = widget.featureKey;
    if (widget.preview != null) {
      _d = widget.preview;
      _offers = widget.previewOffers ?? const {};
      _store = widget.previewOffers != null;
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final d = await _api.load();
      final store = await _buyer.available();
      var offers = const <String, String>{};
      if (store && d['on_sale'] == true) {
        offers = await _buyer.offers('${d['product_id'] ?? ''}');
      }
      if (!mounted) return;
      setState(() {
        _d = d;
        _store = store;
        _offers = offers;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Map<String, dynamic> get _status =>
      (_d?['status'] is Map) ? (_d!['status'] as Map).cast<String, dynamic>() : const {};
  bool get _active => _status['status'] == 'active';
  String get _base => '${_d?['trial_base_plan'] ?? cctvBasePlan(2, false)}';
  String get _product => '${_d?['product_id'] ?? ''}';

  bool get _trial =>
      _d?['trial_available'] == true &&
      !_active &&
      _offers.containsKey('$_base#${_d?['trial_offer_id']}');

  /// Play's own price for the 2-camera base plan; the server's taka number
  /// only when the store is not reachable (then no buy button anyway).
  String? get _playPrice {
    final s = _offers[_base];
    return s == null ? null : localizeStoreDigits(context, s);
  }

  int get _baseTaka {
    for (final m in (_d?['tiers'] as List? ?? const []).whereType<Map>()) {
      if (m['cameras'] == 2) return (m['monthly'] as num?)?.toInt() ?? 500;
    }
    return 500;
  }

  Future<void> _buy({required bool trial}) async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _note = '';
    });
    final r = await _buyer.buy(
        productId: _product,
        basePlanId: _base,
        offerId: trial ? '${_d?['trial_offer_id'] ?? ''}' : '',
        accountId: '${_d?['play_account_id'] ?? ''}');
    if (!mounted) return;
    if (r == CctvBuyStatus.done) {
      Navigator.of(context).pop(true); // back to the same screen, unlocked
      return;
    }
    setState(() {
      _busy = false;
      _note = switch (r) {
        CctvBuyStatus.pending => t.cplPending,
        CctvBuyStatus.cancelled => t.cplCancelled,
        CctvBuyStatus.unavailable => t.cplUnavailable,
        _ => t.cplFailed,
      };
    });
  }

  /// All CCTV camera counts / yearly / add-on — and from there all plans.
  void _allPlans() {
    final nav = Navigator.of(context);
    nav.pop(false);
    nav.push(MaterialPageRoute(builder: (_) => const CctvPlanScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final price = _playPrice;
    final taka = '৳${fmtInt(context, _baseTaka)}';
    final canBuy = _store && price != null && !_active;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: scheme.ds.primarySoft,
              child: Icon(Icons.videocam_rounded,
                  size: 28, color: scheme.ds.primaryInk),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(t.biCctvName,
                    key: const Key('bi-cctv-title'),
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          for (final b in [t.biCctvB1, t.biCctvB2, t.biCctvB3])
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check_circle_rounded,
                    size: 20, color: Brand.onTint(context, Brand.success)),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(b, style: AType.bodyMedium.copyWith(height: 1.35))),
              ]),
            ),
          const SizedBox(height: Gap.md),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_active)
            Text(t.biUnlocked,
                key: const Key('bi-cctv-active'),
                style: AType.bodyMedium.copyWith(
                    color: Brand.onTint(context, Brand.success),
                    fontWeight: FontWeight.w700))
          else ...[
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Text(t.payNetwork, style: AType.bodyMedium.copyWith(color: scheme.error)),
              ),
            // gap-cctv: a failed load can be tried again here
            if (_failed && _d == null)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: OutlinedButton.icon(
                  key: const Key('bi-cctv-retry'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t.retry),
                  onPressed: _busy ? null : _load,
                ),
              ),
            if (canBuy && _trial)
              FilledButton.icon(
                key: const Key('bi-cctv-trial'),
                onPressed: _busy ? null : () => _buy(trial: true),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.card_giftcard_rounded),
                label: Text(t.cplStartTrial, textAlign: TextAlign.center),
              ),
            if (canBuy) ...[
              const SizedBox(height: Gap.sm),
              if (_trial)
                OutlinedButton(
                  key: const Key('bi-cctv-buy'),
                  onPressed: _busy ? null : () => _buy(trial: false),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50)),
                  child: Text(t.biCctvPrice(price ?? ''), textAlign: TextAlign.center),
                )
              else
                FilledButton(
                  key: const Key('bi-cctv-buy'),
                  onPressed: _busy ? null : () => _buy(trial: false),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  child: Text(t.biCctvPrice(price ?? ''), textAlign: TextAlign.center),
                ),
              const SizedBox(height: Gap.xs),
              Text(t.biThenPlay(price ?? ''),
                  key: const Key('bi-cctv-then'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.ds.muted)),
              if (_trial)
                Text(t.biCctvTrialNote,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.ds.muted)),
            ] else
              // No Play client (website APK) / store price unknown: an honest
              // line + the plan screen (never a fake buy button).
              // gap-cctv: Play works but the plan is not on sale yet → say
              // "opens soon", not "bought through Google Play"
              Text(_store && _d != null && _d!['on_sale'] != true ? t.cplSaleSoon : t.biCctvNoStore(taka),
                  key: const Key('bi-cctv-nostore'),
                  style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.4)),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: Gap.sm),
                child: LinearProgressIndicator(),
              ),
            if (_note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(_note,
                    key: const Key('bi-cctv-note'),
                    style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
              ),
          ],
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const Key('bi-cctv-all-plans'),
            onPressed: _busy ? null : _allPlans,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(t.biCctvAllPlans, textAlign: TextAlign.center),
          ),
          TextButton(
            key: const Key('bi-cctv-not-now'),
            onPressed: () => Navigator.pop(context, _active),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(t.pv2NotNow),
          ),
        ],
      ),
    );
  }
}
