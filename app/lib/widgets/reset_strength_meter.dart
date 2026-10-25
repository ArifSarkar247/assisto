import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Password strength scoring + meter (SPEC v2.1 §21, account recovery ADVANCED).
///
/// Pure, UI-only scoring that MIRRORS the backend rule in `backend/core/reset.py`
/// (`validate_password` / `score_password`): min 8 chars AND a mix of letters and
/// numbers is the floor; symbols / length push the score up. The meter never
/// blocks typing — it coaches. The backend is still the authority on confirm;
/// this is a fast, offline hint so people fix weak passwords before submitting.
///
/// Zero Bangla lives here: every human string comes from `AppLocalizations`.
enum PwStrength { empty, weak, fair, good, strong }

class PwScore {
  final PwStrength level;

  /// 0..1 bar fill.
  final double fraction;
  const PwScore(this.level, this.fraction);

  /// Backend floor: >= 8 chars AND not all-letters / all-digits.
  bool get meetsFloor => level.index >= PwStrength.fair.index;

  static PwScore of(String pw) {
    if (pw.isEmpty) return const PwScore(PwStrength.empty, 0);
    final hasLower = pw.contains(RegExp(r'[a-z]'));
    final hasUpper = pw.contains(RegExp(r'[A-Z]'));
    final hasDigit = pw.contains(RegExp(r'[0-9]'));
    final hasSymbol = pw.contains(RegExp(r'[^A-Za-z0-9]'));
    final longEnough = pw.length >= 8;
    final veryLong = pw.length >= 12;

    // Backend floor mirror: must be >= 8 chars AND mix letters + numbers.
    final mixesLettersDigits = (hasLower || hasUpper) && hasDigit;
    if (!longEnough || !mixesLettersDigits) {
      // Below the floor the backend will reject — show "weak" but keep a hint
      // of progress so the bar moves as the user types.
      final frac = (pw.length.clamp(0, 8) / 8) * 0.25;
      return PwScore(PwStrength.weak, frac.clamp(0.08, 0.25));
    }
    var classes = 0;
    if (hasLower) classes++;
    if (hasUpper) classes++;
    if (hasDigit) classes++;
    if (hasSymbol) classes++;
    // At the floor: fair. Reward length + character variety beyond it.
    if (veryLong && classes >= 3) return const PwScore(PwStrength.strong, 1.0);
    if ((veryLong && classes >= 2) || (longEnough && classes >= 3)) {
      return const PwScore(PwStrength.good, 0.75);
    }
    return const PwScore(PwStrength.fair, 0.5);
  }
}

class ResetStrengthMeter extends StatelessWidget {
  final String password;
  const ResetStrengthMeter({super.key, required this.password});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final score = PwScore.of(password);
    if (score.level == PwStrength.empty) {
      // Empty state: just the coaching hint, no bar.
      return Text(t.resetStrengthHint,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant));
    }
    final (label, color) = switch (score.level) {
      PwStrength.weak => (t.resetStrengthWeak, scheme.error),
      PwStrength.fair => (t.resetStrengthFair, Colors.orange.shade800),
      PwStrength.good => (t.resetStrengthGood, Colors.teal.shade700),
      PwStrength.strong => (t.resetStrengthStrong, Colors.green.shade700),
      PwStrength.empty => (t.resetStrengthHint, scheme.onSurfaceVariant),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          // WCAG: strength is announced, not conveyed by colour alone.
          label: t.resetStrengthSemantics(label),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: score.fraction,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              score.meetsFloor
                  ? Icons.check_circle_outline_rounded
                  : Icons.info_outline_rounded,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$label — ${score.meetsFloor ? t.resetStrengthOkFloor : t.resetStrengthBelowFloor}',
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
