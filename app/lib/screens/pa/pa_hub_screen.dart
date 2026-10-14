import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'pa_schedule_screen.dart';
import 'visitor_filter_screen.dart';
import 'liaison_screen.dart';
import 'delegate_access_screen.dart';
import 'personal_tasks_screen.dart';
import 'call_email_screen.dart';
import 'letters_screen.dart';
import 'filing_screen.dart';
import 'meeting_minutes_screen.dart';
import 'pa_travel_screen.dart';
import 'expense_voucher_screen.dart';
import 'research_prep_screen.dart';

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
      // Key-gated layer (§14 #106/107/109/110/112/113/114) — deterministic mock
      // with honest "connect a key" seams; works fully with no key.
      _PaTool(Icons.contact_phone_outlined, t.paCeTitle,
          (_) => const CallEmailScreen()),
      _PaTool(Icons.mail_outline, t.paLetTitle,
          (_) => const LettersScreen()),
      _PaTool(Icons.folder_outlined, t.paFileTitle,
          (_) => const FilingScreen()),
      _PaTool(Icons.sticky_note_2_outlined, t.paMinTitle,
          (_) => const MeetingMinutesScreen()),
      _PaTool(Icons.flight_outlined, t.paTravelTitle,
          (_) => const PaTravelScreen()),
      _PaTool(Icons.receipt_long_outlined, t.paVoucherTitle,
          (_) => const ExpenseVoucherScreen()),
      _PaTool(Icons.insert_chart_outlined, t.paResearchTitle,
          (_) => const ResearchPrepScreen()),
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
