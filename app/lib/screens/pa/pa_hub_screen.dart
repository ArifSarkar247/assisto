import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'pa_schedule_screen.dart';
import 'visitor_filter_screen.dart';
import 'liaison_screen.dart';
import 'delegate_access_screen.dart';
import 'personal_tasks_screen.dart';

/// PA Secretary Mode hub (SPEC v2.1 §14 / §4 Work group) — the single sidebar
/// entry point for the six PA tools. Each tile reuses the destination screen's
/// own title getter so the hub carries ZERO new strings (no Bangla literals).
class PaHubScreen extends StatelessWidget {
  const PaHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    // The meeting brief (#104) is reached by selecting a meeting inside the
    // schedule (it needs a specific meeting), so it is not a standalone tile.
    final tools = <_PaTool>[
      _PaTool(Icons.calendar_month_outlined, t.paScheduleTitle,
          (_) => const PaScheduleScreen()),
      _PaTool(Icons.how_to_reg_outlined, t.paVisTitle,
          (_) => const VisitorFilterScreen()),
      _PaTool(Icons.follow_the_signs_outlined, t.paLiaTitle,
          (_) => const LiaisonScreen()),
      _PaTool(Icons.checklist_outlined, t.paTasksTitle,
          (_) => const PersonalTasksScreen()),
      _PaTool(Icons.admin_panel_settings_outlined, t.paDelegateTitle,
          (_) => const DelegateAccessScreen()),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(t.sidebarPaSecretary)),
      body: ListView.separated(
        padding: const EdgeInsets.all(Gap.md),
        itemCount: tools.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (context, i) {
          final tool = tools[i];
          return Material(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: tool.build)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: Gap.md),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: Icon(tool.icon, color: cs.onPrimaryContainer),
                    ),
                    const SizedBox(width: Gap.md),
                    Expanded(
                      child: Text(tool.label,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                    Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PaTool {
  final IconData icon;
  final String label;
  final WidgetBuilder build;
  const _PaTool(this.icon, this.label, this.build);
}
