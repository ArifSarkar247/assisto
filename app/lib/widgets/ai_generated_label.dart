import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// aifinal (owner AI order 3 Nov 23:15, PART 6): the small "AI generated ·
/// general information" line under every AI answer (chat + photo answers).
/// Not shown under the free offline (Brain) answers, which are not AI.
class AiGeneratedLabel extends StatelessWidget {
  const AiGeneratedLabel({super.key});

  static bool shows(Map<String, dynamic> meta, String? source) =>
      meta['ai_generated'] == true || (source ?? meta['source']) == 'ai';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.auto_awesome_rounded, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(t.aiGenLabel,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}
