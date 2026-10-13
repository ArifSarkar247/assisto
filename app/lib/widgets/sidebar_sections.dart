import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/money_screen.dart';
import '../screens/finance_screen.dart';
import '../screens/vault_screen.dart';
import '../screens/subscriptions_screen.dart';
import '../screens/family_screen.dart';
import '../screens/emergency_screen.dart';
import '../screens/nominee_screen.dart';
import '../screens/reminders_screen.dart';
import '../screens/notes_todos_screen.dart';
import '../screens/memory_screen.dart';
import '../screens/watch_feed_screen.dart';
import '../screens/inbox_screen.dart';
import '../screens/agent_studio_screen.dart';
import '../screens/guide_screen.dart';
import '../screens/jobs_screen.dart';
import '../screens/nearby_screen.dart';
import '../screens/business_screen.dart';
import '../screens/crm_contacts_screen.dart';
import '../screens/crm/crm_home_screen.dart';
import '../screens/scam_screen.dart';
import '../screens/safety_screen.dart';
import '../screens/plans_screen.dart';
import '../screens/in_progress_screen.dart';
import '../screens/settings_screen.dart'; // exports SourcesScreen (Connected apps)
// module 5 (P13+)
import '../screens/medicine_db_screen.dart';
import '../screens/health_tips_screen.dart';
import '../screens/birthdays_screen.dart';
import '../screens/meetings_screen.dart';
import '../screens/dictionary_screen.dart';
import '../screens/ride_food_screen.dart';
import '../screens/ramadan_screen.dart';
import '../screens/exam_result_screen.dart';
import '../screens/unseen_world_screen.dart';
import '../screens/photo_enhance_screen.dart';
import '../screens/circle_screen.dart';
import '../screens/legal_screen.dart';

/// One navigable module inside a sidebar section.
class SidebarItem {
  final IconData icon;
  final String Function(AppLocalizations t) label;
  final WidgetBuilder builder;
  const SidebarItem(this.icon, this.label, this.builder);
}

/// A collapsible, titled group of modules in the sidebar.
class SidebarSection {
  final IconData icon;
  final String Function(AppLocalizations t) title;
  final List<SidebarItem> items;
  const SidebarSection(this.icon, this.title, this.items);
}

/// Grouped, collapsible sidebar layout (Phase B spec, for the integrator to
/// wire into the integrator-owned `app_drawer.dart`).
///
/// Sections (localized): My Account, Family, Health, Daily Life, Work,
/// Business, Settings. (Documents lives under Daily Life.)
/// Every module here is ALSO reachable from chat (see [ChatNav]); the sidebar
/// is the discovery surface, chat is the fast path.
///
/// Usage by integrator (replacing the flat `modules` list in app_drawer):
///   for (final s in SidebarSections.all)  -> render an ExpansionTile with
///   s.title(t)/s.icon, children = s.items (ListTile -> push item.builder).
///   Settings + Plans can stay in their own pinned footer if preferred; they
///   are included here too so search covers them.
///
/// Search: filter items by `item.label(t).toLowerCase().contains(query)`;
/// show only sections that still have matching items (see
/// [SidebarSections.filter]).
class SidebarSections {
  SidebarSections._();

  static final List<SidebarSection> all = [
    SidebarSection(Icons.account_balance_wallet_outlined, (t) => t.sidebarMoney, [
      SidebarItem(Icons.account_balance_wallet_outlined,
          (t) => t.moduleMoney, (_) => const MoneyScreen()),
      SidebarItem(Icons.calculate_outlined,
          (t) => t.financeTools, (_) => const FinanceScreen()),
      SidebarItem(Icons.autorenew,
          (t) => t.subscriptions, (_) => const SubscriptionsScreen()),
    ]),
    SidebarSection(Icons.diversity_1_outlined, (t) => t.sidebarFamily, [
      SidebarItem(Icons.diversity_1_outlined,
          (t) => t.moduleFamily, (_) => const FamilyScreen()),
      SidebarItem(Icons.forum_outlined,
          (t) => t.circleTitle, (_) => const CircleScreen()),
      SidebarItem(Icons.emergency_outlined,
          (t) => t.moduleEmergency, (_) => const EmergencyScreen()),
      SidebarItem(Icons.health_and_safety_outlined,
          (t) => t.safetyTitle, (_) => const SafetyScreen()),
      SidebarItem(Icons.shield_outlined,
          (t) => t.nominee, (_) => const NomineeScreen()),
    ]),
    SidebarSection(Icons.favorite_outline, (t) => t.sidebarHealth, [
      SidebarItem(Icons.medication_outlined,
          (t) => t.medicineDbTitle, (_) => const MedicineDbScreen()),
      SidebarItem(Icons.tips_and_updates_outlined,
          (t) => t.healthTipsTitle, (_) => const HealthTipsScreen()),
      SidebarItem(Icons.cake_outlined,
          (t) => t.birthdaysTitle, (_) => const BirthdaysScreen()),
      SidebarItem(Icons.alarm_outlined,
          (t) => t.navReminders, (_) => const RemindersScreen()),
      SidebarItem(Icons.verified_user_outlined,
          (t) => t.scamTitle, (_) => const ScamScreen()),
    ]),
    SidebarSection(Icons.auto_awesome_outlined, (t) => t.sidebarLife, [
      SidebarItem(Icons.lock_outline,
          (t) => t.moduleVault, (_) => const VaultScreen()),
      SidebarItem(Icons.event_outlined,
          (t) => t.meetingsTitle, (_) => const MeetingsScreen()),
      SidebarItem(Icons.menu_book_outlined,
          (t) => t.dictionaryTitle, (_) => const DictionaryScreen()),
      SidebarItem(Icons.local_taxi_outlined,
          (t) => t.rideFoodTitle, (_) => const RideFoodScreen()),
      SidebarItem(Icons.nightlight_outlined,
          (t) => t.ramadanTitle, (_) => const RamadanScreen()),
      SidebarItem(Icons.school_outlined,
          (t) => t.examTitle, (_) => const ExamResultScreen()),
      SidebarItem(Icons.travel_explore_outlined,
          (t) => t.unseenTitle, (_) => const UnseenWorldScreen()),
      SidebarItem(Icons.auto_fix_high_outlined,
          (t) => t.photoTitle, (_) => const PhotoEnhanceScreen()),
      SidebarItem(Icons.checklist_outlined,
          (t) => t.navNotesTasks, (_) => const NotesTodosScreen()),
      SidebarItem(Icons.psychology_outlined,
          (t) => t.navMemory, (_) => const MemoryScreen()),
      SidebarItem(Icons.radar_outlined,
          (t) => t.watchFeed, (_) => const WatchFeedScreen()),
      SidebarItem(Icons.mark_email_unread_outlined,
          (t) => t.aiInbox, (_) => const InboxScreen()),
      SidebarItem(Icons.place_outlined,
          (t) => t.sidebarNearby, (_) => const NearbyScreen()),
    ]),
    SidebarSection(Icons.work_outline, (t) => t.sidebarWork, [
      SidebarItem(Icons.auto_awesome_outlined,
          (t) => t.agentStudio, (_) => const AgentStudioScreen()),
      SidebarItem(Icons.account_balance_outlined,
          (t) => t.serviceGuide, (_) => const GuideScreen()),
      SidebarItem(Icons.work_outline,
          (t) => t.jobHunter, (_) => const JobsScreen()),
      SidebarItem(Icons.hub_outlined,
          (t) => t.connectedApps, (_) => SourcesScreen()),
    ]),
    SidebarSection(Icons.storefront_outlined, (t) => t.sidebarBusiness, [
      SidebarItem(Icons.storefront_outlined,
          (t) => t.business, (_) => const BusinessScreen()),
      SidebarItem(Icons.contacts_outlined,
          (t) => t.contactsTitle, (_) => const CrmContactsScreen()),
      SidebarItem(Icons.insights_outlined,
          (t) => t.crmTitle, (_) => const CrmHomeScreen()),
    ]),
    SidebarSection(Icons.settings_outlined, (t) => t.sidebarSettings, [
      SidebarItem(Icons.workspace_premium_outlined,
          (t) => t.planCredits, (_) => const PlansScreen()),
      SidebarItem(Icons.pending_actions_outlined,
          (t) => t.inProgress, (_) => const InProgressScreen()),
      SidebarItem(Icons.gavel_outlined,
          (t) => t.legalTitle, (_) => const LegalScreen()),
    ]),
  ];

  /// ASCII-only search aliases (English back-compat / old names). Bangla aliases
  /// are NOT listed here (language-gate forbids Bangla in Dart); Bangla searches
  /// resolve directly against the localized section titles + item labels, which
  /// already carry the Bangla text via ARB (the Bangla word for "account"
  /// matches the "My Account" section/module, the Bangla word for "daily"
  /// matches the "Daily Life" section title). Each alias maps to a
  /// substring that appears in the English title/label it should surface.
  ///   'money'     -> old section name, now "My Account"
  ///   'life'      -> old section name, now "Daily Life"
  ///   'sales crm' -> old module name, now "CRM"
  static const Map<String, String> _searchAliases = {
    'money': 'my account',
    'life': 'daily life',
    'sales crm': 'crm',
    'sales': 'crm',
  };

  /// Returns sections (with items) matching [query]. Empty query -> [all].
  /// Matches against both the section TITLE (whole section surfaces) and each
  /// item label. A few ASCII aliases ([_searchAliases]) keep old English names
  /// like "money"/"life"/"sales crm" working after the rename.
  /// Integrator uses this for the sidebar search box.
  static List<SidebarSection> filter(AppLocalizations t, String query) {
    var q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    q = _searchAliases[q] ?? q;
    final out = <SidebarSection>[];
    for (final s in all) {
      // Section-title hit surfaces the whole section.
      if (s.title(t).toLowerCase().contains(q)) {
        out.add(s);
        continue;
      }
      final hits = s.items
          .where((i) => i.label(t).toLowerCase().contains(q))
          .toList();
      if (hits.isNotEmpty) out.add(SidebarSection(s.icon, s.title, hits));
    }
    return out;
  }
}
