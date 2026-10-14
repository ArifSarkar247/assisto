// Expandable service card for the ADVANCED Government / Service Guide.
// Renders one GuideService as a how-to card: steps, required-documents
// checklist, fee (always with a "verify on portal" chip), where/office,
// processing time, the official link, common mistakes, and a source +
// disclaimer footer. Includes a bookmark toggle and a "what do I need" button
// that opens the checklist-only sheet.
//
// All user-facing copy comes from AppLocalizations (t.guide*). The only text
// rendered directly is server/cache CONTENT (localised bn/en by the backend),
// so there are no Bangla literals in this file.

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'guide_data.dart';

/// Opens [url] in the external browser if non-empty. Kept dependency-free:
/// uses url_launcher only if present via a late import at the call site; here
/// we expose a callback so the screen owns the launch (keeps this widget pure).
typedef GuideLaunch = void Function(String url);

class GuideServiceCard extends StatelessWidget {
  final GuideService service;
  final bool bookmarked;
  final VoidCallback onToggleBookmark;
  final GuideLaunch onOpenLink;
  final VoidCallback onWhatDoINeed;
  final bool initiallyExpanded;

  const GuideServiceCard({
    super.key,
    required this.service,
    required this.bookmarked,
    required this.onToggleBookmark,
    required this.onOpenLink,
    required this.onWhatDoINeed,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final meta = guideCatMeta(service.category);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        leading: Container(
          height: 42,
          width: 42,
          decoration: BoxDecoration(
            color: meta.tint.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(guideServiceIcon(service), color: meta.tint),
        ),
        title: Text(service.name,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
        subtitle: service.portal.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(service.portal,
                    style: TextStyle(fontSize: 12, color: scheme.primary)),
              ),
        trailing: IconButton(
          tooltip: bookmarked ? tr.guideRemoveBookmark : tr.guideSave,
          icon: Icon(bookmarked ? Icons.bookmark : Icons.bookmark_border,
              color: bookmarked ? scheme.primary : scheme.onSurfaceVariant),
          onPressed: onToggleBookmark,
        ),
        children: [
          // ---- quick actions row ----
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onWhatDoINeed,
                icon: const Icon(Icons.checklist_rtl, size: 18),
                label: Text(tr.guideWhatDoINeed,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (service.url.isNotEmpty) ...[
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => onOpenLink(service.url),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(tr.guideOfficialSite,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ]),
          const SizedBox(height: Gap.md),

          // ---- steps ----
          _Section(icon: Icons.format_list_numbered, title: tr.guideSteps),
          for (int i = 0; i < service.steps.length; i++)
            _StepRow(index: i + 1, text: service.steps[i]),

          // ---- required documents checklist ----
          if (service.docs.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            _Section(icon: Icons.fact_check_outlined, title: tr.guideRequiredDocs),
            for (final d in service.docs) _CheckRow(text: d),
          ],

          // ---- fee / office / time facts ----
          const SizedBox(height: Gap.md),
          _FactRow(
            icon: Icons.payments_outlined,
            label: tr.guideFees,
            value: service.fee,
            verifyNote: service.verifyFee ? tr.guideVerifyOnPortal : null,
            tint: scheme,
          ),
          if (service.office.isNotEmpty)
            _FactRow(
              icon: Icons.place_outlined,
              label: tr.guideWhereOffice,
              value: service.office,
              tint: scheme,
            ),
          if (service.time.isNotEmpty)
            _FactRow(
              icon: Icons.schedule_outlined,
              label: tr.guideProcessingTime,
              value: service.time,
              verifyNote: service.verifyTime ? tr.guideVerifyOnPortal : null,
              tint: scheme,
            ),

          // ---- common mistakes ----
          if (service.mistakes.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            _Section(
                icon: Icons.warning_amber_rounded,
                title: tr.guideCommonMistakes,
                tint: scheme.error),
            for (final m in service.mistakes)
              _BulletRow(text: m, color: scheme.error),
          ],

          // ---- source + disclaimer ----
          const SizedBox(height: Gap.md),
          _DisclaimerBox(
            source: service.source,
            disclaimer:
                service.disclaimer.isEmpty ? tr.guideDisclaimer : service.disclaimer,
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color? tint;
  const _Section({required this.icon, required this.title, this.tint});
  @override
  Widget build(BuildContext context) {
    final c = tint ?? Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Row(children: [
        Icon(icon, size: 17, color: c),
        const SizedBox(width: Gap.sm),
        Text(title,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: c)),
      ]),
    );
  }
}

class _StepRow extends StatelessWidget {
  final int index;
  final String text;
  const _StepRow({required this.index, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          height: 22,
          width: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Text('$index',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
        ),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ]),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String text;
  const _CheckRow({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.check_circle_outline, size: 18, color: scheme.secondary),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ]),
    );
  }
}

class _BulletRow extends StatelessWidget {
  final String text;
  final Color color;
  const _BulletRow({required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Icon(Icons.circle, size: 6, color: color),
        ),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ]),
    );
  }
}

class _FactRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? verifyNote;
  final ColorScheme tint;
  const _FactRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.tint,
    this.verifyNote,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: tint.onSurfaceVariant),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: tint.onSurfaceVariant)),
            const SizedBox(height: 1),
            Text(value, style: const TextStyle(height: 1.3)),
            if (verifyNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(children: [
                  Icon(Icons.verified_outlined, size: 13, color: tint.tertiary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(verifyNote!,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontStyle: FontStyle.italic,
                            color: tint.tertiary)),
                  ),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _DisclaimerBox extends StatelessWidget {
  final String source;
  final String disclaimer;
  const _DisclaimerBox({required this.source, required this.disclaimer});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (source.isNotEmpty)
          Text(source,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
        if (source.isNotEmpty) const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(disclaimer,
                style: TextStyle(
                    fontSize: 12, height: 1.35, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ]),
    );
  }
}
