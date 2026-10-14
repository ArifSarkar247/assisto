import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'disaster_model.dart';

/// One active (or clearly-flagged SAMPLE) disaster warning. Shows severity by
/// colour AND label AND icon (never colour alone), the affected area, the
/// kind-specific metric chip (cyclone signal no. / m above danger level / heat
/// °C), a source note, and — for a sample — an explicit "example, not a live
/// warning" badge so it can NEVER be mistaken for a real alert. Actions:
/// what-to-do safety steps + share.
class DisasterWarningCard extends StatelessWidget {
  final DisasterWarning warning;
  final VoidCallback onSteps;
  final VoidCallback onShare;
  const DisasterWarningCard({
    super.key,
    required this.warning,
    required this.onSteps,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tint = dSevColor(warning.severity);
    final chip = warning.metricChip(context);

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // header: kind icon + title + severity pill
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: tint.withValues(alpha: 0.15),
              foregroundColor: tint,
              child: Icon(dKindIcon(warning.kind), size: 20),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  warning.title.isEmpty
                      ? dKindLabel(context, warning.kind)
                      : warning.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (warning.area.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(children: [
                      Icon(Icons.place_outlined,
                          size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(warning.area,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant)),
                      ),
                    ]),
                  ),
              ]),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          // severity + metric chips
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            _Pill(
              icon: Icons.priority_high,
              label: dSevLabel(context, warning.severity),
              color: tint,
              filled: true,
            ),
            if (chip != null)
              _Pill(icon: dKindIcon(warning.kind), label: chip, color: tint),
            if (warning.sample || !warning.isLive)
              _Pill(
                icon: Icons.science_outlined,
                label: t.disSampleBadge,
                color: scheme.onSurfaceVariant,
              ),
          ]),
          if (warning.text.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(warning.text,
                style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurface)),
          ],
          const SizedBox(height: Gap.sm),
          if (warning.source.isNotEmpty)
            Text(t.disSourceLine(warning.source),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Row(children: [
            FilledButton.tonalIcon(
              onPressed: onSteps,
              icon: const Icon(Icons.checklist_rtl, size: 18),
              label: Text(t.disWhatToDo),
            ),
            const SizedBox(width: Gap.sm),
            OutlinedButton.icon(
              onPressed: onShare,
              icon: const Icon(Icons.share_outlined, size: 18),
              label: Text(t.disShare),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool filled;
  const _Pill({
    required this.icon,
    required this.label,
    required this.color,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: fg),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}
