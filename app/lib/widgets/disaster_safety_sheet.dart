import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'disaster_model.dart';

/// Bottom sheet: source-noted "what to do" safety steps for ONE disaster kind.
/// Steps come from the server (disaster.safety_steps, source-noted — condensed
/// from DDM / BDRCS / BMD) and always carry the emergency hotlines. Never a
/// promise of safety.
class DisasterSafetySheet extends StatelessWidget {
  final String kind;
  final List<String> steps;
  final String source;
  const DisasterSafetySheet({
    super.key,
    required this.kind,
    required this.steps,
    required this.source,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(dKindIcon(kind), color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.disStepsTitle(dKindLabel(context, kind)),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: steps.length,
              separatorBuilder: (_, __) => const SizedBox(height: Gap.xs),
              itemBuilder: (context, i) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 11,
                    backgroundColor: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    child: Text(dNum(context, i + 1),
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(steps[i], style: const TextStyle(height: 1.4)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          if (source.isNotEmpty)
            Text(t.disSourceLine(source),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Text(t.disNotSafetyGuarantee,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
