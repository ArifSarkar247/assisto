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
import '../screens/remittance/remittance_screen.dart'; // budget-remittance
import '../screens/money_tax_screen.dart';
import '../screens/money_wrapped_screen.dart';
import '../screens/money_voice_screen.dart';
import '../screens/voice_assistant_screen.dart';
import '../screens/subscriptions_screen.dart';
import '../screens/finance_screen.dart';
import '../screens/payment_ladder_screen.dart';
import '../screens/task_manager_screen.dart';
import '../screens/mess_accounting_screen.dart';
import '../screens/my_vehicles_screen.dart';
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
import '../screens/health_timeline_screen.dart';
import '../screens/wellness_tracker_screen.dart';
import '../screens/daily_challenges_screen.dart';
import '../screens/saved_items_screen.dart';
import '../screens/kid_school_screen.dart';
import '../screens/fitness_partner_screen.dart';
import '../screens/smartwatch_screen.dart';
import '../screens/contract_analyzer_screen.dart';
import '../screens/cost_estimator_screen.dart';
import '../screens/mock_interview_screen.dart';
import '../screens/language_partner_screen.dart';
import '../screens/spending_advice_screen.dart';
import '../screens/price_radar_screen.dart';
import '../screens/quick_tools_screen.dart';
import '../screens/daily_brief_screen.dart';
import '../screens/blog_writer_screen.dart';
import '../screens/cv_builder_screen.dart';
import '../screens/doc_scanner_screen.dart';
import '../screens/transcription_screen.dart';
import '../screens/travel_planner_screen.dart';
import '../screens/voice_mood_screen.dart';
import '../screens/proactive_ai_screen.dart';
import '../screens/area_community_screen.dart';
import '../screens/doctor_serial_screen.dart';
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
import '../screens/lost_stolen_screen.dart';
import '../screens/my_lost_phone_screen.dart';
import '../screens/phone_safety_screen.dart';
import '../screens/security_screen.dart';
import '../screens/sell_my_phone_screen.dart';
import '../screens/shop_box_screen.dart';
import '../screens/watchman/watchman_screen.dart'; // cctv1
import '../screens/booking/booking_biz_screen.dart'; // booking-bot
import '../screens/booking/my_bookings_screen.dart'; // booking-bot
import '../screens/retention/retention_inbox.dart'; // retention1
import '../screens/retention/retention_screen.dart'; // retention1
import '../screens/used_phone_check_screen.dart';
import '../screens/unseen_world_screen.dart';
import '../screens/world/world_hub_screen.dart'; // p4-world
import '../screens/dictionary_screen.dart';
import '../screens/ramadan_screen.dart';
import '../screens/watch_feed_screen.dart';
import '../screens/exam_result_screen.dart';
import '../screens/photo_studio_screen.dart'; // ps1-photo
// work
import '../screens/agent_studio_screen.dart';
import '../screens/jobs_screen.dart';
import '../screens/inbox_screen.dart';
// business
import '../screens/pa/pa_hub_screen.dart';
import '../screens/business_screen.dart';
import '../screens/crm/crm_home_screen.dart';
import '../feature_gates.dart'
    show kAgentStudioRunsAutomations, kAreaBoardShared, kMedicalFeaturesAllowed; // f6 + play-nomed
import '../feature_flags.dart' show FeatureFlags; // feature-flags
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

  /// play-nomed: a dedicated medical module — hidden in the Play flavour
  /// (see feature_gates.kMedicalFeaturesAllowed).
  final bool medical;

  /// feature-flags: the server feature flag that owns this module
  /// (feature_registry.dart). Hidden flag -> no sidebar entry and no search
  /// hit. Null = a core entry that is never hidden by a flag.
  final String? feature;
  const SidebarItem(this.icon, this.label, this.builder,
      {this.synonyms = const [], this.medical = false, this.feature});

  /// Visible in THIS build for THIS user (medical gate + feature flag).
  bool get visible =>
      (kMedicalFeaturesAllowed || !medical) && FeatureFlags.instance.isOn(feature);

  /// Visible ONLY as a server preview (owner / staff / listed tester) —
  /// normal users do not have it. Shown with a small "Preview" tag.
  bool get preview =>
      feature != null && FeatureFlags.instance.isPreview(feature!);
}

/// The small "Preview" tag next to a sidebar / All Services entry the user
/// sees only because they are the owner / staff / a listed tester.
class PreviewTag extends StatelessWidget {
  const PreviewTag({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('preview_tag'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(t.ffPreviewTag,
          maxLines: 1,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: scheme.onSecondaryContainer)),
    );
  }
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

  /// The sidebar for THIS build and user. play-nomed: in the Play flavour
  /// every [SidebarItem.medical] module is removed; feature-flags: every
  /// module whose server flag is off is removed too (an emptied section is
  /// dropped).
  static List<SidebarSection> get all => [
        for (final s in _all)
          if (s.items.any((i) => i.visible))
            s.items.every((i) => i.visible)
                ? s
                : SidebarSection(s.id, s.icon, s.title,
                    [for (final i in s.items) if (i.visible) i]),
      ];

  static final List<SidebarSection> _all = [
    // ONE-ENTRY-PER-MODULE (OWNER UI FIX v2 §5): the Messenger hub ("My Circle")
    // is the single top quick-link in app_drawer.dart and is intentionally NOT
    // a sidebar section. Connected circle / Circle privacy / Circle calls are
    // features of that hub, not standalone modules, so they are NOT listed here.
    // 1. Reminders & Memory
    SidebarSection('reminders_memory', Icons.notifications_active_rounded,
        (t) => t.sidebarRemindersMemory, [
      SidebarItem(Icons.alarm_rounded, (t) => t.navReminders,
          feature: 'reminders',
          (_) => const RemindersScreen(),
          synonyms: ['reminder', 'alarm']),
      SidebarItem(Icons.cake_rounded, (t) => t.birthdaysTitle,
          feature: 'birthdays',
          (_) => const BirthdaysScreen(),
          synonyms: ['birthday', 'memorable', 'anniversary']),
      SidebarItem(Icons.event_rounded, (t) => t.meetingsTitle,
          feature: 'meetings',
          (_) => const MeetingsScreen(),
          synonyms: ['meeting', 'appointment', 'calendar']),
      // booking-bot: bookings I made with businesses (flag booking_bot).
      SidebarItem(Icons.event_available_rounded, (t) => t.bkgSidebarMine,
          feature: 'booking_bot',
          (_) => const MyBookingsScreen(),
          synonyms: ['my bookings', 'booking', 'appointment', 'serial', 'slot']),
      SidebarItem(Icons.checklist_rounded, (t) => t.navNotesTasks,
          feature: 'notes',
          (_) => const NotesTodosScreen(),
          synonyms: ['note', 'task', 'todo', 'to-do']),
      SidebarItem(Icons.psychology_rounded, (t) => t.navMemory,
          feature: 'memory',
          (_) => const MemoryScreen(),
          synonyms: ['memory', 'ai knows', 'remember']),
      // #18 Saved / bookmarks — universal save surface.
      SidebarItem(Icons.bookmark_outline_rounded, (t) => t.savedTitle,
          feature: 'saved_items',
          (_) => const SavedItemsScreen(),
          synonyms: ['saved', 'bookmark', 'bookmarks', 'star', 'keep']),
    ]),
    // 2. My Account
    SidebarSection('my_account', Icons.account_balance_wallet_rounded,
        (t) => t.sidebarMoney, [
      SidebarItem(Icons.account_balance_wallet_rounded, (t) => t.moduleMoney,
          feature: 'money',
          (_) => const MoneyScreen(),
          synonyms: ['account', 'finance', 'ledger', 'money', 'expense', 'income']),
      // Advanced Budget module (feature #50, SPEC v2.1 §21).
      SidebarItem(Icons.pie_chart_outline_rounded, (t) => t.budgetTitle,
          feature: 'budget',
          (_) => const MoneyBudgetScreen(),
          synonyms: ['budget', 'limit', 'spending plan', 'rollover']),
      // budget-remittance: money received from abroad + the family budget
      // (flag budget_remittance, hidden until 9/9).
      SidebarItem(Icons.currency_exchange_rounded, (t) => t.rmtTitle,
          feature: 'budget_remittance',
          (_) => const RemittanceScreen(),
          synonyms: ['remittance', 'money from abroad', 'family budget', 'bidesh', 'probashi money']),
      // Tax & Zakat calculators (feature #60) — client-side, bilingual.
      SidebarItem(Icons.receipt_long_rounded, (t) => t.taxTitle,
          feature: 'tax_zakat',
          (_) => const MoneyTaxScreen(),
          synonyms: ['tax', 'zakat', 'nisab', 'income tax', 'nbr']),
      // Monthly Money Wrapped recap (feature #63).
      SidebarItem(Icons.auto_awesome_rounded, (t) => t.wrappedTitle,
          feature: 'money_wrapped',
          (_) => const MoneyWrappedScreen(),
          synonyms: ['wrapped', 'recap', 'monthly', 'summary', 'story']),
      // Money by voice — speak an expense/income, confirm, log (feature #62).
      SidebarItem(Icons.mic_none_rounded, (t) => t.mvoiceTitle,
          feature: 'money_voice',
          (_) => const MoneyVoiceScreen(),
          synonyms: ['voice', 'speak', 'say', 'mic', 'dictate']),
      SidebarItem(Icons.autorenew_rounded, (t) => t.subscriptions,
          feature: 'subscriptions',
          (_) => const SubscriptionsScreen(),
          synonyms: ['subscription', 'recurring', 'bill']),
      SidebarItem(Icons.calculate_rounded, (t) => t.financeTools,
          feature: 'finance_tools',
          (_) => const FinanceScreen(),
          synonyms: ['finance', 'loan', 'savings', 'calculator']),
      // Payment / auto-pay LADDER (SPEC v2.1 §21): escalating collection/auto-pay
      // reminders. Never holds money, never auto-charges — key-gated payments.
      SidebarItem(Icons.stairs_rounded, (t) => t.plTitle,
          feature: 'payment_ladder',
          (_) => const PaymentLadderScreen(),
          synonyms: ['payment', 'ladder', 'collection', 'auto-pay', 'tagada']),
      // Section-20 money modules (SPEC v2.1 §20) — thin, on the Money foundation.
      SidebarItem(Icons.restaurant_rounded, (t) => t.messTitle,
          feature: 'mess_accounting',
          (_) => const MessAccountingScreen(),
          synonyms: ['mess', 'bachelor', 'meal', 'bazar', 'manager']),
      SidebarItem(Icons.groups_rounded, (t) => t.splitTitle,
          feature: 'expense_split',
          (_) => const ExpenseSplitScreen(),
          synonyms: ['split', 'splitwise', 'share', 'settle', 'group expense']),
      SidebarItem(Icons.savings_rounded, (t) => t.samityTitle,
          feature: 'samity',
          (_) => const SamityScreen(),
          synonyms: ['samity', 'committee', 'rosca', 'rotating savings']),
      SidebarItem(Icons.home_work_rounded, (t) => t.rentTitle,
          feature: 'house_rent',
          (_) => const LandlordTenantScreen(),
          synonyms: ['rent', 'landlord', 'tenant', 'bari', 'house rent']),
      // #193 Prepaid electricity & gas meter tracker.
      SidebarItem(Icons.electric_meter_rounded, (t) => t.meterTitle,
          feature: 'prepaid_meter',
          (_) => const PrepaidMeterScreen(),
          synonyms: ['meter', 'prepaid', 'electricity', 'gas', 'recharge', 'token']),
      // #186 Domestic staff/driver payroll + #171 savings challenge.
      SidebarItem(Icons.badge_rounded, (t) => t.staffTitle,
          feature: 'domestic_staff',
          (_) => const DomesticStaffScreen(),
          synonyms: ['staff', 'maid', 'driver', 'cook', 'salary', 'household']),
      SidebarItem(Icons.emoji_events_rounded, (t) => t.savechalTitle,
          feature: 'savings_challenge',
          (_) => const SavingsChallengeScreen(),
          synonyms: ['savings', 'challenge', 'save', '52 week', 'streak']),
      // #51 AI spending advice (key-gated mock) + #34 market price radar.
      SidebarItem(Icons.insights_rounded, (t) => t.spendTitle,
          feature: 'spending_advice',
          (_) => const SpendingAdviceScreen(),
          synonyms: ['spending', 'advice', 'insights', 'ai money', 'analysis']),
      SidebarItem(Icons.trending_up_rounded, (t) => t.priceTitle,
          feature: 'price_radar',
          (_) => const PriceRadarScreen(),
          synonyms: ['price', 'radar', 'market', 'bazar', 'rate']),
    ]),
    // 3. Family & Safety — merged per SPEC v2.1 §4 (Family + Safety → one group).
    // Contacts moved OUT to its own "Contacts & Profile" section (item 4).
    SidebarSection('family_safety', Icons.diversity_1_rounded,
        (t) => t.sidebarFamilySafety, [
      SidebarItem(Icons.diversity_1_rounded, (t) => t.moduleFamily,
          feature: 'family',
          (_) => const FamilyScreen(),
          synonyms: ['family', 'care', 'medicine schedule', 'elderly']),
      SidebarItem(Icons.shield_rounded, (t) => t.nominee,
          feature: 'nominee',
          (_) => const NomineeScreen(),
          synonyms: ['nominee', 'access', 'inheritance']),
      SidebarItem(Icons.navigation_rounded, (t) => t.journeyHubTitle,
          feature: 'safe_journey',
          (_) => const JourneyStartScreen(),
          synonyms: ['safe journey', 'journey', 'travel', 'sos', 'track']),
      SidebarItem(Icons.emergency_rounded, (t) => t.moduleEmergency,
          feature: 'emergency',
          (_) => const EmergencyScreen(),
          synonyms: ['emergency', 'sos', 'card']),
      SidebarItem(Icons.verified_user_rounded, (t) => t.scamTitle,
          feature: 'scam_check',
          (_) => const ScamScreen(),
          synonyms: ['scam', 'fraud', 'protection']),
      // NO SHOWPIECES: hidden until a real fall sensor engine ships.
      if (FallDetectScreen.engineShipped)
        SidebarItem(Icons.monitor_heart_rounded, (t) => t.fallDetectTitle,
            feature: 'fall_detect',
            (_) => const FallDetectScreen(),
            synonyms: ['fall', 'fall detection', 'accident', 'elderly safety']),
      // #80 Lost / stolen phone protection (device-admin: lock / alarm /
      // locate / lost-message). Chat-openable via ChatNav route 'lost_stolen'.
      SidebarItem(Icons.phonelink_lock_rounded, (t) => t.lostStolenTitle,
          feature: 'anti_theft',
          (_) => const LostStolenScreen(),
          synonyms: ['lost', 'stolen', 'theft', 'anti-theft', 'find phone',
              'device admin', 'remote lock', 'churi', 'harano']),
      // Anti-theft Batch 5: "My lost phone" — the server-side view of this
      // phone (armed/lost/frozen status, last location + trail, intruder
      // photos, SIM change, IMEIs) plus Lost-mode on/off. Recovery help
      // (GD draft / SP letter / evidence PDF / nearest stations / recovery
      // chances) is reachable from INSIDE this screen and from Lost/Stolen, so
      // it adds no second sidebar entry. ChatNav routes 'my_lost_phone' +
      // 'recovery'.
      SidebarItem(Icons.travel_explore_rounded, (t) => t.mlpTitle,
          feature: 'anti_theft',
          (_) => const MyLostPhoneScreen(),
          synonyms: ['my lost phone', 'lost phone', 'find my phone',
              'track phone', 'lost mode', 'recovery', 'gd', 'harano',
              'locate phone', 'where is my phone']),
      // Phone Safety Check-up — honest anti-theft hardening wizard (brand-aware
      // menu paths, self-confirm checklist, protection score). ChatNav route
      // 'phone_safety'.
      SidebarItem(Icons.security_rounded, (t) => t.phoneSafetyTitle,
          feature: 'anti_theft',
          (_) => const PhoneSafetyScreen(),
          synonyms: ['phone safety', 'theft', 'anti-theft', 'churi',
              'nirapotta', 'lock', 'harden', 'secure phone']),
      // Section 8 — Stolen-while-unlocked protection: server-side ownership +
      // delayed/alerted sensitive actions (disarm, transfer, remove admin).
      // ChatNav route 'security'.
      SidebarItem(Icons.shield_rounded, (t) => t.securityTitle,
          feature: 'anti_theft',
          (_) => const SecurityScreen(),
          synonyms: ['security', 'stolen while unlocked', 'ownership',
              'anti-theft ownership', 'protect phone', 'churi', 'disarm',
              'security pin']),
      // Anti-theft Batch 4: Sell my phone safely — guided wipe checklist + a
      // digital sale receipt with a Section-8-gated transfer authorize, buyer
      // accept, and "my receipts". Report-my-phone-stolen + mark-recovered live
      // INSIDE this screen (and the Used-phone check screen), so they add no
      // 3rd top entry. ChatNav route 'sell_phone'.
      SidebarItem(Icons.sell_rounded, (t) => t.upSellTitle,
          feature: 'anti_theft',
          (_) => const SellMyPhoneScreen(),
          synonyms: ['sell phone', 'sell my phone', 'transfer phone',
              'phone sale', 'report stolen', 'report phone', 'bikri', 'churi']),
      // Part 4: Shop Box / CCTV loss-prevention (Business tier). Signals-only,
      // privacy-first: NO video — the edge box detects on-device and sends only
      // signals + at most one snapshot. Alerts say "please check camera X".
      // Business-gated inside the screen. ChatNav route 'shop_box'.
      // cctv1: Home & shop watchman — homes (any plan) and shops (Business);
      // not tied to the POS. Server flag home_watchman (route 'watchman').
      SidebarItem(Icons.videocam_rounded, (t) => t.wmTitle,
          feature: 'home_watchman',
          (_) => const WatchmanScreen(),
          synonyms: ['cctv', 'camera', 'watchman', 'home camera', 'imou',
              'hikvision', 'dahua', 'tapo', 'ezviz', 'security camera',
              'pahara', 'pahaladar']),
      SidebarItem(Icons.storefront_rounded, (t) => t.shopBoxTitle,
          feature: 'cctv_watchman',
          (_) => const ShopBoxScreen(),
          synonyms: ['shop box', 'cctv', 'camera', 'loss prevention',
              'shop security', 'theft', 'churi', 'dokan', 'store camera',
              'surveillance', 'alert camera']),
      // Wave-D batch-4: BD-specific disaster & weather warnings (cyclone / flood
      // / heatwave / earthquake), official sources only. Also chat-openable via
      // ChatNav route 'disaster'.
      SidebarItem(Icons.cyclone_rounded, (t) => t.disTitle,
          feature: 'disaster_alerts',
          (_) => const DisasterAlertsScreen(),
          synonyms: ['disaster', 'cyclone', 'flood', 'warning', 'earthquake',
              'weather warning']),
      // #188 Blood-donor network (community registry; donor contact opt-in).
      SidebarItem(Icons.bloodtype_rounded, (t) => t.bloodTitle,
          feature: 'blood_donor',
          (_) => const BloodDonorScreen(),
          synonyms: ['blood', 'donor', 'donate', 'blood group', 'rokto']),
      // #27 Kid's school corner — notices → fees / exams / PTM per child.
      SidebarItem(Icons.school_rounded, (t) => t.kidTitle,
          feature: 'kid_school',
          (_) => const KidSchoolScreen(),
          synonyms: ['kid', 'child', 'school', 'fees', 'exam', 'ptm', 'notice']),
      // #187 Doctor serial / appointment tracker.
      SidebarItem(Icons.medical_services_rounded, (t) => t.doctorSerialTitle,
          (_) => const DoctorSerialScreen(),
          synonyms: ['doctor', 'appointment', 'serial', 'chamber', 'hospital'],
          medical: true),
    ]),
    // 4. Contacts — single-item section. Profile was REMOVED here (OWNER UI FIX
    // v2 §4–5): Profile is NOT a module, it lives as a card at the top of
    // SettingsScreen and in the Messenger hub-settings. Contacts remains a
    // real module and keeps its own entry.
    SidebarSection('contacts', Icons.contacts_rounded,
        (t) => t.contactsTitle, [
      SidebarItem(Icons.contacts_rounded, (t) => t.contactsTitle,
          feature: 'contacts',
          (_) => const CrmContactsScreen(),
          synonyms: ['contact', 'phonebook', 'crm']),
    ]),
    // 5. Daily Life — Health info (medicine DB, health tips) folded in per
    // SPEC v2.1 §4 (standalone Health section removed).
    SidebarSection('daily_life', Icons.auto_awesome_rounded,
        (t) => t.sidebarLife, [
      // Part 3: Assisto Voice — hands-free assistant (calls, alarms, torch,
      // YouTube, maps, reminders, expenses, SOS — outgoing always confirmed).
      SidebarItem(Icons.graphic_eq_rounded, (t) => t.vaTitle,
          feature: 'voice_assistant',
          (_) => const VoiceAssistantScreen(),
          synonyms: ['voice assistant', 'assistant', 'hey assisto', 'voice',
              'talk', 'speak', 'alarm', 'torch', 'flashlight']),
      SidebarItem(Icons.medication_rounded, (t) => t.medicineDbTitle,
          (_) => const MedicineDbScreen(),
          synonyms: ['medicine', 'drug', 'pharmacy'],
          medical: true),
      SidebarItem(Icons.tips_and_updates_rounded, (t) => t.healthTipsTitle,
          (_) => const HealthTipsScreen(),
          synonyms: ['health', 'tips', 'wellness'],
          medical: true),
      SidebarItem(Icons.lock_outline_rounded, (t) => t.moduleVault,
          feature: 'documents',
          (_) => const VaultScreen(),
          synonyms: ['document', 'vault', 'file', 'nid', 'passport']),
      SidebarItem(Icons.account_balance_rounded, (t) => t.serviceGuide,
          feature: 'service_guide',
          (_) => const GuideScreen(),
          synonyms: ['government', 'service', 'guide']),
      SidebarItem(Icons.place_rounded, (t) => t.sidebarNearby,
          feature: 'nearby',
          (_) => const NearbyScreen(),
          synonyms: ['nearby', 'around me', 'places']),
      // p4-world: Unseen World — Today cards, web answers, jobs, hubs.
      SidebarItem(Icons.public_rounded, (t) => t.uwTitle,
          feature: 'unseen_world',
          (_) => const WorldHubScreen(),
          synonyms: ['world', 'today', 'news', 'weather', 'prayer time',
              'currency', 'gold price', 'fuel price', 'jobs', 'expat', 'visa',
              'bcs', 'farmer', 'crop', 'passport', 'nid', 'prescription',
              'web search', 'ask anything']),
      SidebarItem(Icons.travel_explore_rounded, (t) => t.unseenTitle,
          feature: 'unseen_bangladesh',
          (_) => const UnseenWorldScreen(),
          synonyms: ['unseen', 'travel', 'explore']),
      SidebarItem(Icons.menu_book_rounded, (t) => t.dictionaryTitle,
          feature: 'dictionary',
          (_) => const DictionaryScreen(),
          synonyms: ['dictionary', 'word', 'meaning']),
      SidebarItem(Icons.nightlight_rounded, (t) => t.ramadanTitle,
          feature: 'ramadan',
          (_) => const RamadanScreen(),
          synonyms: ['prayer', 'ramadan', 'namaz', 'roza']),
      SidebarItem(Icons.radar_rounded, (t) => t.watchFeed,
          feature: 'watch_feed',
          (_) => const WatchFeedScreen(),
          synonyms: ['watch', 'feed', 'alerts']),
      SidebarItem(Icons.school_rounded, (t) => t.examTitle,
          feature: 'exam_result',
          (_) => const ExamResultScreen(),
          synonyms: ['exam', 'result', 'ssc', 'hsc']),
      // ps1-photo: Photo Studio — one-tap AI enhance + edit/generate by prompt.
      // It REPLACES the old enhance tool (owner order): one entry, one ad rule.
      SidebarItem(Icons.auto_awesome_rounded, (t) => t.psTitle,
          feature: 'photo_studio',
          (_) => const PhotoStudioScreen(),
          synonyms: ['photo studio', 'edit photo', 'background', 'passport photo',
              'ai photo', 'beauty', 'retouch', 'photo', 'enhance', 'image']),
      SidebarItem(Icons.directions_car_rounded, (t) => t.rideFoodTitle,
          feature: 'ride_food',
          (_) => const RideFoodScreen(),
          synonyms: ['ride', 'food', 'uber', 'pathao', 'foodpanda', 'delivery']),
      // Anti-theft Batch 4: Used-phone check — enter an IMEI, check the
      // community + ownership registry before buying a second-hand phone.
      // ChatNav route 'used_phone_check'.
      SidebarItem(Icons.phonelink_setup_rounded, (t) => t.upCheckTitle,
          feature: 'anti_theft',
          (_) => const UsedPhoneCheckScreen(),
          synonyms: ['used phone', 'second hand', 'secondhand', 'imei check',
              'buy used phone', 'check phone', 'stolen check', 'purano phone']),
      SidebarItem(Icons.directions_car_rounded, (t) => t.vehiclesTitle,
          feature: 'vehicles',
          (_) => const MyVehiclesScreen(), synonyms: [
        'vehicle',
        'car',
        'bike',
        'motorcycle',
        'gari',
        'registration',
        'tax token',
        'fitness',
        'insurance',
        'tracker'
      ]),
      // Section-20 life modules (SPEC v2.1 §20) — Daily Life group.
      SidebarItem(Icons.school_rounded, (t) => t.studentTitle,
          feature: 'student_corner',
          (_) => const StudentCornerScreen(),
          synonyms: ['student', 'routine', 'cgpa', 'gpa', 'assignment', 'exam']),
      SidebarItem(Icons.celebration_rounded, (t) => t.weddingTitle,
          feature: 'wedding_events',
          (_) => const WeddingEventsScreen(),
          synonyms: ['wedding', 'event', 'guest', 'biye', 'party', 'anniversary']),
      SidebarItem(Icons.mosque_rounded, (t) => t.qurbaniTitle,
          feature: 'qurbani',
          (_) => const QurbaniScreen(),
          synonyms: ['qurbani', 'eid', 'korbani', 'sacrifice', 'animal share']),
      SidebarItem(Icons.flight_takeoff_rounded, (t) => t.probashiTitle,
          feature: 'probashi',
          (_) => const ProbashiScreen(),
          synonyms: ['probashi', 'expat', 'remittance', 'abroad', 'foreign']),
      // #199 Farmer / village mode — large-touch farm ledger + crop calendar.
      SidebarItem(Icons.agriculture_rounded, (t) => t.farmerTitle,
          feature: 'farmer_mode',
          (_) => const FarmerModeScreen(),
          synonyms: ['farmer', 'village', 'crop', 'livestock', 'krishi', 'chash']),
      // Health §10: #69 timeline + #71 wellness; #173 challenges; #72 fitness.
      SidebarItem(Icons.timeline_rounded, (t) => t.htlTitle,
          (_) => const HealthTimelineScreen(),
          synonyms: ['health', 'timeline', 'record', 'history', 'medical'],
          medical: true),
      SidebarItem(Icons.local_drink_rounded, (t) => t.wellTitle,
          feature: 'wellness',
          (_) => const WellnessTrackerScreen(),
          synonyms: ['wellness', 'water', 'sleep', 'diet', 'tracker']),
      SidebarItem(Icons.fitness_center_rounded, (t) => t.fitTitle,
          feature: 'fitness',
          (_) => const FitnessPartnerScreen(),
          synonyms: ['fitness', 'workout', 'exercise', 'steps', 'gym']),
      // #70 Smartwatch & fitness — Health Connect bridge (steps/HR/sleep/energy).
      SidebarItem(Icons.watch_rounded, (t) => t.swTitle,
          feature: 'smartwatch',
          (_) => const SmartwatchScreen(),
          synonyms: [
            'watch',
            'smartwatch',
            'health connect',
            'heart rate',
            'steps',
            'wearable',
            'fitness band'
          ]),
      SidebarItem(Icons.quiz_rounded, (t) => t.chalTitle,
          feature: 'daily_challenges',
          (_) => const DailyChallengesScreen(),
          synonyms: ['challenge', 'quiz', 'daily', 'streak', 'game']),
      // #30 Contract analyzer + #132 language-learning partner (key-gated mock).
      SidebarItem(Icons.gavel_rounded, (t) => t.caTitle,
          feature: 'contract_analyzer',
          (_) => const ContractAnalyzerScreen(),
          synonyms: ['contract', 'agreement', 'analyze', 'clause', 'legal helper']),
      SidebarItem(Icons.translate_rounded, (t) => t.lpTitle,
          feature: 'language_partner',
          (_) => const LanguagePartnerScreen(),
          synonyms: ['language', 'learn', 'english', 'vocabulary', 'practice']),
      // §6/§8 key-gated-mock: #7 daily brief, #29 doc scanner, #92 transcription,
      // #35 travel planner.
      SidebarItem(Icons.wb_sunny_rounded, (t) => t.dbTitle,
          feature: 'daily_brief',
          (_) => const DailyBriefScreen(),
          synonyms: ['brief', 'morning', 'night', 'digest', 'summary', 'today']),
      SidebarItem(Icons.document_scanner_rounded, (t) => t.dsTitle,
          feature: 'doc_scanner',
          (_) => const DocScannerScreen(),
          synonyms: ['document', 'scan', 'scanner', 'nid', 'passport', 'ocr']),
      SidebarItem(Icons.graphic_eq_rounded, (t) => t.tnTitle,
          feature: 'transcription',
          (_) => const TranscriptionScreen(),
          synonyms: ['transcription', 'voice note', 'transcribe', 'recording']),
      SidebarItem(Icons.luggage_rounded, (t) => t.tvTitle,
          feature: 'travel_planner',
          (_) => const TravelPlannerScreen(),
          synonyms: ['travel', 'trip', 'itinerary', 'tour', 'journey', 'vacation']),
      // §6 AI-core: #15 voice mood (on-device opt-in), #6 proactive AI;
      // §20 #194 area community (local-area board).
      SidebarItem(Icons.mood_rounded, (t) => t.moodTitle,
          feature: 'voice_mood',
          (_) => const VoiceMoodScreen(),
          synonyms: ['mood', 'wellbeing', 'feeling', 'mental', 'check-in']),
      SidebarItem(Icons.lightbulb_outline_rounded, (t) => t.proTitle,
          feature: 'proactive_ai',
          (_) => const ProactiveAiScreen(),
          synonyms: ['proactive', 'suggestions', 'nudges', 'ai', 'digest']),
      // f6 (no showpieces): a "neighbourhood board" whose posts no neighbour
      // can see (per-user collection) — hidden until a moderated shared feed
      // exists on the server.
      if (kAreaBoardShared)
        SidebarItem(Icons.holiday_village_rounded, (t) => t.areaCommunityTitle,
            feature: 'area_community',
            (_) => const AreaCommunityScreen(),
            synonyms: ['area', 'community', 'neighbourhood', 'local', 'notice board']),
    ]),
    // 7. Work
    SidebarSection('work', Icons.work_outline_rounded, (t) => t.sidebarWork, [
      // f6 (no showpieces): Agent Studio automations never fire yet (and its
      // social composer labels template drafts "AI-generated"), so the entry
      // is hidden until automations really run.
      if (kAgentStudioRunsAutomations)
        SidebarItem(Icons.auto_awesome_rounded, (t) => t.agentStudio,
            feature: 'agent_studio',
            (_) => const AgentStudioScreen(),
            synonyms: ['agent', 'studio', 'automation']),
      // #21 Task manager — projects / board / assign / progress.
      SidebarItem(Icons.view_kanban_rounded, (t) => t.tmTitle,
          feature: 'task_manager',
          (_) => const TaskManagerScreen(),
          synonyms: ['task', 'project', 'board', 'kanban', 'assign', 'progress']),
      // #36 Cost/time estimator + #131 mock interview (key-gated mock).
      SidebarItem(Icons.calculate_rounded, (t) => t.ceTitle,
          feature: 'cost_estimator',
          (_) => const CostEstimatorScreen(),
          synonyms: ['estimate', 'cost', 'time', 'quote', 'budget estimate']),
      SidebarItem(Icons.record_voice_over_rounded, (t) => t.miTitle,
          feature: 'mock_interview',
          (_) => const MockInterviewScreen(),
          synonyms: ['interview', 'mock', 'practice', 'job prep', 'viva']),
      // #17 Quick tools + #130 blog & script writer (key-gated AI mock).
      SidebarItem(Icons.bolt_rounded, (t) => t.qtTitle,
          feature: 'quick_tools',
          (_) => const QuickToolsScreen(),
          synonyms: ['quick', 'tools', 'summarise', 'grammar', 'translate', 'tone']),
      SidebarItem(Icons.article_rounded, (t) => t.bwTitle,
          feature: 'blog_writer',
          (_) => const BlogWriterScreen(),
          synonyms: ['blog', 'script', 'writing', 'post', 'caption', 'draft']),
      SidebarItem(Icons.work_outline_rounded, (t) => t.jobHunter,
          feature: 'jobs',
          (_) => const JobsScreen(),
          synonyms: ['job', 'hunter', 'career']),
      SidebarItem(Icons.description_rounded, (t) => t.cvTitle,
          feature: 'cv_builder',
          (_) => const CvBuilderScreen(),
          synonyms: ['cv', 'resume', 'bio data', 'biodata', 'curriculum vitae']),
      SidebarItem(Icons.mark_email_unread_rounded, (t) => t.aiInbox,
          feature: 'ai_inbox',
          (_) => const InboxScreen(),
          synonyms: ['inbox', 'ai inbox', 'mail']),
      // PA Secretary — SPEC §14 / §4. Section 14 core (schedule, meeting brief,
      // visitor filter, liaison, personal tasks, delegate access) now ships, so
      // this opens the PA hub.
      SidebarItem(Icons.support_agent_rounded, (t) => t.sidebarPaSecretary,
          feature: 'pa_secretary',
          (_) => const PaHubScreen(),
          synonyms: ['pa', 'secretary', 'personal assistant', 'pa mode']),
    ]),
    // 8. Business
    SidebarSection('business', Icons.storefront_rounded,
        (t) => t.sidebarBusiness, [
      SidebarItem(Icons.storefront_rounded, (t) => t.business,
          feature: 'business',
          (_) => const BusinessScreen(),
          synonyms: ['business', 'shop', 'store', 'orders']),
      SidebarItem(Icons.insights_rounded, (t) => t.crmTitle,
          feature: 'crm',
          (_) => const CrmHomeScreen(),
          synonyms: ['crm', 'sales', 'leads', 'pipeline']),
      // booking-bot: the business' services, hours, link and bookings.
      SidebarItem(Icons.edit_calendar_rounded, (t) => t.bkgSidebarBiz,
          feature: 'booking_bot',
          (_) => const BookingBizScreen(),
          synonyms: ['booking', 'appointment', 'slot', 'salon', 'chamber', 'serial', 'calendar']),
      // retention1: Retention automation for the shop owner (flag
      // retention_auto) and, for everyone, the messages shops sent them.
      SidebarItem(Icons.autorenew_rounded, (t) => t.rtTitle,
          feature: 'retention_auto',
          (_) => const RetentionScreen(),
          synonyms: ['retention', 'automation', 'win back', 'winback', 'thank you',
              'review', 'birthday wish', 'back in stock', 'due reminder', 'follow up']),
      SidebarItem(Icons.mark_chat_unread_outlined, (t) => t.rtInboxTitle,
          feature: 'retention_auto',
          (_) => const RetentionInboxScreen(),
          synonyms: ['shop messages', 'messages from shops', 'store messages']),
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
