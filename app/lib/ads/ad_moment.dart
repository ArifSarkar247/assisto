import 'package:flutter/widgets.dart';

import 'ad_placements.dart';

/// adcontrol (owner 10 Nov 03:45): fires ONE owner-approved transition
/// interstitial ([AdExit.transition]) the first time [child] is shown — the
/// month-end full report of Account & Finance or Mess. Every global rule
/// still applies (Free only, the owner's switch, >= 3 min gap, daily cap,
/// none on the first day of use, accidental-tap guard). Shows nothing itself.
class AdMomentOnShow extends StatefulWidget {
  const AdMomentOnShow({super.key, required this.placement, required this.child});

  final AdExitPlacement placement;
  final Widget child;

  @override
  State<AdMomentOnShow> createState() => _AdMomentOnShowState();
}

class _AdMomentOnShowState extends State<AdMomentOnShow> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AdExit.transition(widget.placement);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
