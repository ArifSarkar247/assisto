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
import 'board_pack_screen.dart';
import 'dept_update_screen.dart';
import 'vip_stakeholder_screen.dart';
import 'biz_travel_events_screen.dart';
import 'project_tracking_screen.dart';
import 'star_deals_screen.dart';
import 'pr_press_screen.dart';
import 'social_inbox_screen.dart';
import 'shoot_logistics_screen.dart';
import 'lifestyle_screen.dart';

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
      _PaTool(Icons.calendar_month_rounded, t.paScheduleTitle,
          (_) => const PaScheduleScreen()),
      _PaTool(Icons.how_to_reg_rounded, t.paVisTitle,
          (_) => const VisitorFilterScreen()),
      _PaTool(Icons.follow_the_signs_rounded, t.paLiaTitle,
          (_) => const LiaisonScreen()),
      _PaTool(Icons.checklist_rounded, t.paTasksTitle,
          (_) => const PersonalTasksScreen()),
      _PaTool(Icons.admin_panel_settings_rounded, t.paDelegateTitle,
          (_) => const DelegateAccessScreen()),
      // Key-gated layer (§14 #106/107/109/110/112/113/114) — deterministic mock
      // with honest "connect a key" seams; works fully with no key.
      _PaTool(Icons.contact_phone_rounded, t.paCeTitle,
          (_) => const CallEmailScreen()),
      _PaTool(Icons.mail_outline_rounded, t.paLetTitle,
          (_) => const LettersScreen()),
      _PaTool(Icons.folder_rounded, t.paFileTitle,
          (_) => const FilingScreen()),
      _PaTool(Icons.sticky_note_2_rounded, t.paMinTitle,
          (_) => const MeetingMinutesScreen()),
      _PaTool(Icons.flight_rounded, t.paTravelTitle,
          (_) => const PaTravelScreen()),
      _PaTool(Icons.receipt_long_rounded, t.paVoucherTitle,
          (_) => const ExpenseVoucherScreen()),
      _PaTool(Icons.insert_chart_rounded, t.paResearchTitle,
          (_) => const ResearchPrepScreen()),
      // Corporate tier (§14 #116-120).
      _PaTool(Icons.dashboard_customize_rounded, t.paBoardTitle,
          (_) => const BoardPackScreen()),
      _PaTool(Icons.summarize_rounded, t.paDeptTitle,
          (_) => const DeptUpdateScreen()),
      _PaTool(Icons.stars_rounded, t.paVipTitle,
          (_) => const VipStakeholderScreen()),
      _PaTool(Icons.business_center_rounded, t.paBizTitle,
          (_) => const BizTravelEventsScreen()),
      _PaTool(Icons.account_tree_rounded, t.paProjTitle,
          (_) => const ProjectTrackingScreen()),
      // Celebrity / star tier (§14 #121-125).
      _PaTool(Icons.handshake_rounded, t.starDealsTitle,
          (_) => const StarDealsScreen()),
      _PaTool(Icons.campaign_rounded, t.prPressTitle,
          (_) => const PrPressScreen()),
      _PaTool(Icons.forum_rounded, t.socialInboxTitle,
          (_) => const SocialInboxScreen()),
      _PaTool(Icons.movie_rounded, t.shootTitle,
          (_) => const ShootLogisticsScreen()),
      _PaTool(Icons.spa_rounded, t.lifestyleTitle,
          (_) => const LifestyleScreen()),
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
                    Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
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
