import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// GPA/grade explainer + a countdown chip (SPEC v2.1 §21, ADVANCED).
///
/// IMPORTANT: none of this is a student's result. The grade table is the
/// board's PUBLIC scale (identical for everyone), and the GPA "band" only
/// interprets a number the USER typed from their own slip. We never produce,
/// infer, or pre-fill a result.
///
/// Mirrors core.logic.exam.grade_scale / explain_gpa / countdown.

/// The standard BD board grade scale (mirrors exam.GRADE_SCALE).
const List<Map<String, String>> kGradeScale = [
  {'grade': 'A+', 'gp': '5.00', 'marks': '80–100'},
  {'grade': 'A', 'gp': '4.00', 'marks': '70–79'},
  {'grade': 'A-', 'gp': '3.50', 'marks': '60–69'},
  {'grade': 'B', 'gp': '3.00', 'marks': '50–59'},
  {'grade': 'C', 'gp': '2.00', 'marks': '40–49'},
  {'grade': 'D', 'gp': '1.00', 'marks': '33–39'},
  {'grade': 'F', 'gp': '0.00', 'marks': '0–32'},
];

/// Band label for a USER-TYPED GPA. Returns null for blank/invalid/out-of-range
/// input (mirrors exam.explain_gpa).
String? gpaBand(AppLocalizations t, String gpa) {
  final v = double.tryParse(gpa.trim());
  if (v == null || v < 0 || v > 5) return null;
  if (v >= 5.0) return t.examBandOutstanding;
  if (v >= 4.0) return t.examBandVeryGood;
  if (v >= 3.0) return t.examBandGood;
  if (v >= 2.0) return t.examBandSatisfactory;
  if (v >= 1.0) return t.examBandPassed;
  return t.examBandDidNotPass;
}

/// Expandable public grade-scale table + an optional interpretation of the
/// user's own typed GPA.
class ExamGpaExplainer extends StatelessWidget {
  final String enteredGpa;
  const ExamGpaExplainer({super.key, this.enteredGpa = ''});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final band = gpaBand(t, enteredGpa);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // interpretation of the user's own value (only if they typed one)
          if (band != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                t.examYourGpaBand(enteredGpa.trim(), band),
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: Gap.sm),
          ],
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(t.examGradeScaleTitle,
                  style: Theme.of(context).textTheme.titleSmall),
              children: [
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(1),
                    1: FlexColumnWidth(1),
                    2: FlexColumnWidth(1.4),
                  },
                  children: [
                    TableRow(children: [
                      _h(context, t.examColGrade),
                      _h(context, t.examColGp),
                      _h(context, t.examColMarks),
                    ]),
                    for (final r in kGradeScale)
                      TableRow(children: [
                        _c(r['grade']!),
                        _c(r['gp']!),
                        _c(r['marks']!),
                      ]),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                Text(t.examGradeScaleNote,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _h(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(s,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
      );

  Widget _c(String s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(s, style: const TextStyle(fontSize: 12.5)),
      );
}

/// A countdown chip to the expected result date (mirrors exam.countdown).
/// Shows nothing useful past the date — the screen switches to the
/// traffic-spike + check-official flow then.
class ExamCountdownChip extends StatelessWidget {
  final DateTime expected;
  const ExamCountdownChip({super.key, required this.expected});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final secs = expected.difference(now).inSeconds;
    final String label;
    if (secs <= 0) {
      label = t.examCountdownDue;
    } else {
      final totalH = secs ~/ 3600;
      final days = totalH ~/ 24;
      final hours = totalH % 24;
      label = t.examCountdownLeft(days, hours);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.hourglass_bottom_rounded, size: 16, color: Colors.white),
        const SizedBox(width: Gap.xs),
        Text(label,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
      ]),
    );
  }
}
