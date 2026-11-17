import 'package:flutter/material.dart';
import '../../ds/ds.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset; // lifebar
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
import 'ps_today_screen.dart'; // pssec
import '../../feature_flags.dart'; // pssec

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
      // pssec: the Personal Secretary "Today" page leads (flag ps_secretary;
      // hidden — never dead — while the flag is off).
      if (FeatureFlags.instance.isOn('ps_secretary'))
        _PaTool(Icons.wb_sunny_rounded, t.psecTodayTitle,
            (_) => const PsTodayScreen()),
      _PaTool.header(t.lbWPaGroupDaily),
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
      _PaTool.header(t.lbWPaGroupOffice),
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
      _PaTool.header(t.lbWPaGroupCompany),
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
      _PaTool.header(t.lbWPaGroupPublic),
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

    // group the tools into one DS group card per section; a tool before the
    // first header (the secretary's "Today" page) leads as the soft hero
    void open(WidgetBuilder b) =>
        Navigator.of(context).push(MaterialPageRoute(builder: b));
    _PaTool? lead;
    final sections = <(String, List<_PaTool>)>[];
    for (final tool in tools) {
      if (tool.build == null) {
        sections.add((tool.label, <_PaTool>[]));
      } else if (sections.isEmpty) {
        lead = tool;
      } else {
        sections.last.$2.add(tool);
      }
    }
    Widget icon(IconData i) => Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: cs.ds.primarySoft,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Icon(i, color: cs.ds.primaryInk),
        );
    final leadTool = lead;
    return Scaffold(
      appBar: AppBar(title: Text(t.sidebarPersonalSecretary)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          if (leadTool != null)
            DsHeroCard(
              onTap: () => open(leadTool.build!),
              child: Row(children: [
                icon(leadTool.icon),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Text(leadTool.label,
                      style: AType.titleLarge.copyWith(
                          color: cs.ds.text, fontWeight: FontWeight.w800)),
                ),
                Icon(Icons.chevron_right_rounded, color: cs.ds.muted),
              ]),
            ),
          for (final (i, sec) in sections.indexed) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Gap.xs, (i == 0 && leadTool == null) ? 0 : Gap.lg, Gap.xs, Gap.sm),
              child: Semantics(
                header: true,
                child: Text(sec.$1,
                    style: AType.titleSmall.copyWith(
                        color: cs.ds.muted, fontWeight: FontWeight.w700)),
              ),
            ),
            DsGroup(margin: EdgeInsets.zero, children: [
              for (final tool in sec.$2)
                DsListRow(
                  leading: icon(tool.icon),
                  title: tool.label,
                  trailing: Icon(Icons.chevron_right_rounded, color: cs.ds.muted),
                  onTap: () => open(tool.build!),
                ),
            ]),
          ],
        ],
      ),
    );
  }
}

class _PaTool {
  final IconData icon;
  final String label;
  final WidgetBuilder? build; // null = a group header
  const _PaTool(this.icon, this.label, this.build);
  const _PaTool.header(this.label)
      : icon = Icons.label_rounded,
        build = null;
}
