// P3 — non-blocking scam warning shown UNDER an incoming message. The check
// ran on this phone (scam_guard.dart); nothing was sent anywhere.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'scam_guard.dart';
import 'package:assisto/widgets/app_sheet.dart';

String scamReasonTitle(AppLocalizations t, ScamReason r) => switch (r) {
      ScamReason.otpRequest => t.p3ScamOtpTitle,
      ScamReason.mfsAgent => t.p3ScamMfsTitle,
      ScamReason.prize => t.p3ScamPrizeTitle,
      ScamReason.lookalikeLink => t.p3ScamLinkTitle,
      ScamReason.urgentMoney => t.p3ScamMoneyTitle,
    };

String scamReasonWhy(AppLocalizations t, ScamReason r, String domain) => switch (r) {
      ScamReason.otpRequest => t.p3ScamOtpWhy,
      ScamReason.mfsAgent => t.p3ScamMfsWhy,
      ScamReason.prize => t.p3ScamPrizeWhy,
      ScamReason.lookalikeLink => t.p3ScamLinkWhy(domain),
      ScamReason.urgentMoney => t.p3ScamMoneyWhy,
    };

class ScamWarningBanner extends StatelessWidget {
  final ScamVerdict verdict;
  final bool alignRight;
  const ScamWarningBanner({super.key, required this.verdict, this.alignRight = false});

  void _why(BuildContext context) {
    final t = AppLocalizations.of(context);
    showAppSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.p3ScamWhyTitle, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: Gap.md),
              for (final r in verdict.reasons) ...[
                Text(scamReasonTitle(t, r),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xs),
                Text(scamReasonWhy(t, r, verdict.domain)),
                const SizedBox(height: Gap.md),
              ],
              Text(t.p3ScamWhatToDo, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Text(t.p3ScamAdvice),
              const SizedBox(height: Gap.md),
              Text(t.p3ScamOnDevice,
                  style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ink = AssistoTokens.of(context).warning; // a11y1: AA on the amber tint
    final w = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: const ValueKey('p3-scam-banner'),
        constraints: BoxConstraints(maxWidth: w * 0.86),
        margin: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xs),
        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.xs, Gap.xs),
        decoration: BoxDecoration(
          color: Brand.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: Brand.warning.withValues(alpha: 0.6)),
        ),
        child: Row(
          children: [
            Icon(Icons.gpp_maybe_rounded, size: 18, color: ink),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(
                verdict.reasons.length == 1
                    ? scamReasonTitle(t, verdict.reasons.first)
                    : t.p3ScamMaybe,
                style: TextStyle(color: ink, fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () => _why(context),
              style: TextButton.styleFrom(foregroundColor: ink, minimumSize: const Size(48, 36)),
              child: Text(t.p3ScamWhy),
            ),
          ],
        ),
      ),
    );
  }
}
