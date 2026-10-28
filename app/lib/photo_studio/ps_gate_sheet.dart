import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../payments/credits_out_sheet.dart'; // credout
import 'ps_export.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// The ONE funding sheet free users see before a full-quality export or a
/// paid AI run. Honest copy: N rewarded ads OR credits; a failed ad offers
/// retry or credits — never a free unlock.
class PsGateSheet extends StatelessWidget {
  const PsGateSheet({super.key, required this.need, this.forRun = false, this.onPremium});
  final GateNeed need;
  final bool forRun;
  final VoidCallback? onPremium;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // d1-photo (owner's build-202 dead end): with no ad network linked in
    // this build a "Watch ads" button could never succeed — show credits /
    // Premium only, plus the honest "ads aren't available yet" note.
    final adsPossible = need.adsRemaining > 0 && need.adsLinked;
    final adsBlocked = need.adsRemaining > 0 && !need.adsLinked;
    final n = fmtInt(context, need.adsRemaining);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                    gradient: Brand.gradient, shape: BoxShape.circle),
                child: const Icon(Icons.lock_open_rounded, color: Colors.white),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(forRun ? t.psGateRunTitle : t.psGateTitle,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: Gap.md),
            if (adsPossible)
              // qa1: plural-aware ("Watch 1 short ads" in English)
              Text(forRun
                      ? t.qa1PsGateRunBody(need.adsRemaining, n)
                      : t.qa1PsGateBody(need.adsRemaining, n),
                  style: Theme.of(context).textTheme.bodyLarge)
            else
              Text(need.reason == 'trial_used' ? t.psGateTrialUsed : t.psGateCreditsOnly,
                  style: Theme.of(context).textTheme.bodyLarge),
            if (adsPossible && need.adsTotal > 1) ...[
              const SizedBox(height: Gap.sm),
              Text(
                  t.psGateProgress(fmtInt(context, need.adsTotal - need.adsRemaining),
                      fmtInt(context, need.adsTotal)),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            if (need.lastAdFailed) ...[
              const SizedBox(height: Gap.md),
              _note(context, Icons.wifi_off_rounded, t.psAdUnavailable, Brand.warnInk(context)),
            ],
            if (adsBlocked) ...[
              const SizedBox(height: Gap.md),
              _note(context, Icons.info_outline_rounded, t.psGateAdsNotLinked, scheme.onSurfaceVariant),
            ],
            const SizedBox(height: Gap.lg),
            if (adsPossible)
              FilledButton.icon(
                key: const Key('psGateWatch'),
                onPressed: () => Navigator.of(context).pop(FundChoice.ads),
                icon: const Icon(Icons.play_circle_outline_rounded),
                label: Text(need.lastAdFailed ? t.psGateRetry : t.psGateWatch),
              ),
            if (need.credits != null) ...[
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                key: const Key('psGateCredits'),
                onPressed: () => Navigator.of(context).pop(FundChoice.credits),
                icon: const Icon(Icons.toll_rounded),
                label: Text(t.psGateUseCredits(fmtInt(context, need.credits!))),
              ),
            ],
            if (onPremium != null) ...[
              const SizedBox(height: Gap.sm),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  onPremium!();
                },
                icon: const Icon(Icons.workspace_premium_rounded),
                label: Text(t.psGatePremium),
              ),
            ],
            const SizedBox(height: Gap.sm),
            Text(t.psGateNoFillNote,
                textAlign: TextAlign.center,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _note(BuildContext context, IconData icon, String text, Color color) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: TextStyle(color: color))),
        ],
      );
}

/// [GateUi] backed by [PsGateSheet].
class SheetGateUi extends GateUi {
  SheetGateUi(this.context, {this.forRun = false, this.onPremium});
  final BuildContext context;
  final bool forRun;
  final VoidCallback? onPremium;

  @override
  Future<FundChoice?> chooseFunding(GateNeed need) {
    if (!context.mounted) return Future.value(null);
    return showAppSheet<FundChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PsGateSheet(need: need, forRun: forRun, onPremium: onPremium),
    );
  }

  @override
  Future<bool> outOfCredits() {
    if (!context.mounted) return Future.value(false);
    return CreditsOut.offer(context, screen: 'photo_studio', draftKept: true);
  }
}
