import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Lower-paywall trust block for the Plans screen (Section 21): an honest
/// "manage / cancel + billing" note, an annual-vs-monthly explainer, and a
/// short FAQ. All copy is strict (no hype) and bilingual via ARB — this is the
/// place where we are transparent about billing not being live yet, how to
/// cancel, and how annual compares to monthly.
///
/// `annualPlan` / `monthlyPremium` are the raw `plansPublic()` rows (may be
/// absent); when both are present we compute the honest yearly saving from the
/// REAL owner-set prices — we never invent or hardcode a price here.
class PlansFaq extends StatelessWidget {
  final Map<String, dynamic>? annualPlan;
  final Map<String, dynamic>? monthlyPremium;
  const PlansFaq({super.key, this.annualPlan, this.monthlyPremium});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Annual vs monthly — computed from real prices, shown only if we can.
      if (_savingLine(t) != null) ...[
        _noteCard(
          scheme,
          icon: Icons.calendar_month_rounded,
          title: t.plansAnnualVsMonthlyTitle,
          body: _savingLine(t)!,
        ),
        const SizedBox(height: Gap.md),
      ],

      // Manage / cancel + billing honesty.
      _noteCard(
        scheme,
        icon: Icons.receipt_long_rounded,
        title: t.plansManageTitle,
        body: t.plansManageBody,
      ),
      const SizedBox(height: Gap.lg),

      Text(t.plansFaqTitle,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      const SizedBox(height: Gap.sm),
      _faq(t.plansFaqQCancelQ, t.plansFaqQCancelA),
      _faq(t.plansFaqQSafetyQ, t.plansFaqQSafetyA),
      _faq(t.plansFaqQSwitchQ, t.plansFaqQSwitchA),
      _faq(t.plansFaqQFamilyQ, t.plansFaqQFamilyA),
      _faq(t.plansFaqQPointsQ, t.plansFaqQPointsA),
      _faq(t.plansFaqQRefundQ, t.plansFaqQRefundA),
    ]);
  }

  /// Build the annual-vs-monthly saving sentence from REAL prices, or null if
  /// we can't (missing rows / different currencies / zero price).
  String? _savingLine(AppLocalizations t) {
    final a = annualPlan, m = monthlyPremium;
    if (a == null || m == null) return null;
    final ay = (a['price'] is num) ? (a['price'] as num).toDouble() : null;
    final mm = (m['price'] is num) ? (m['price'] as num).toDouble() : null;
    if (ay == null || mm == null || ay <= 0 || mm <= 0) return null;
    if ((a['cur'] ?? '') != (m['cur'] ?? '')) return null;
    final yearlyIfMonthly = mm * 12;
    final saved = yearlyIfMonthly - ay;
    if (saved <= 0) return null;
    final sign = (a['cur'] == 'USD') ? '\$' : '৳';
    return t.plansAnnualSaving('$sign${_fmt(ay)}', '$sign${_fmt(saved)}');
  }

  String _fmt(double n) {
    if (n == n.roundToDouble()) {
      final s = n.round().toString();
      final b = StringBuffer();
      for (int i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
        b.write(s[i]);
      }
      return b.toString();
    }
    return n.toStringAsFixed(2);
  }

  Widget _noteCard(ColorScheme scheme,
          {required IconData icon,
          required String title,
          required String body}) =>
      Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(body,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      );

  Widget _faq(String q, String a) => Theme(
        // Remove the default ExpansionTile divider lines for a cleaner look.
        data: ThemeData(dividerColor: Colors.transparent),
        child: Builder(builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: Gap.sm),
            title: Text(q,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(a,
                    style: TextStyle(
                        fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant)),
              ),
            ],
          );
        }),
      );
}
