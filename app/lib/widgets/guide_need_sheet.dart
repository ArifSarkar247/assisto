// "What do I need for X" bottom sheet for the ADVANCED Service Guide.
// A focused, scannable checklist: the required documents, the fee (with a
// verify-on-portal chip), the office, the processing time and the official
// link — the answer to "I just want to know what to bring".
//
// All labels come from AppLocalizations; only server/cache CONTENT is rendered
// directly, so no Bangla literals live here.

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'guide_data.dart';

Future<void> showGuideNeedSheet(
  BuildContext context,
  GuideService service, {
  required void Function(String url) onOpenLink,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _GuideNeedSheet(service: service, onOpenLink: onOpenLink),
  );
}

class _GuideNeedSheet extends StatelessWidget {
  final GuideService service;
  final void Function(String url) onOpenLink;
  const _GuideNeedSheet({required this.service, required this.onOpenLink});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final meta = guideCatMeta(service.category);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
            Gap.lg + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(guideServiceIcon(service), color: meta.tint),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(tr.guideWhatYouNeedFor(service.name),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ]),
            const SizedBox(height: Gap.md),

            if (service.docs.isEmpty)
              Text(tr.guideNoDocsListed,
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else ...[
              Text(tr.guideRequiredDocs,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              const SizedBox(height: Gap.xs),
              for (final d in service.docs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.check_circle_outline_rounded, size: 18, color: scheme.secondary),
                    const SizedBox(width: Gap.md),
                    Expanded(child: Text(d, style: const TextStyle(height: 1.35))),
                  ]),
                ),
            ],

            const SizedBox(height: Gap.md),
            _KV(label: tr.guideFees, value: service.fee,
                verify: service.verifyFee ? tr.guideVerifyOnPortal : null, scheme: scheme),
            if (service.office.isNotEmpty)
              _KV(label: tr.guideWhereOffice, value: service.office, scheme: scheme),
            if (service.time.isNotEmpty)
              _KV(label: tr.guideProcessingTime, value: service.time,
                  verify: service.verifyTime ? tr.guideVerifyOnPortal : null, scheme: scheme),

            const SizedBox(height: Gap.md),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    service.disclaimer.isEmpty ? tr.guideDisclaimer : service.disclaimer,
                    style: TextStyle(fontSize: 12, height: 1.35, color: scheme.onSurfaceVariant)),
              ),
            ]),

            if (service.url.isNotEmpty) ...[
              const SizedBox(height: Gap.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onOpenLink(service.url);
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(tr.guideOfficialSite),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _KV extends StatelessWidget {
  final String label;
  final String value;
  final String? verify;
  final ColorScheme scheme;
  const _KV({required this.label, required this.value, required this.scheme, this.verify});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
        Text(value, style: const TextStyle(height: 1.3)),
        if (verify != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              Icon(Icons.verified_rounded, size: 13, color: scheme.tertiary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(verify!,
                    style: TextStyle(
                        fontSize: 11.5, fontStyle: FontStyle.italic, color: scheme.tertiary)),
              ),
            ]),
          ),
      ]),
    );
  }
}
