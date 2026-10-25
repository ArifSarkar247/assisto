import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import 'onb_common.dart';
import 'onb_role.dart';

/// Which real feature a first-win tile opens. The onboarding screen owns the
/// actual Navigator.push (it holds the screen imports); this enum just carries
/// the intent so the widget stays screen-agnostic and testable.
enum OnbWin { medicine, bill, journey, expense }

/// The <60s "wow": one quick, REAL task tailored to the chosen role. Tapping a
/// tile marks onboarding done and opens the live screen — the win is genuine,
/// not simulated. The recommended tile (per role) floats to the top with a
/// "Recommended for you" badge (mirrors parent_link.first_win_for_role).
class OnbFirstWin extends StatelessWidget {
  final OnbRole? role;
  final ValueChanged<OnbWin> onPick;
  const OnbFirstWin({super.key, required this.role, required this.onPick});

  /// The recommended first win for the chosen role (mirrors the backend).
  /// play-nomed: no medicine first-win in the Play flavour; parents/family
  /// get Safe Journey (a real, non-medical family task) instead.
  OnbWin get _recommended {
    final r = _roleRecommended;
    return (r == OnbWin.medicine && !kMedicalFeaturesAllowed)
        ? OnbWin.journey
        : r;
  }

  OnbWin get _roleRecommended => switch (role) {
        OnbRole.parent => OnbWin.medicine,
        OnbRole.family => OnbWin.medicine,
        OnbRole.business => OnbWin.bill,
        OnbRole.self => OnbWin.journey,
        null => OnbWin.medicine,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);

    final all = <(OnbWin, IconData, String, String)>[
      if (kMedicalFeaturesAllowed)
        (
          OnbWin.medicine,
          Icons.medication_rounded,
          t.onbWinMedicineTitle,
          t.onbWinMedicineSub
        ),
      (
        OnbWin.bill,
        Icons.receipt_long_rounded,
        t.onbWinBillTitle,
        t.onbWinBillSub
      ),
      (
        OnbWin.journey,
        Icons.directions_walk_rounded,
        t.onbWinJourneyTitle,
        t.onbWinJourneySub
      ),
      (
        OnbWin.expense,
        Icons.payments_rounded,
        t.onbWinExpenseTitle,
        t.onbWinExpenseSub
      ),
    ];

    // Recommended first, then the rest in their natural order.
    final rec = _recommended;
    all.sort((a, b) {
      if (a.$1 == rec) return -1;
      if (b.$1 == rec) return 1;
      return 0;
    });

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        OnbHeader(
          icon: Icons.bolt_rounded,
          title: t.onbFirstWinTitle,
          subtitle: t.onbFirstWinSub,
          iconSize: 72,
        ),
        const SizedBox(height: Gap.xl),
        for (final w in all)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: OnbChoiceTile(
              icon: w.$2,
              title: w.$3,
              subtitle: w.$4,
              badge: w.$1 == rec ? t.onbRecommendedForYou : null,
              onTap: () => onPick(w.$1),
            ),
          ),
      ],
    );
  }
}
