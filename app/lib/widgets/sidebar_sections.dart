import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
// reminders & memory
import '../screens/reminders_screen.dart';
import '../screens/birthdays_screen.dart';
import '../screens/meetings_screen.dart';
import '../screens/notes_todos_screen.dart';
import '../screens/memory_screen.dart';
// my account
import '../screens/money_screen.dart';
import '../screens/money_budget_screen.dart';
import '../screens/money_tax_screen.dart';
import '../screens/money_wrapped_screen.dart';
import '../screens/money_voice_screen.dart';
import '../screens/subscriptions_screen.dart';
import '../screens/finance_screen.dart';
import '../screens/payment_ladder_screen.dart';
import '../screens/task_manager_screen.dart';
import '../screens/mess_accounting_screen.dart';
import '../screens/expense_split_screen.dart';
import '../screens/samity_screen.dart';
import '../screens/landlord_tenant_screen.dart';
import '../screens/blood_donor_screen.dart';
import '../screens/prepaid_meter_screen.dart';
import '../screens/qurbani_screen.dart';
import '../screens/probashi_screen.dart';
import '../screens/student_corner_screen.dart';
import '../screens/wedding_events_screen.dart';
import '../screens/domestic_staff_screen.dart';
import '../screens/savings_challenge_screen.dart';
import '../screens/farmer_mode_screen.dart';
// family & safety (merged per SPEC v2.1 §4)
import '../screens/family_screen.dart';
import '../screens/nominee_screen.dart';
import '../screens/journey_start_screen.dart';
import '../screens/emergency_screen.dart';
import '../screens/scam_screen.dart';
import '../screens/disaster_alerts_screen.dart';
// contacts (own section per SPEC v2.1 §4; Profile moved to Settings per
// OWNER UI FIX v2 §4 — Profile is not a module)
import '../screens/crm_contacts_screen.dart';
// health info — folded into daily life per SPEC v2.1 §4
import '../screens/medicine_db_screen.dart';
import '../screens/health_tips_screen.dart';
// daily life
import '../screens/vault_screen.dart';
import '../screens/guide_screen.dart';
import '../screens/nearby_screen.dart';
import '../screens/ride_food_screen.dart';
import '../screens/fall_detect_screen.dart';
import '../screens/unseen_world_screen.dart';
import '../screens/dictionary_screen.dart';
import '../screens/ramadan_screen.dart';
import '../screens/watch_feed_screen.dart';
import '../screens/exam_result_screen.dart';
import '../screens/photo_enhance_screen.dart';
// work
import '../screens/agent_studio_screen.dart';
import '../screens/jobs_screen.dart';
import '../screens/inbox_screen.dart';
// business
import '../screens/pa/pa_hub_screen.dart';
import '../screens/business_screen.dart';
import '../screens/crm/crm_home_screen.dart';
// NOTE: the former "My Circle" sidebar group (Connected circle / Circle privacy
// / Circle calls) was DELETED per OWNER UI FIX v2 §2 — those circle-management
// functions now live INSIDE the Messenger hub (people icon, ⋮ hub-settings,
// Calls tab). The hub itself is the single "My Circle" entry at the top of
// app_drawer.dart.

/// One navigable module inside a sidebar section.
class SidebarItem {
  final IconData icon;
  final String Function(AppLocalizations t) label;
  final WidgetBuilder builder;

  /// ASCII search synonyms (English alt-names / old names). Bangla names are
  /// resolved via the localized [label] directly (the gate forbids Bangla in
  /// Dart). Each synonym is matched as a substring of the query.
  final List<String> synonyms;
  const SidebarItem(this.icon, this.label, this.builder,
      {this.synonyms = const []});
}

/// A collapsible, titled group of modules in the sidebar.
class SidebarSection {
  /// Stable id used to persist open/closed state (not localized).
  final String id;
  final IconData icon;
  final String Function(AppLocalizations t) title;
  final List<SidebarItem> items;
  const SidebarSection(this.id, this.icon, this.title, this.items);
}

/// Grouped, collapsible sidebar layout — OWNER UI FIX v2: ONE ENTRY PER MODULE,
/// no feature sub-entries. 7 collapsible sections: Reminders & Memory ·
/// My Account · Family & Safety (merged) · Contacts · Daily Life (health info
/// folded in) · Work (+ PA Secretary) · Business (+CRM). The Messenger hub
/// ("My Circle") is the single top quick-link in `app_drawer.dart` (NOT a
/// section); circle management lives inside that hub. The top chrome (New chat /
/// My Circle hub quick-link / search), Settings and Plans & points live INLINE
/// in the one scroll list rendered by `app_drawer.dart` (nothing pinned; no
/// profile card). Each module appears in exactly ONE place and is ALSO openable
/// from chat via ChatNav + screen_synonyms.
class SidebarSections {
  SidebarSections._();

  static final List<SidebarSection> all = [
    // ONE-ENTRY-PER-MODULE (OWNER UI FIX v2 §5): the Messenger hub ("My Circle")
    // is the single top quick-link in app_drawer.dart and is intentionally NOT
    // a sidebar section. Connected circle / Circle privacy / Circle calls are
    // features of that hub, not standalone modules, so they are NOT listed here.
    // 1. Reminders & Memory
    SidebarSection('reminders_memory', Icons.notifications_active_outlined,
        (t) => t.sidebarRemindersMemory, [
      SidebarItem(Icons.alarm_outlined, (t) => t.navReminders,
          (_) => const RemindersScreen(),
          synonyms: ['reminder', 'alarm']),
      SidebarItem(Icons.cake_outlined, (t) => t.birthdaysTitle,
          (_) => const BirthdaysScreen(),
          synonyms: ['birthday', 'memorable', 'anniversary']),
      SidebarItem(Icons.event_outlined, (t) => t.meetingsTitle,
          (_) => const MeetingsScreen(),
          synonyms: ['meeting', 'appointment', 'calendar']),
      SidebarItem(Icons.checklist_outlined, (t) => t.navNotesTasks,
          (_) => const NotesTodosScreen(),
          synonyms: ['note', 'task', 'todo', 'to-do']),
      SidebarItem(Icons.psychology_outlined, (t) => t.navMemory,
          (_) => const MemoryScreen(),
          synonyms: ['memory', 'ai knows', 'remember']),
    ]),
    // 2. My Account
    SidebarSection('my_account', Icons.account_balance_wallet_outlined,
        (t) => t.sidebarMoney, [
      SidebarItem(Icons.account_balance_wallet_outlined, (t) => t.moduleMoney,
          (_) => const MoneyScreen(),
          synonyms: ['account', 'ledger', 'money', 'expense', 'income']),
      // Advanced Budget module (feature #50, SPEC v2.1 §21).
      SidebarItem(Icons.pie_chart_outline, (t) => t.budgetTitle,
          (_) => const MoneyBudgetScreen(),
          synonyms: ['budget', 'limit', 'spending plan', 'rollover']),
      // Tax & Zakat calculators (feature #60) — client-side, bilingual.
      SidebarItem(Icons.receipt_long_outlined, (t) => t.taxTitle,
          (_) => const MoneyTaxScreen(),
          synonyms: ['tax', 'zakat', 'nisab', 'income tax', 'nbr']),
      // Monthly Money Wrapped recap (feature #63).
      SidebarItem(Icons.auto_awesome_outlined, (t) => t.wrappedTitle,
          (_) => const MoneyWrappedScreen(),
          synonyms: ['wrapped', 'recap', 'monthly', 'summary', 'story']),
      // Money by voice — speak an expense/income, confirm, log (feature #62).
      SidebarItem(Icons.mic_none_outlined, (t) => t.mvoiceTitle,
          (_) => const MoneyVoiceScreen(),
          synonyms: ['voice', 'speak', 'say', 'mic', 'dictate']),
      SidebarItem(Icons.autorenew, (t) => t.subscriptions,
          (_) => const SubscriptionsScreen(),
          synonyms: ['subscription', 'recurring', 'bill']),
      SidebarItem(Icons.calculate_outlined, (t) => t.financeTools,
          (_) => const FinanceScreen(),
          synonyms: ['finance', 'loan', 'savings', 'calculator']),
      // Payment / auto-pay LADDER (SPEC v2.1 §21): escalating collection/auto-pay
      // reminders. Never holds money, never auto-charges — key-gated payments.
      SidebarItem(Icons.stairs_outlined, (t) => t.plTitle,
          (_) => const PaymentLadderScreen(),
          synonyms: ['payment', 'ladder', 'collection', 'auto-pay', 'tagada']),
      // Section-20 money modules (SPEC v2.1 §20) — thin, on the Money foundation.
      SidebarItem(Icons.restaurant_outlined, (t) => t.messTitle,
          (_) => const MessAccountingScreen(),
          synonyms: ['mess', 'bachelor', 'meal', 'bazar', 'manager']),
      SidebarItem(Icons.groups_outlined, (t) => t.splitTitle,
          (_) => const ExpenseSplitScreen(),
          synonyms: ['split', 'splitwise', 'share', 'settle', 'group expense']),
      SidebarItem(Icons.savings_outlined, (t) => t.samityTitle,
          (_) => const SamityScreen(),
          synonyms: ['samity', 'committee', 'rosca', 'rotating savings']),
      SidebarItem(Icons.home_work_outlined, (t) => t.rentTitle,
          (_) => const LandlordTenantScreen(),
          synonyms: ['rent', 'landlord', 'tenant', 'bari', 'house rent']),
      // #193 Prepaid electricity & gas meter tracker.
      SidebarItem(Icons.electric_meter_outlined, (t) => t.meterTitle,
          (_) => const PrepaidMeterScreen(),
          synonyms: ['meter', 'prepaid', 'electricity', 'gas', 'recharge', 'token']),
      // #186 Domestic staff/driver payroll + #171 savings challenge.
      SidebarItem(Icons.badge_outlined, (t) => t.staffTitle,
          (_) => const DomesticStaffScreen(),
          synonyms: ['staff', 'maid', 'driver', 'cook', 'salary', 'household']),
      SidebarItem(Icons.emoji_events_outlined, (t) => t.savechalTitle,
          (_) => const SavingsChallengeScreen(),
          synonyms: ['savings', 'challenge', 'save', '52 week', 'streak']),
    ]),
    // 3. Family & Safety — merged per SPEC v2.1 §4 (Family + Safety → one group).
    // Contacts moved OUT to its own "Contacts & Profile" section (item 4).
    SidebarSection('family_safety', Icons.diversity_1_outlined,
        (t) => t.sidebarFamilySafety, [
      SidebarItem(Icons.diversity_1_outlined, (t) => t.moduleFamily,
          (_) => const FamilyScreen(),
          synonyms: ['family', 'care', 'medicine schedule', 'elderly']),
      SidebarItem(Icons.shield_outlined, (t) => t.nominee,
          (_) => const NomineeScreen(),
          synonyms: ['nominee', 'access', 'inheritance']),
      SidebarItem(Icons.navigation_outlined, (t) => t.journeyHubTitle,
          (_) => const JourneyStartScreen(),
          synonyms: ['safe journey', 'journey', 'travel', 'sos', 'track']),
      SidebarItem(Icons.emergency_outlined, (t) => t.moduleEmergency,
          (_) => const EmergencyScreen(),
          synonyms: ['emergency', 'sos', 'card']),
      SidebarItem(Icons.verified_user_outlined, (t) => t.scamTitle,
          (_) => const ScamScreen(),
          synonyms: ['scam', 'fraud', 'protection']),
      SidebarItem(Icons.monitor_heart_outlined, (t) => t.fallDetectTitle,
          (_) => const FallDetectScreen(),
          synonyms: ['fall', 'fall detection', 'accident', 'elderly safety']),
      // Wave-D batch-4: BD-specific disaster & weather warnings (cyclone / flood
      // / heatwave / earthquake), official sources only. Also chat-openable via
      // ChatNav route 'disaster'.
      SidebarItem(Icons.cyclone, (t) => t.disTitle,
          (_) => const DisasterAlertsScreen(),
          synonyms: ['disaster', 'cyclone', 'flood', 'warning', 'earthquake',
              'weather warning']),
      // #188 Blood-donor network (community registry; donor contact opt-in).
      SidebarItem(Icons.bloodtype_outlined, (t) => t.bloodTitle,
          (_) => const BloodDonorScreen(),
          synonyms: ['blood', 'donor', 'donate', 'blood group', 'rokto']),
    ]),
    // 4. Contacts — single-item section. Profile was REMOVED here (OWNER UI FIX
    // v2 §4–5): Profile is NOT a module, it lives as a card at the top of
    // SettingsScreen and in the Messenger hub-settings. Contacts remains a
    // real module and keeps its own entry.
    SidebarSection('contacts', Icons.contacts_outlined,
        (t) => t.contactsTitle, [
      SidebarItem(Icons.contacts_outlined, (t) => t.contactsTitle,
          (_) => const CrmContactsScreen(),
          synonyms: ['contact', 'phonebook', 'crm']),
    ]),
    // 5. Daily Life — Health info (medicine DB, health tips) folded in per
    // SPEC v2.1 §4 (standalone Health section removed).
    SidebarSection('daily_life', Icons.auto_awesome_outlined,
        (t) => t.sidebarLife, [
      SidebarItem(Icons.medication_outlined, (t) => t.medicineDbTitle,
          (_) => const MedicineDbScreen(),
          synonyms: ['medicine', 'drug', 'pharmacy']),
      SidebarItem(Icons.tips_and_updates_outlined, (t) => t.healthTipsTitle,
          (_) => const HealthTipsScreen(),
          synonyms: ['health', 'tips', 'wellness']),
      SidebarItem(Icons.lock_outline, (t) => t.moduleVault,
          (_) => const VaultScreen(),
          synonyms: ['document', 'vault', 'file', 'nid', 'passport']),
      SidebarItem(Icons.account_balance_outlined, (t) => t.serviceGuide,
          (_) => const GuideScreen(),
          synonyms: ['government', 'service', 'guide']),
      SidebarItem(Icons.place_outlined, (t) => t.sidebarNearby,
          (_) => const NearbyScreen(),
          synonyms: ['nearby', 'around me', 'places']),
      SidebarItem(Icons.travel_explore_outlined, (t) => t.unseenTitle,
          (_) => const UnseenWorldScreen(),
          synonyms: ['unseen', 'travel', 'explore']),
      SidebarItem(Icons.menu_book_outlined, (t) => t.dictionaryTitle,
          (_) => const DictionaryScreen(),
          synonyms: ['dictionary', 'word', 'meaning']),
      SidebarItem(Icons.nightlight_outlined, (t) => t.ramadanTitle,
          (_) => const RamadanScreen(),
          synonyms: ['prayer', 'ramadan', 'namaz', 'roza']),
      SidebarItem(Icons.radar_outlined, (t) => t.watchFeed,
          (_) => const WatchFeedScreen(),
          synonyms: ['watch', 'feed', 'alerts']),
      SidebarItem(Icons.school_outlined, (t) => t.examTitle,
          (_) => const ExamResultScreen(),
          synonyms: ['exam', 'result', 'ssc', 'hsc']),
      SidebarItem(Icons.auto_fix_high_outlined, (t) => t.photoTitle,
          (_) => const PhotoEnhanceScreen(),
          synonyms: ['photo', 'enhance', 'image']),
      SidebarItem(Icons.directions_car_outlined, (t) => t.rideFoodTitle,
          (_) => const RideFoodScreen(),
          synonyms: ['ride', 'food', 'uber', 'pathao', 'foodpanda', 'delivery']),
      // Section-20 life modules (SPEC v2.1 §20) — Daily Life group.
      SidebarItem(Icons.school_outlined, (t) => t.studentTitle,
          (_) => const StudentCornerScreen(),
          synonyms: ['student', 'routine', 'cgpa', 'gpa', 'assignment', 'exam']),
      SidebarItem(Icons.celebration_outlined, (t) => t.weddingTitle,
          (_) => const WeddingEventsScreen(),
          synonyms: ['wedding', 'event', 'guest', 'biye', 'party', 'anniversary']),
      SidebarItem(Icons.mosque_outlined, (t) => t.qurbaniTitle,
          (_) => const QurbaniScreen(),
          synonyms: ['qurbani', 'eid', 'korbani', 'sacrifice', 'animal share']),
      SidebarItem(Icons.flight_takeoff_outlined, (t) => t.probashiTitle,
          (_) => const ProbashiScreen(),
          synonyms: ['probashi', 'expat', 'remittance', 'abroad', 'foreign']),
      // #199 Farmer / village mode — large-touch farm ledger + crop calendar.
      SidebarItem(Icons.agriculture_outlined, (t) => t.farmerTitle,
          (_) => const FarmerModeScreen(),
          synonyms: ['farmer', 'village', 'crop', 'livestock', 'krishi', 'chash']),
    ]),
    // 7. Work
    SidebarSection('work', Icons.work_outline, (t) => t.sidebarWork, [
      SidebarItem(Icons.auto_awesome_outlined, (t) => t.agentStudio,
          (_) => const AgentStudioScreen(),
          synonyms: ['agent', 'studio', 'automation']),
      // #21 Task manager — projects / board / assign / progress.
      SidebarItem(Icons.view_kanban_outlined, (t) => t.tmTitle,
          (_) => const TaskManagerScreen(),
          synonyms: ['task', 'project', 'board', 'kanban', 'assign', 'progress']),
      SidebarItem(Icons.work_outline, (t) => t.jobHunter,
          (_) => const JobsScreen(),
          synonyms: ['job', 'hunter', 'career', 'cv']),
      SidebarItem(Icons.mark_email_unread_outlined, (t) => t.aiInbox,
          (_) => const InboxScreen(),
          synonyms: ['inbox', 'ai inbox', 'mail']),
      // PA Secretary — SPEC §14 / §4. Section 14 core (schedule, meeting brief,
      // visitor filter, liaison, personal tasks, delegate access) now ships, so
      // this opens the PA hub.
      SidebarItem(Icons.support_agent_outlined, (t) => t.sidebarPaSecretary,
          (_) => const PaHubScreen(),
          synonyms: ['pa', 'secretary', 'personal assistant', 'pa mode']),
    ]),
    // 8. Business
    SidebarSection('business', Icons.storefront_outlined,
        (t) => t.sidebarBusiness, [
      SidebarItem(Icons.storefront_outlined, (t) => t.business,
          (_) => const BusinessScreen(),
          synonyms: ['business', 'shop', 'store', 'orders']),
      SidebarItem(Icons.insights_outlined, (t) => t.crmTitle,
          (_) => const CrmHomeScreen(),
          synonyms: ['crm', 'sales', 'leads', 'pipeline']),
    ]),
  ];

  /// Returns sections (with items) matching [query]. Empty query -> [all].
  /// Matches the section TITLE, each item LABEL (localized bn OR en), and each
  /// item's ASCII [SidebarItem.synonyms]. Integrator uses this for the search box.
  static List<SidebarSection> filter(AppLocalizations t, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    final out = <SidebarSection>[];
    for (final s in all) {
      if (s.title(t).toLowerCase().contains(q)) {
        out.add(s);
        continue;
      }
      final hits = s.items.where((i) {
        if (i.label(t).toLowerCase().contains(q)) return true;
        return i.synonyms.any((syn) => syn.contains(q) || q.contains(syn));
      }).toList();
      if (hits.isNotEmpty) {
        out.add(SidebarSection(s.id, s.icon, s.title, hits));
      }
    }
    return out;
  }
}
