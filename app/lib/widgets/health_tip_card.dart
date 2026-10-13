import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// One health tip: title, body, and a NAMED source chip (DGHS / WHO). The
/// source is always shown so the guidance is attributable and trustworthy.
class HealthTipCard extends StatelessWidget {
  final Map<String, dynamic> tip;
  const HealthTipCard({super.key, required this.tip});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = (tip['title'] ?? '').toString();
    final body = (tip['body'] ?? '').toString();
    final sourceName = (tip['source_name'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),
          if (sourceName.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Row(children: [
              Icon(Icons.verified_outlined, size: 14, color: scheme.secondary),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.healthTipSourceLine(sourceName),
                    style: TextStyle(fontSize: 11, color: scheme.secondary)),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
