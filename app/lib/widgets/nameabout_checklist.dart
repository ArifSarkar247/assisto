import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'nameabout_sections.dart';

/// Assisto — DIY trademark checklist for the "About the name" ADVANCED surface
/// (SPEC v2.1 §21). The OWNER ticks off each real-world step (search BD DPDT,
/// search the Nice classes, check app stores / domains, consult an attorney).
///
/// HARD RULE: ZERO Bangla glyphs in this .dart file — item text comes either
/// from the server payload (already localised by the backend) or, when the
/// payload is empty, from ARB getters via `AppLocalizations`. Ticks are local,
/// ephemeral UI state only (nothing is persisted or sent anywhere) — this is a
/// self-help aid, NOT a record of clearance.
///
/// CRITICAL: ticking every box does NOT mean the name is cleared. A closing
/// reminder restates that only an attorney can advise; the surface never
/// claims clearance.
class NameAboutChecklist extends StatefulWidget {
  /// Server-supplied, pre-localised steps. When empty, local ARB steps are used
  /// so the checklist is never blank.
  final List<String> serverItems;
  const NameAboutChecklist({super.key, required this.serverItems});

  @override
  State<NameAboutChecklist> createState() => _NameAboutChecklistState();
}

class _NameAboutChecklistState extends State<NameAboutChecklist> {
  final Set<int> _done = {};

  List<String> _items(AppLocalizations t) {
    if (widget.serverItems.isNotEmpty) return widget.serverItems;
    // Fallback steps (used when the backend sends nothing) — kept in ARB.
    return [
      t.nameAboutStepDpdt,
      t.nameAboutStepClasses,
      t.nameAboutStepGlobal,
      t.nameAboutStepStores,
      t.nameAboutStepDomain,
      t.nameAboutStepAttorney,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final items = _items(t);
    final done = _done.length;
    final total = items.length;
    final progress = total == 0 ? 0.0 : done / total;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NameAboutSectionTitle(text: t.nameAboutChecklistLabel, icon: Icons.checklist_rtl),
      Text(t.nameAboutChecklistHint,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.45)),
      const SizedBox(height: Gap.sm),
      // Progress — honest: "n of m steps done", never "cleared".
      Row(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Text(t.nameAboutStepsProgress('$done', '$total'),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
      const SizedBox(height: Gap.sm),
      Card(
        child: Column(children: [
          for (var i = 0; i < items.length; i++)
            CheckboxListTile(
              value: _done.contains(i),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _done.add(i);
                } else {
                  _done.remove(i);
                }
              }),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(items[i], style: const TextStyle(height: 1.4)),
            ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      // Closing reminder — ticking all boxes is NOT clearance.
      Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.nameAboutChecklistDone,
                style: TextStyle(
                    fontSize: 12, height: 1.5, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    ]);
  }
}
