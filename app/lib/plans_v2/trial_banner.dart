import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'plans_v2.dart';

/// plans-v2: "Business trial ends on 3 Nov — then it returns to Free;
/// nothing is charged." Self-loading; renders nothing unless plans-v2 is ON
/// and a trial is running (so the flag-off app is unchanged).
class PlansV2TrialBanner extends StatefulWidget {
  /// Tests / gallery: a ready state (skips the network).
  final PlansV2State? state;
  const PlansV2TrialBanner({super.key, this.state});
  @override
  State<PlansV2TrialBanner> createState() => _PlansV2TrialBannerState();
}

class _PlansV2TrialBannerState extends State<PlansV2TrialBanner> {
  PlansV2State _s = PlansV2State.off;

  @override
  void initState() {
    super.initState();
    if (widget.state != null) {
      _s = widget.state!;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final s = await loadPlansV2(context.read<AppState>().api);
        if (mounted) setState(() => _s = s);
      });
    }
  }

  @override
  void didUpdateWidget(PlansV2TrialBanner old) {
    super.didUpdateWidget(old);
    final s = widget.state;
    if (s != null && !identical(s, old.state)) _s = s;
  }

  @override
  Widget build(BuildContext context) {
    final until = _s.trialUntil;
    if (!_s.on || !_s.trialActive || until == null) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final date = trialDate(context, until);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Container(
        key: const Key('pv2-trial-banner'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.card_giftcard_rounded, color: scheme.onPrimaryContainer),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(t.pv2TrialBanner(planName(t, _s.trialPlan), date),
                style: TextStyle(color: scheme.onPrimaryContainer, height: 1.35)),
          ),
        ]),
      ),
    );
  }
}
