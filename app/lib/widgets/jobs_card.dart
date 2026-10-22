import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'jobs_store.dart';
import 'subs_common.dart' show fmtInt;

/// A single job row for the Discover / Saved lists — match score, title/company,
/// quick facts (location · type · salary) and a bookmark toggle. Taps open the
/// detail sheet. Labels come from the ARB bundle (no Bangla literals).
class JobsCard extends StatelessWidget {
  final Map<String, dynamic> job;
  final bool saved;
  final VoidCallback onTap;
  final VoidCallback onToggleSave;
  const JobsCard({
    super.key,
    required this.job,
    required this.saved,
    required this.onTap,
    required this.onToggleSave,
  });

  String _typeLabel(AppLocalizations tr, String? k) => {
        'full_time': tr.jobsTypeFullTime, 'part_time': tr.jobsTypePartTime,
        'contract': tr.jobsTypeContract, 'remote': tr.jobsTypeRemote,
        'internship': tr.jobsTypeInternship,
      }[k] ?? '';

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final score = (job['match_score'] ?? 0) as int;
    final company = (job['company'] ?? '').toString();
    final location = (job['location'] ?? '').toString();
    final type = _typeLabel(tr, job['job_type'] as String?);
    final salary = job['salary'];
    final facts = <String>[
      if (location.isNotEmpty) location,
      if (type.isNotEmpty) type,
      // qa1: "45000" -> "45,000" / Bangla digits
      if (salary is num) tr.jobsSalaryBdt(fmtInt(context, salary.toInt())),
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Match score — high-contrast; a 0 score reads as "—" rather than a fake number.
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: score >= 70
                    ? scheme.primaryContainer
                    : score >= 40
                        ? scheme.tertiaryContainer
                        : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(score > 0 ? '$score' : '—',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: score >= 70
                          ? scheme.onPrimaryContainer
                          : score >= 40
                              ? scheme.onTertiaryContainer
                              : scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${job['title'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (company.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(company,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  Wrap(spacing: Gap.sm, runSpacing: 4, children: [
                    for (final f in facts)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(f, style: TextStyle(fontSize: 11.5, color: scheme.onSurface)),
                      ),
                  ]),
                ],
              ]),
            ),
            IconButton(
              icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border,
                  color: saved ? scheme.primary : scheme.onSurfaceVariant),
              tooltip: saved ? tr.jobsRemoveSaved : tr.jobsSaveJob,
              onPressed: onToggleSave,
            ),
          ]),
        ),
      ),
    );
  }
}

/// A compact stage badge used on tracker cards. Colour-coded with WCAG-safe
/// container/on-container pairs; label from ARB.
class StageBadge extends StatelessWidget {
  final String status;
  const StageBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = {
      kStageMatched: tr.jobsStageMatched,
      kStageSaved: tr.jobsStageSaved,
      kStageApplied: tr.jobsStageApplied,
      kStageInterview: tr.jobsStageInterview,
      kStageOffer: tr.jobsStageOffer,
      kStageRejected: tr.jobsStageRejected,
      kStageWithdrawn: tr.jobsStageWithdrawn,
    }[status] ?? status;

    late final Color bg, fg;
    switch (status) {
      case kStageOffer:
        bg = scheme.primaryContainer; fg = scheme.onPrimaryContainer; break;
      case kStageInterview:
        bg = scheme.tertiaryContainer; fg = scheme.onTertiaryContainer; break;
      case kStageRejected:
      case kStageWithdrawn:
        bg = scheme.errorContainer; fg = scheme.onErrorContainer; break;
      default:
        bg = scheme.secondaryContainer; fg = scheme.onSecondaryContainer;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}
