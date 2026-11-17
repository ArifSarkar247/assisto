import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/plans_screen.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/home_hero.dart' show CompactAdFrame;
import 'ad_control.dart';
import 'ad_rules.dart';
import 'ads_service.dart';
import 'hero_ad.dart';
import 'hero_binding.dart';
import 'ad_block_context.dart' show AdBlockGate;

/// adcontrol (owner 10 Nov 03:45) — ONE in-page native ad card for a
/// registered placement ([AdControl]): the Account & Finance main page,
/// reports bottom, All Services, the after-call review card, or a card
/// between list rows (one every 15–20 rows, [AdControl.listNativeAfter]).
///
/// Shows only when the owner's switch for [placement] is on with type
/// "native" (Owner Admin -> Ad control), for a Free user. Before / without a
/// fill, for Premium / Plus / Business, or when switched off it takes NO
/// space (never a gap, never a dead box). The "Ad" label and "Remove ads"
/// link sit OUTSIDE the ad ([CompactAdFrame]). Lazy: nothing loads before
/// the card's first frame; any failure is "no card". Never throws.
class AdSpotCard extends StatefulWidget {
  const AdSpotCard(
      {super.key, required this.placement, this.padding, this.onResult});

  /// A registry key whose allowed types include native.
  final String placement;
  final EdgeInsetsGeometry? padding;

  /// adwire: called ONCE when the card knows its fate — true = an ad is
  /// showing, false = no ad (off, paid plan, no fill, timeout, error). The
  /// after-call screen keeps itself open until this arrives.
  final ValueChanged<bool>? onResult;

  /// adcontrol list native: [row] alone, or [row] + one native card when
  /// row [i] (of [count]) is the N-th row (N = the owner's 15–20,
  /// [AdControl.listNativeAfter]). Never after the last row.
  static Widget afterRow(int i, int count, String placement, Widget row) {
    final every = AdsService.instance.config.control.listNativeEvery;
    if (!AdControl.listNativeAfter(count, every).contains(i)) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [row, AdSpotCard(placement: placement)],
    );
  }

  @visibleForTesting
  static HeroAdBridge? debugBridge;
  @visibleForTesting
  static Future<AdConfig> Function()? debugLoadConfig;

  @override
  State<AdSpotCard> createState() => _AdSpotCardState();
}

class _AdSpotCardState extends State<AdSpotCard> {
  HeroAdHandle? _ad;
  bool _loading = false;

  late final HeroAdBridge _bridge = AdSpotCard.debugBridge ??
      createHeroAdBridge(placement: 'native_${widget.placement}');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    try {
      _ad?.dispose();
    } catch (_) {}
    super.dispose();
  }

  Future<AdConfig> _config() async {
    final f = AdSpotCard.debugLoadConfig;
    if (f != null) return f();
    return AdsService.instance.configFor(context.read<AppState>());
  }

  bool _loggedIn() {
    if (AdSpotCard.debugLoadConfig != null) return true;
    try {
      return context.read<AppState>().loggedIn;
    } catch (_) {
      return false;
    }
  }

  bool _reported = false;

  void _report(bool shown) {
    if (_reported) return;
    _reported = true;
    try {
      widget.onResult?.call(shown);
    } catch (_) {}
  }

  Future<void> _load() async {
    if (!mounted || _loading || _ad != null) return;
    _loading = true;
    try {
      if (!_bridge.linked) return;
      final cfg = await _config();
      if (!mounted) return;
      final d = AdControl.decide(widget.placement, AdKind.native, cfg,
          loggedIn: _loggedIn());
      if (!d.allowed) return;
      final unit = cfg.unitFor(AdKind.native, builtAppId: AdsService.builtAppId);
      if (unit == null) return;
      final ad = await _bridge
          .load(unit, startMuted: true)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      if (!mounted) {
        try {
          ad?.dispose();
        } catch (_) {}
        return;
      }
      if (ad != null) {
        setState(() => _ad = ad);
        _report(true);
      }
    } catch (_) {
      // an ad problem never reaches the page
    } finally {
      _loading = false;
      if (mounted) _report(false); // no-op when already reported true
    }
  }

  void _openPlans() =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlansScreen()));

  // ads-guard: the whole slot (frame + "Remove ads") disappears at once on
  // a call / safety screen / plan change
  @override
  Widget build(BuildContext context) =>
      AdBlockGate(child: Builder(builder: _buildSlot));

  Widget _buildSlot(BuildContext context) {
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    return Padding(
      key: ValueKey('ad-spot-${widget.placement}'),
      padding: widget.padding ??
          const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: CompactAdFrame(onRemoveAds: _openPlans, child: ad.view()),
    );
  }
}
