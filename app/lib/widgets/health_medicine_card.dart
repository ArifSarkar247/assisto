import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// One medicine-DB record: brand + generic + strength + form + manufacturer +
/// indicative price + uses + how-to-take, with an expandable same-generic
/// alternatives list. EVERY alternative repeats the switch-warning.
class HealthMedicineCard extends StatelessWidget {
  final Map<String, dynamic> record;
  const HealthMedicineCard({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final brand = (record['brand'] ?? '').toString();
    final generic = (record['generic'] ?? '').toString();
    final strength = (record['strength'] ?? '').toString();
    final form = (record['form'] ?? '').toString();
    final manufacturer = (record['manufacturer'] ?? '').toString();
    final price = (record['price_display'] ?? '').toString();
    final uses = (record['uses'] ?? '').toString();
    final howTo = (record['how_to_take'] ?? '').toString();
    final switchWarning = (record['switch_warning'] ?? '').toString();
    final alternatives =
        ((record['alternatives'] ?? []) as List).cast<Map<String, dynamic>>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // brand + strength
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text('$brand  $strength'.trim(),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (price.isNotEmpty)
              Text(price, style: TextStyle(fontSize: 12, color: scheme.secondary)),
          ]),
          const SizedBox(height: Gap.xs),
          // generic + form + manufacturer
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _Chip(icon: Icons.science_outlined, text: generic),
            if (form.isNotEmpty) _Chip(icon: Icons.medication_outlined, text: form),
            if (manufacturer.isNotEmpty)
              _Chip(icon: Icons.factory_outlined, text: manufacturer),
          ]),
          if (uses.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            _Labeled(label: t.medicineDbUses, value: uses),
          ],
          if (howTo.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _Labeled(label: t.medicineDbHowToTake, value: howTo),
          ],
          // switch-warning on every record
          if (switchWarning.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: scheme.onErrorContainer),
                const SizedBox(width: Gap.xs),
                Expanded(child: Text(switchWarning,
                    style: TextStyle(fontSize: 11, color: scheme.onErrorContainer))),
              ]),
            ),
          ],
          // alternatives (same generic)
          if (alternatives.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(t.medicineDbAlternativesTitle(alternatives.length),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                children: [
                  for (final a in alternatives)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.swap_horiz, size: 18),
                      title: Text('${a['brand']}  ${a['strength']}'.trim()),
                      subtitle: Text(
                          '${a['manufacturer'] ?? ''}'
                          '${(a['price_display'] ?? '').toString().isNotEmpty ? ' · ${a['price_display']}' : ''}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.sm),
                    child: Text(t.medicineDbAlternativesNote,
                        style: TextStyle(fontSize: 11, color: scheme.error)),
                  ),
                ],
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Chip({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _Labeled extends StatelessWidget {
  final String label, value;
  const _Labeled({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(height: 1.4)),
    ]);
  }
}
