import '../family_v3/family_entry.dart'; // fcscreen
import 'package:flutter/material.dart';
import '../account_mode.dart'; // acctmode
import '../screens/kids_watch/kids_watch_screen.dart'; // kidswatch
import '../screens/missing/missing_hub_screen.dart'; // missing
import '../screens/blood/blood_hub_screen.dart'; // blood
import '../screens/train/dest_alarm_screen.dart'; // train
import '../screens/train/train_tracker_screen.dart'; // train
import '../screens/itag/itag_screen.dart'; // flag-itag
import '../screens/kid_audio/kid_audio_screen.dart'; // kidaudio

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
import '../screens/day_planner_screen.dart'; // p2plan
import '../screens/mess_accounting_screen.dart';
import '../screens/my_vehicles_screen.dart';
import '../screens/expense_split_screen.dart';
import '../screens/samity_screen.dart';
import '../screens/landlord_tenant_screen.dart';
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
import '../screens/food_calories_screen.dart'; // p2food
import '../screens/smartwatch_screen.dart';
import '../screens/contract_analyzer_screen.dart';
import '../screens/cost_estimator_screen.dart';
import '../screens/mock_interview_screen.dart';
import '../screens/language_partner_screen.dart';
import '../screens/learn_cert_screen.dart'; // learncert
import '../screens/spending_advice_screen.dart';
import '../screens/price_radar_screen.dart';
import '../screens/quick_tools_screen.dart';
import '../screens/daily_tools_screen.dart';
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
import '../screens/safe_journey/sj_hub_screen.dart'; // sjlive
import '../screens/emergency_hub_screen.dart'; // emhub
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
import '../screens/city/city_service_screen.dart'; // cityapp
import '../screens/ride_food_screen.dart';
import '../screens/shop_box_screen.dart';
import '../screens/watchman/watchman_screen.dart'; // cctv1
import '../screens/merged/phone_tiles.dart'; // svcclean
import '../screens/fall_detect_screen.dart' show FallDetectScreen; // svcclean
import '../screens/booking/booking_biz_screen.dart'; // booking-bot
import '../screens/booking/my_bookings_screen.dart'; // booking-bot
import '../screens/retention/retention_inbox.dart'; // retention1
import '../screens/retention/retention_screen.dart'; // retention1
import '../screens/mktengine/mkt_engine_screen.dart'; // mktengine
import '../screens/unseen_world_screen.dart';
import '../screens/world/world_hub_screen.dart'; // p4-world
import '../screens/dictionary_screen.dart';
import '../screens/ramadan_screen.dart';
import '../screens/quran_screen.dart'; // p3faith
import '../quran_learn/quran_learn_screen.dart'; // quranread
import '../screens/watch_feed_screen.dart';
import '../screens/exam_result_screen.dart';
import '../screens/photo_studio_screen.dart'; // ps1-photo
// work
import '../screens/agent_studio_screen.dart';
import '../screens/agent_core/agent_core_screen.dart'; // agent-core
import '../screens/jobs_screen.dart';
import '../screens/inbox_screen.dart';
// business
import '../screens/pa/pa_hub_screen.dart';
import '../screens/business_screen.dart';
import '../screens/market/market_screen.dart'; // amarket
import '../carecall/carecall_screen.dart'; // carecall
import '../bizai/my_shops_screen.dart' show MyShopsScreen; // bizai
import '../screens/crm/crm_home_screen.dart';
import '../feature_gates.dart'
    show kAgentStudioRunsAutomations, kAreaBoardShared, kMedicalFeaturesAllowed; // f6 + play-nomed
import '../feature_flags.dart' show FeatureFlags; // feature-flags
import '../screens/my_dues_screen.dart'; // tagada2
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

  /// acctmode: the accounts area this module belongs to (personal books or
  /// business books). Null = shown in every accounts mode. The mode only
  /// takes it off the MENU — search still finds it (see [SidebarSections]).
  final AcctArea? area;

  /// svcclean (owner 10 Nov): a SHORT name for the All Services tile that
  /// fits whole (no "...") at 360 dp in Bangla and English, default and large
  /// font (guarded by svcclean_guard_test). Null = [label] already fits.
  final String Function(AppLocalizations t)? tile;

  /// svcclean: the canonical ChatNav route of this tile when it has one —
  /// gives the tile its colour (red for Emergency) and is checked for
  /// duplicates (one job = one tile).
  final String? route;

  /// svcclean: flags of the features that are SECTIONS inside this one tile
  /// (e.g. Emergency holds fall detection). A section counts as "in the menu"
  /// while its own flag is on; searching its name finds this tile.
  final List<String> includes;

  /// svcclean: names of the sections inside (search finds this tile by them).
  final List<String Function(AppLocalizations t)> alsoLabels;
  const SidebarItem(this.icon, this.label, this.builder,
      {this.synonyms = const [], this.medical = false, this.feature,
      this.area, this.tile, this.route, this.includes = const [],
      this.alsoLabels = const []});

  /// The All Services tile name.
  String tileLabel(AppLocalizations t) => (tile ?? label)(t);

  /// svcclean: every feature this tile opens — its own flag plus the flags
  /// of the sections inside that are on.
  Set<String> get features => {
        if (feature != null) feature!,
        for (final f in includes)
          if (FeatureFlags.instance.isOn(f)) f,
      };

  /// Listed in the menu for the current accounts mode.
  bool get inMode => AccountModeController.instance.shows(area);

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
  /// acctmode: items outside the current accounts mode are left off the
  /// menu too (never their data — see lib/account_mode.dart).
  static List<SidebarSection> get all => _build(byMode: true);

  /// Every visible module regardless of the accounts mode — what SEARCH uses,
  /// so a mode never closes a door.
  static List<SidebarSection> get allModes => _build(byMode: false);

  /// svcclean: Budget and Remittance replaces the plain Budget tile when on.
  static bool get _remitOn => FeatureFlags.instance.isOn('budget_remittance');

  static List<SidebarSection> _build({required bool byMode}) {
    bool show(SidebarItem i) => i.visible && (!byMode || i.inMode);
    return [
      for (final s in _all)
        if (s.items.any(show))
          s.items.every(show)
              ? s
              : SidebarSection(s.id, s.icon, s.title,
                  [for (final i in s.items) if (show(i)) i]),
    ];
  }

  static final List<SidebarSection> _all = [
    // ONE-ENTRY-PER-MODULE (OWNER UI FIX v2 §5): the Messenger hub ("My Circle")
    // is the single top quick-link in app_drawer.dart and is intentionally NOT
    // a sidebar section.
    // svcclean (owner order 10 Nov 00:45): ONE JOB = ONE TILE; related jobs
    // are SECTIONS inside one tile; about 8 tiles per category; short names
    // that fit whole. Old routes of merged tiles redirect (chatnav.dart).
    // Map: owner_actions/ALL_SERVICES_CLEANUP_BN.md. Guard: test/svcclean_guard_test.dart.
    // 1. Reminders & Memory
    SidebarSection('reminders_memory', Icons.notifications_active_rounded,
        (t) => t.sidebarRemindersMemory, [
      SidebarItem(Icons.alarm_rounded, (t) => t.navReminders,
          feature: 'reminders',
          (_) => const RemindersScreen(),
          synonyms: ['reminder', 'alarm']),
      SidebarItem(Icons.cake_rounded, (t) => t.birthdaysTitle,
          tile: (t) => t.svcTileBirthdays, // svcclean
          feature: 'birthdays',
          (_) => const BirthdaysScreen(),
          synonyms: ['birthday', 'memorable', 'anniversary']),
      SidebarItem(Icons.event_rounded, (t) => t.meetingsTitle,
          tile: (t) => t.svcTileMeetings, // svcclean
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
    // 2. Account & Finance — svcclean: everyday money, max ~8 tiles
    SidebarSection('my_account', Icons.account_balance_wallet_rounded,
        (t) => t.sidebarMoney, [
      SidebarItem(Icons.account_balance_wallet_rounded, (t) => t.moduleMoney,
          tile: (t) => t.svcTileAccounts, // svcclean
          area: AcctArea.personal,
          feature: 'money',
          (_) => const MoneyScreen(),
          synonyms: ['account', 'finance', 'ledger', 'money', 'expense', 'income']),
      // tagada2: what shops' khatas say I owe (verified phone only), pay
      // steps, chat with the shop, mute / block. Owned by the money flag.
      SidebarItem(Icons.storefront_rounded, (t) => t.tg2DuesTitle,
          feature: 'money',
          (_) => const MyDuesScreen(),
          synonyms: ['dues', 'baki', 'shop due', 'what i owe', 'khata', 'tagada']),
      // svcclean: Budget and "Budget and Remittance" were TWO tiles for ONE job.
      // One tile now: it opens Budget and Remittance when that feature is on
      // (the same rule as the home Budget tile), else the plain Budget.
      // Advanced Budget module (feature #50, SPEC v2.1 §21).
      SidebarItem(Icons.pie_chart_outline_rounded,
          (t) => _remitOn ? t.rmtTitle : t.budgetTitle,
          area: AcctArea.personal,
          feature: 'budget',
          tile: (t) => _remitOn ? t.svcTileBudgetRemit : t.budgetTitle, // svcclean
          includes: const ['budget_remittance'], // svcclean
          alsoLabels: [(t) => t.rmtTitle],
          (_) => _remitOn ? const RemittanceScreen() : const MoneyBudgetScreen(),
          synonyms: ['budget', 'limit', 'spending plan', 'rollover', 'remittance',
              'money from abroad', 'family budget', 'bidesh', 'probashi money']),
      // Tax & Zakat calculators (feature #60) — client-side, bilingual.
      SidebarItem(Icons.receipt_long_rounded, (t) => t.taxTitle,
          feature: 'tax_zakat',
          (_) => const MoneyTaxScreen(),
          synonyms: ['tax', 'zakat', 'nisab', 'income tax', 'nbr']),
      SidebarItem(Icons.autorenew_rounded, (t) => t.subscriptions,
          area: AcctArea.personal,
          feature: 'subscriptions',
          (_) => const SubscriptionsScreen(),
          synonyms: ['subscription', 'recurring', 'bill']),
      // Money by voice — speak an expense/income, confirm, log (feature #62).
      SidebarItem(Icons.mic_none_rounded, (t) => t.mvoiceTitle,
          area: AcctArea.personal,
          feature: 'money_voice',
          (_) => const MoneyVoiceScreen(),
          synonyms: ['voice', 'speak', 'say', 'mic', 'dictate']),
      // Monthly Money Wrapped recap (feature #63).
      SidebarItem(Icons.auto_awesome_rounded, (t) => t.wrappedTitle,
          area: AcctArea.personal,
          feature: 'money_wrapped',
          (_) => const MoneyWrappedScreen(),
          synonyms: ['wrapped', 'recap', 'monthly', 'summary', 'story']),
      // #51 AI spending advice (key-gated mock) + #34 market price radar.
      SidebarItem(Icons.insights_rounded, (t) => t.truthSpendTitle, // truth: rule-based, not AI
          area: AcctArea.personal,
          feature: 'spending_advice',
          (_) => const SpendingAdviceScreen(),
          synonyms: ['spending', 'advice', 'insights', 'ai money', 'analysis']),
    ]),
    // 3. Savings & sharing — svcclean: split out of Account & Finance
    SidebarSection('money_groups', Icons.savings_rounded,
        (t) => t.svcCatSaveShare, [
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
          tile: (t) => t.svcTileMess, // svcclean
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
      SidebarItem(Icons.emoji_events_rounded, (t) => t.savechalTitle,
          area: AcctArea.personal,
          feature: 'savings_challenge',
          (_) => const SavingsChallengeScreen(),
          synonyms: ['savings', 'challenge', 'save', '52 week', 'streak']),
    ]),
    // 4. Family & Safety — svcclean (owner 10 Nov): EXACTLY 8 tiles
    SidebarSection('family_safety', Icons.diversity_1_rounded,
        (t) => t.sidebarFamilySafety, [
      SidebarItem(Icons.diversity_1_rounded, (t) => t.moduleFamily,
          route: 'family', // svcclean
          // svcclean: Guardians & who sees me, Nominee access and the Probashi
          // family plan are sections of Family now (rows in Family > More).
          includes: const ['nominee', 'probashi_plan'],
          alsoLabels: [(t) => t.g2SidebarLabel, (t) => t.nominee, (t) => t.pbsTitle],
          feature: 'family',
          (_) => const FamilyEntry(), // fcscreen
          synonyms: ['family', 'care', 'medicine schedule', 'elderly']),
      // carecall (flag care_call): a family care reminder call in your own voice
      SidebarItem(Icons.phone_callback_rounded, (t) => t.ccTitle,
          feature: 'care_call',
          (_) => const CareCallScreen(),
          synonyms: ['care call', 'reminder call', 'call reminder', 'remind mother',
              'remind father', 'elderly reminder']),
      SidebarItem(Icons.navigation_rounded, (t) => t.journeyHubTitle,
          feature: 'safe_journey',
          (_) => const SafeJourneyHubScreen(),
          synonyms: ['safe journey', 'journey', 'travel', 'sos', 'track',
              'live location', 'share location', 'request location', 'child school']),
      // emhub (owner 2 Nov): the Emergency hub — every emergency tool on one
      // screen.
      SidebarItem(Icons.sos_rounded, (t) => t.svcEmergency,
          route: 'emergency', // svcclean
          // svcclean: Emergency hub + Emergency (contacts / card) + Accident &
          // fall detection are ONE tile and ONE screen now.
          includes: [if (FallDetectScreen.engineShipped) 'fall_detect'],
          alsoLabels: [(t) => t.moduleEmergency, (t) => t.fallDetectTitle, (t) => t.emhTitle],
          feature: 'emergency',
          (_) => const EmergencyHubScreen(),
          synonyms: ['emergency hub', 'sos', 'emergency', '999', 'help',
              'joruri']),
      // svcclean: ONE Lost phone tile = Lost or Stolen Pro + My lost phone.
      SidebarItem(Icons.phonelink_lock_rounded, (t) => t.svcLostPhone,
          feature: 'anti_theft',
          route: 'lost_stolen',
          alsoLabels: [(t) => t.lostStolenTitle, (t) => t.mlpTitle],
          (_) => const LostPhoneTileScreen(),
          synonyms: ['lost', 'stolen', 'theft', 'anti-theft', 'find phone', 'my lost phone',
              'lost phone', 'find my phone', 'where is my phone', 'lost mode', 'churi', 'harano']),
      // svcclean: ONE Phone safety tile = check-up + ownership protection +
      // sell my phone safely + used phone check (sections inside).
      SidebarItem(Icons.security_rounded, (t) => t.svcPhoneSafety,
          feature: 'anti_theft',
          route: 'phone_safety',
          alsoLabels: [(t) => t.phoneSafetyTitle, (t) => t.securityTitle,
              (t) => t.upSellTitle, (t) => t.upCheckTitle],
          (_) => const PhoneSafetyTileScreen(),
          synonyms: ['phone safety', 'security', 'ownership', 'stolen while unlocked', 'sell phone',
              'sell my phone', 'transfer phone', 'used phone', 'second hand', 'imei check', 'bikri']),
      SidebarItem(Icons.verified_user_rounded, (t) => t.scamTitle,
          feature: 'scam_check',
          (_) => const ScamScreen(),
          synonyms: ['scam', 'fraud', 'protection']),
      // cctv1: Home & shop watchman — homes (any plan) and shops (Business);
      // not tied to the POS. Server flag home_watchman (route 'watchman').
      SidebarItem(Icons.videocam_rounded, (t) => t.svcCctvWatch,
          route: 'watchman', // svcclean
          feature: 'home_watchman',
          (_) => const WatchmanScreen(),
          synonyms: ['cctv', 'camera', 'watchman', 'home camera', 'imou',
              'hikvision', 'dahua', 'tapo', 'ezviz', 'security camera',
              'pahara', 'pahaladar']),
    ]),
    // 5. Kids — svcclean: the children's features together
    SidebarSection('kids', Icons.child_care_rounded,
        (t) => t.svcCatKids, [
      // #27 Kid's school corner — notices → fees / exams / PTM per child.
      SidebarItem(Icons.school_rounded, (t) => t.kidTitle,
          feature: 'kid_school',
          (_) => const KidSchoolScreen(),
          synonyms: ['kid', 'child', 'school', 'fees', 'exam', 'ptm', 'notice']),
      // kidswatch (owner idea 2): kids GPS watch + School Mode (flag OFF).
      SidebarItem(Icons.watch_rounded, (t) => t.kwTitle,
          tile: (t) => t.svcTileKidsWatch, // svcclean
          feature: 'kids_watch',
          (_) => const KidsWatchScreen(),
          synonyms: ['kids watch', 'gps watch', 'smart watch', 'school mode',
              'child tracker', 'setracker']),
      // kidaudio (owner 2 Nov): child emergency audio (flag OFF).
      SidebarItem(Icons.hearing_rounded, (t) => t.kauTitle,
          tile: (t) => t.svcTileChildAudio, // svcclean
          feature: 'child_emergency_audio',
          (_) => const KidAudioScreen(),
          synonyms: ['emergency audio', 'listen child', 'child sos audio',
              'hear my child', 'kid audio']),
      // missing (owner 2 Nov): Missing person alert (flag missing_alert OFF).
      SidebarItem(Icons.person_search_rounded, (t) => t.maTitle,
          tile: (t) => t.svcTileMissing, // svcclean
          feature: 'missing_alert',
          (_) => const MissingHubScreen(),
          synonyms: ['missing', 'missing person', 'missing child', 'lost child',
              'nikhonj', 'amber alert', 'find person']),
    ]),
    // 6. Contacts — single-item section (Profile lives in Settings).
    SidebarSection('contacts', Icons.contacts_rounded,
        (t) => t.contactsTitle, [
      SidebarItem(Icons.contacts_rounded, (t) => t.contactsTitle,
          feature: 'contacts',
          (_) => const CrmContactsScreen(),
          synonyms: ['contact', 'phonebook', 'crm']),
    ]),
    // 7. Health — svcclean: split out of Daily Life
    SidebarSection('health', Icons.favorite_rounded,
        (t) => t.sidebarHealth, [
      SidebarItem(Icons.local_drink_rounded, (t) => t.wellTitle,
          tile: (t) => t.svcTileWellness, // svcclean
          feature: 'wellness',
          (_) => const WellnessTrackerScreen(),
          synonyms: ['wellness', 'water', 'sleep', 'diet', 'tracker']),
      SidebarItem(Icons.fitness_center_rounded, (t) => t.fitTitle,
          feature: 'fitness',
          (_) => const FitnessPartnerScreen(),
          synonyms: ['fitness', 'workout', 'exercise', 'steps', 'gym']),
      // p2food: food photo -> calories (cited table; flag food_calories).
      SidebarItem(Icons.restaurant_rounded, (t) => t.foodTitle,
          feature: 'food_calories',
          (_) => const FoodCaloriesScreen(),
          synonyms: ['food', 'calorie', 'calories', 'diet', 'meal', 'khabar', 'nutrition']),
      // #70 Smartwatch & fitness — Health Connect bridge (steps/HR/sleep/energy).
      SidebarItem(Icons.watch_rounded, (t) => t.swTitle,
          tile: (t) => t.svcTileSmartwatch, // svcclean
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
      // §6 AI-core: #15 voice mood (on-device opt-in), #6 proactive AI;
      // §20 #194 area community (local-area board).
      SidebarItem(Icons.mood_rounded, (t) => t.moodJournalTitle,
          tile: (t) => t.svcTileMood, // svcclean
          feature: 'voice_mood',
          (_) => const VoiceMoodScreen(),
          synonyms: ['mood', 'journal', 'energy', 'relax', 'breathing', 'check-in']),
      // blood (owner 2 Nov): Blood donor panel — find donors nearby, urgent
      // requests, private contact, My saved donors (flag blood_donors OFF).
      // ownerfix (owner 3 Nov): the ONLY blood donor entry — the old personal
      // registry (#188) is gone; its donors moved into "My saved donors".
      SidebarItem(Icons.bloodtype_rounded, (t) => t.hv2TileBloodDonor,
          feature: 'blood_donors',
          (_) => const BloodHubScreen(),
          synonyms: ['blood donor', 'blood bank', 'urgent blood', 'need blood',
              'rokto dorkar', 'rokto dan', 'donor panel', 'blood', 'donor',
              'donate', 'rokto']),
      // #187 Doctor serial / appointment tracker.
      SidebarItem(Icons.medical_services_rounded, (t) => t.doctorSerialTitle,
          tile: (t) => t.svcTileDoctor, // svcclean
          (_) => const DoctorSerialScreen(),
          synonyms: ['doctor', 'appointment', 'serial', 'chamber', 'hospital'],
          medical: true),
      SidebarItem(Icons.medication_rounded, (t) => t.medicineDbTitle,
          tile: (t) => t.svcTileMedicine, // svcclean
          (_) => const MedicineDbScreen(),
          synonyms: ['medicine', 'drug', 'pharmacy'],
          medical: true),
      SidebarItem(Icons.tips_and_updates_rounded, (t) => t.healthTipsTitle,
          (_) => const HealthTipsScreen(),
          synonyms: ['health', 'tips', 'wellness'],
          medical: true),
      // Health §10: #69 timeline + #71 wellness; #173 challenges; #72 fitness.
      SidebarItem(Icons.timeline_rounded, (t) => t.htlTitle,
          (_) => const HealthTimelineScreen(),
          synonyms: ['health', 'timeline', 'record', 'history', 'medical'],
          medical: true),
    ]),
    // 8. Travel & city — svcclean
    SidebarSection('travel', Icons.directions_bus_rounded,
        (t) => t.svcCatTravel, [
      // cityapp (owner 9 Nov 11:45): City Service — which bus, metro gate, fares
      SidebarItem(Icons.directions_bus_rounded, (t) => t.cityTitle,
          feature: 'city_service',
          (_) => const CityServiceScreen(),
          synonyms: ['city service', 'which bus', 'bus route', 'metro', 'fare']),
      SidebarItem(Icons.place_rounded, (t) => t.sidebarNearby,
          feature: 'nearby',
          (_) => const NearbyScreen(),
          synonyms: ['nearby', 'around me', 'places']),
      // train (owner priority C): crowd live trains + estimate + 16318 SMS + chat
      SidebarItem(Icons.train_rounded, (t) => t.sjlNameTrain, // sjlive: one name
          feature: 'train_tracker',
          (_) => const TrainTrackerScreen(),
          synonyms: ['train', 'rail', 'trainkothai', 'where is my train', 'tren',
              'rel', '16318']),
      // train: destination alarm (offline geofence, loud on silent)
      SidebarItem(Icons.alarm_on_rounded, (t) => t.sjlNameAlarm, // sjlive: one name
          feature: 'dest_alarm',
          (_) => const DestAlarmScreen(),
          synonyms: ['destination alarm', 'wake me', 'station alarm', 'stop alarm',
              'bus stop alarm', 'metro', 'launch', 'gonthobbo']),
      SidebarItem(Icons.directions_car_rounded, (t) => t.rideFoodTitle,
          feature: 'ride_food',
          (_) => const RideFoodScreen(),
          synonyms: ['ride', 'food', 'uber', 'pathao', 'foodpanda', 'delivery']),
      SidebarItem(Icons.luggage_rounded, (t) => t.tvTitle,
          feature: 'travel_planner',
          (_) => const TravelPlannerScreen(),
          synonyms: ['travel', 'trip', 'itinerary', 'tour', 'journey', 'vacation']),
      SidebarItem(Icons.travel_explore_rounded, (t) => t.unseenTitle,
          tile: (t) => t.svcTileUnseen, // svcclean
          feature: 'unseen_bangladesh',
          (_) => const UnseenWorldScreen(),
          synonyms: ['unseen', 'travel', 'explore']),
    ]),
    // 9. Home & life — svcclean
    SidebarSection('home_life', Icons.home_work_rounded,
        (t) => t.svcCatHomeLife, [
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
          tile: (t) => t.svcTileStaff, // svcclean
          feature: 'domestic_staff',
          (_) => const DomesticStaffScreen(),
          synonyms: ['staff', 'maid', 'driver', 'cook', 'salary', 'household']),
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
      // flag-itag: Bluetooth iTag on keys / bag (ring it, left behind, find phone)
      SidebarItem(Icons.key_rounded, (t) => t.itgTitle,
          feature: 'itag_tags',
          (_) => const ItagScreen(),
          synonyms: ['itag', 'bluetooth tag', 'key finder', 'find my keys',
              'airtag', 'smart tag', 'chabi', 'left behind', 'find my phone']),
      SidebarItem(Icons.celebration_rounded, (t) => t.weddingTitle,
          feature: 'wedding_events',
          (_) => const WeddingEventsScreen(),
          synonyms: ['wedding', 'event', 'guest', 'biye', 'party', 'anniversary']),
      SidebarItem(Icons.flight_takeoff_rounded, (t) => t.probashiTitle,
          feature: 'probashi',
          (_) => const ProbashiScreen(),
          synonyms: ['probashi', 'expat', 'remittance', 'abroad', 'foreign']),
      // #199 Farmer / village mode — large-touch farm ledger + crop calendar.
      SidebarItem(Icons.agriculture_rounded, (t) => t.farmerTitle,
          feature: 'farmer_mode',
          (_) => const FarmerModeScreen(),
          synonyms: ['farmer', 'village', 'crop', 'livestock', 'krishi', 'chash']),
    ]),
    // 10. Faith — svcclean
    SidebarSection('faith', Icons.mosque_rounded,
        (t) => t.svcCatFaith, [
      // p3faith (flag quran, default OFF): offline Quran — Tanzil Arabic +
      // Pickthall English; Bangla awaits a licence; no ads.
      SidebarItem(Icons.menu_book_rounded, (t) => t.quranTitle,
          feature: 'quran',
          (_) => const QuranScreen(),
          synonyms: ['quran', 'koran', 'surah', 'sura', 'ayat', 'tilawat']),
      // quranread (flag quran_learn, default OFF): learn to read Quran in the
      // Noorani order; EXPERIMENTAL until a Qari reviews; no ads.
      SidebarItem(Icons.school_rounded, (t) => t.qlTitle,
          tile: (t) => t.svcTileLearnQuran, // svcclean
          feature: 'quran_learn',
          (_) => const QuranLearnScreen(),
          synonyms: ['qaida', 'noorani', 'nurani', 'learn quran', 'arabic letters', 'tajweed', 'nazera']),
      SidebarItem(Icons.nightlight_rounded, (t) => t.ramadanTitle,
          feature: 'ramadan',
          (_) => const RamadanScreen(),
          synonyms: ['prayer', 'ramadan', 'namaz', 'roza']),
      SidebarItem(Icons.mosque_rounded, (t) => t.qurbaniTitle,
          tile: (t) => t.svcTileQurbani, // svcclean
          feature: 'qurbani',
          (_) => const QurbaniScreen(),
          synonyms: ['qurbani', 'eid', 'korbani', 'sacrifice', 'animal share']),
    ]),
    // 11. Today & news — svcclean
    SidebarSection('today', Icons.wb_sunny_rounded,
        (t) => t.svcCatToday, [
      // p4-world: Daily info and services (was "Unseen World", renamed
      // 27 Oct) — Today cards, web answers, jobs, hubs. Flag `daily_info`.
      SidebarItem(Icons.public_rounded, (t) => t.dailyInfoTitle,
          tile: (t) => t.svcTileDailyInfo, // svcclean
          feature: 'daily_info',
          (_) => const WorldHubScreen(),
          synonyms: ['daily info', 'services', 'world news', 'today', 'news', 'weather', 'prayer time',
              'currency', 'gold price', 'fuel price', 'jobs', 'expat', 'visa',
              'bcs', 'farmer', 'crop', 'passport', 'nid', 'prescription',
              'web search', 'ask anything']),
      SidebarItem(Icons.radar_rounded, (t) => t.watchFeed2,
          feature: 'watch_feed',
          (_) => const WatchFeedScreen(),
          synonyms: ['watch', 'feed', 'alerts']),
      // §6/§8 key-gated-mock: #7 daily brief, #29 doc scanner, #92 transcription,
      // #35 travel planner.
      SidebarItem(Icons.wb_sunny_rounded, (t) => t.dbTitle,
          feature: 'daily_brief',
          (_) => const DailyBriefScreen(),
          synonyms: ['brief', 'morning', 'night', 'digest', 'summary', 'today']),
      // Wave-D batch-4: BD-specific disaster & weather warnings (cyclone / flood
      // / heatwave / earthquake), official sources only. Also chat-openable via
      // ChatNav route 'disaster'.
      SidebarItem(Icons.cyclone_rounded, (t) => t.disTitle,
          feature: 'disaster_alerts',
          (_) => const DisasterAlertsScreen(),
          synonyms: ['disaster', 'cyclone', 'flood', 'warning', 'earthquake',
              'weather warning']),
      SidebarItem(Icons.lightbulb_outline_rounded, (t) => t.proTitle,
          feature: 'proactive_ai',
          (_) => const ProactiveAiScreen(),
          synonyms: ['proactive', 'suggestions', 'nudges', 'ai', 'digest']),
      SidebarItem(Icons.account_balance_rounded, (t) => t.serviceGuide,
          feature: 'service_guide',
          (_) => const GuideScreen(),
          synonyms: ['government', 'service', 'guide']),
      // f6 (no showpieces): a "neighbourhood board" whose posts no neighbour
      // can see (per-user collection) — hidden until a moderated shared feed
      // exists on the server.
      if (kAreaBoardShared)
        SidebarItem(Icons.holiday_village_rounded, (t) => t.areaCommunityTitle,
            tile: (t) => t.svcTileCommunity, // svcclean
            feature: 'area_community',
            (_) => const AreaCommunityScreen(),
            synonyms: ['area', 'community', 'neighbourhood', 'local', 'notice board']),
    ]),
    // 12. Tools — svcclean
    SidebarSection('tools', Icons.handyman_rounded,
        (t) => t.svcCatTools, [
      SidebarItem(Icons.lock_outline_rounded, (t) => t.moduleVault,
          feature: 'documents',
          (_) => const VaultScreen(),
          synonyms: ['document', 'vault', 'file', 'nid', 'passport']),
      SidebarItem(Icons.document_scanner_rounded, (t) => t.dsTitle,
          feature: 'doc_scanner',
          (_) => const DocScannerScreen(),
          synonyms: ['document', 'scan', 'scanner', 'nid', 'passport', 'ocr']),
      SidebarItem(Icons.graphic_eq_rounded, (t) => t.tnTitle,
          tile: (t) => t.svcTileVoiceNotes, // svcclean
          feature: 'transcription',
          (_) => const TranscriptionScreen(),
          synonyms: ['transcription', 'voice note', 'transcribe', 'recording']),
      // ps1-photo: Photo Studio — one-tap AI enhance + edit/generate by prompt.
      // It REPLACES the old enhance tool (owner order): one entry, one ad rule.
      SidebarItem(Icons.auto_awesome_rounded, (t) => t.psTitle,
          feature: 'photo_studio',
          (_) => const PhotoStudioScreen(),
          synonyms: ['photo studio', 'edit photo', 'background', 'passport photo',
              'ai photo', 'beauty', 'retouch', 'photo', 'enhance', 'image']),
      // p2tools (flag daily_tools, default OFF): offline calculators and
      // converters for BD daily life (bigha/katha, bhori, EMI, zakat, dates).
      SidebarItem(Icons.calculate_rounded, (t) => t.dtDrawer,
          feature: 'daily_tools',
          (_) => const DailyToolsScreen(),
          synonyms: ['calculator', 'converter', 'unit', 'bigha', 'katha',
              'bhori', 'emi', 'zakat', 'age', 'bmi', 'hijri', 'timer', 'qr',
              'dice', 'word count']),
      SidebarItem(Icons.menu_book_rounded, (t) => t.dictionaryTitle,
          feature: 'dictionary',
          (_) => const DictionaryScreen(),
          synonyms: ['dictionary', 'word', 'meaning']),
      // #30 Contract analyzer + #132 language-learning partner (key-gated mock).
      SidebarItem(Icons.gavel_rounded, (t) => t.caTitle,
          feature: 'contract_analyzer',
          (_) => const ContractAnalyzerScreen(),
          synonyms: ['contract', 'agreement', 'analyze', 'clause', 'legal helper']),
      SidebarItem(Icons.graphic_eq_rounded, (t) => t.vaTitle,
          feature: 'voice_assistant',
          (_) => const VoiceAssistantScreen(),
          synonyms: ['voice assistant', 'assistant', 'hey assisto', 'voice',
              'talk', 'speak', 'alarm', 'torch', 'flashlight']),
    ]),
    // 13. Shopping — svcclean
    SidebarSection('shopping', Icons.local_mall_rounded,
        (t) => t.svcCatShopping, [
      // Part 3: Assisto Voice — hands-free assistant (calls, alarms, torch,
      // YouTube, maps, reminders, expenses, SOS — outgoing always confirmed).
      // amarket (flag assisto_market, default OFF): buyers post a need,
      // verified sellers send sealed offers; COD only, Dhaka only.
      SidebarItem(Icons.local_mall_rounded, (t) => t.amkTitle,
          feature: 'assisto_market',
          (_) => const MarketScreen(),
          synonyms: ['market', 'marketplace', 'reverse auction', 'bid', 'offer',
              'group buy', 'buy together', 'wholesale', 'seller']),
      // bizai: chats with shops (their AI sales assistant answers in seconds)
      SidebarItem(Icons.storefront_rounded, (t) => t.bizaiMyShopsTitle,
          feature: 'business_agent',
          (_) => const MyShopsScreen(),
          synonyms: ['shop', 'shop chat', 'store', 'order', 'dokan', 'kena']),
      SidebarItem(Icons.mark_chat_unread_outlined, (t) => t.rtInboxTitle,
          tile: (t) => t.svcTileShopMsgs, // svcclean
          feature: 'retention_auto',
          (_) => const RetentionInboxScreen(),
          synonyms: ['shop messages', 'messages from shops', 'store messages']),
      SidebarItem(Icons.trending_up_rounded, (t) => t.priceTitle,
          tile: (t) => t.svcTilePriceRadar, // svcclean
          feature: 'price_radar',
          (_) => const PriceRadarScreen(),
          synonyms: ['price', 'radar', 'market', 'bazar', 'rate']),
    ]),
    // 14. Jobs & learning — svcclean
    SidebarSection('learning', Icons.school_rounded,
        (t) => t.svcCatLearn, [
      SidebarItem(Icons.work_outline_rounded, (t) => t.jobHunter,
          feature: 'jobs',
          (_) => const JobsScreen(),
          synonyms: ['job', 'hunter', 'career']),
      SidebarItem(Icons.description_rounded, (t) => t.cvTitle,
          feature: 'cv_builder',
          (_) => const CvBuilderScreen(),
          synonyms: ['cv', 'resume', 'bio data', 'biodata', 'curriculum vitae']),
      SidebarItem(Icons.record_voice_over_rounded, (t) => t.miTitle,
          feature: 'mock_interview',
          (_) => const MockInterviewScreen(),
          synonyms: ['interview', 'mock', 'practice', 'job prep', 'viva']),
      // Section-20 life modules (SPEC v2.1 §20) — Daily Life group.
      SidebarItem(Icons.school_rounded, (t) => t.studentTitle,
          feature: 'student_corner',
          (_) => const StudentCornerScreen(),
          synonyms: ['student', 'routine', 'cgpa', 'gpa', 'assignment', 'exam']),
      SidebarItem(Icons.school_rounded, (t) => t.examTitle,
          feature: 'exam_result',
          (_) => const ExamResultScreen(),
          synonyms: ['exam', 'result', 'ssc', 'hsc']),
      // learncert: Assisto learning certificates (flag learning_certificate, OFF)
      SidebarItem(Icons.workspace_premium_rounded, (t) => t.lcTitle,
          tile: (t) => t.svcTileCerts, // svcclean
          feature: 'learning_certificate',
          (_) => const LearnCertScreen(),
          synonyms: ['certificate', 'certificates', 'verify', 'qr', 'course', 'quran']),
      SidebarItem(Icons.translate_rounded, (t) => t.lpTitle,
          feature: 'language_partner',
          (_) => const LanguagePartnerScreen(),
          synonyms: ['language', 'learn', 'english', 'vocabulary', 'practice']),
      SidebarItem(Icons.quiz_rounded, (t) => t.chalTitle,
          feature: 'daily_challenges',
          (_) => const DailyChallengesScreen(),
          synonyms: ['challenge', 'quiz', 'daily', 'streak', 'game']),
    ]),
    // 15. Work
    SidebarSection('work', Icons.work_outline_rounded,
        (t) => t.sidebarWork, [
      // f6 (no showpieces): Agent Studio automations never fire yet (and its
      // social composer labels template drafts "AI-generated"), so the entry
      // is hidden until automations really run.
      // agent-core WP-APP: hidden behind flag agent_core (owner / staff /
      // allow-listed testers see it with the Preview tag while OFF).
      SidebarItem(Icons.smart_toy_outlined, (t) => t.acTitle,
          feature: 'agent_core',
          (_) => const AgentCoreScreen(),
          synonyms: ['agent', 'goal', 'approval', 'assisto agent']),
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
      // p2plan (owner PART 2): today's time-blocked plan from tasks + PS
      // meetings + reminders + bills (+ prayer times). Flag OFF until proven.
      SidebarItem(Icons.today_rounded, (t) => t.p2DayPlanner,
          feature: 'ai_daily_planner',
          (_) => const DayPlannerScreen(),
          synonyms: ['planner', 'plan my day', 'daily plan', 'time block', 'schedule today']),
      SidebarItem(Icons.mark_email_unread_rounded, (t) => t.aiInbox,
          feature: 'ai_inbox',
          (_) => const InboxScreen(),
          synonyms: ['inbox', 'ai inbox', 'mail']),
      // PA Secretary — SPEC §14 / §4. Section 14 core (schedule, meeting brief,
      // visitor filter, liaison, personal tasks, delegate access) now ships, so
      // this opens the PA hub.
      SidebarItem(Icons.support_agent_rounded, (t) => t.sidebarPersonalSecretary,
          tile: (t) => t.svcTileSecretary, // svcclean
          feature: 'pa_secretary',
          (_) => const PaHubScreen(),
          synonyms: ['pa', 'secretary', 'personal assistant', 'pa mode']),
      // #17 Quick tools + #130 blog & script writer (key-gated AI mock).
      SidebarItem(Icons.bolt_rounded, (t) => t.qtTitle,
          feature: 'quick_tools',
          (_) => const QuickToolsScreen(),
          synonyms: ['quick', 'tools', 'summarise', 'grammar', 'translate', 'tone']),
      SidebarItem(Icons.article_rounded, (t) => t.bwTitle,
          tile: (t) => t.svcTileBlog, // svcclean
          feature: 'blog_writer',
          (_) => const BlogWriterScreen(),
          synonyms: ['blog', 'script', 'writing', 'post', 'caption', 'draft']),
      // #36 Cost/time estimator + #131 mock interview (key-gated mock).
      SidebarItem(Icons.calculate_rounded, (t) => t.ceTitle,
          tile: (t) => t.svcTileEstimator, // svcclean
          feature: 'cost_estimator',
          (_) => const CostEstimatorScreen(),
          synonyms: ['estimate', 'cost', 'time', 'quote', 'budget estimate']),
    ]),
    // 16. Business
    SidebarSection('business', Icons.storefront_rounded,
        (t) => t.myBusinessTitle, [
      SidebarItem(Icons.storefront_rounded, (t) => t.myBusinessTitle,
          area: AcctArea.business,
          feature: 'business',
          (_) => const BusinessScreen(),
          synonyms: ['business', 'shop', 'store', 'orders']),
      SidebarItem(Icons.insights_rounded, (t) => t.crmTitle,
          area: AcctArea.business,
          feature: 'crm',
          (_) => const CrmHomeScreen(),
          synonyms: ['crm', 'sales', 'leads', 'pipeline']),
      // booking-bot: the business' services, hours, link and bookings.
      SidebarItem(Icons.edit_calendar_rounded, (t) => t.bkgSidebarBiz,
          tile: (t) => t.svcTileBizBookings, // svcclean
          area: AcctArea.business,
          feature: 'booking_bot',
          (_) => const BookingBizScreen(),
          synonyms: ['booking', 'appointment', 'slot', 'salon', 'chamber', 'serial', 'calendar']),
      // retention1: Retention automation for the shop owner (flag
      // retention_auto) and, for everyone, the messages shops sent them.
      SidebarItem(Icons.autorenew_rounded, (t) => t.rtTitle,
          tile: (t) => t.svcTileRetention, // svcclean
          area: AcctArea.business,
          feature: 'retention_auto',
          (_) => const RetentionScreen(),
          synonyms: ['retention', 'automation', 'win back', 'winback', 'thank you',
              'review', 'birthday wish', 'back in stock', 'due reminder', 'follow up',
              'reorder', 'refill reminder', 'delivery feedback', 'rating', 'quote follow up',
              'customer score', 'lead score', 'activity log']),
      // mktengine: Marketing Engine v1 (flag marketing_engine, shop owner)
      SidebarItem(Icons.campaign_rounded, (t) => t.mktTitle,
          area: AcctArea.business,
          feature: 'marketing_engine',
          (_) => const MktEngineScreen(),
          synonyms: ['marketing', 'marketing engine', 'marketing plan', 'content calendar',
              'facebook post', 'post ideas', 'reels ideas', 'caption', 'campaign', 'festival post',
              'eid offer', 'boishakh offer', 'ad budget', 'follow up sequence']),
      // Part 4: Shop Box / CCTV loss-prevention (Business tier). Signals-only,
      // privacy-first: NO video. ChatNav route 'shop_box'.
      // svcclean: Shop Box (shop CCTV loss prevention) is a business tool —
      // in Business, so Family & Safety keeps exactly 8 tiles.
      SidebarItem(Icons.storefront_rounded, (t) => t.shopBoxTitle,
          feature: 'cctv_watchman',
          (_) => const ShopBoxScreen(),
          synonyms: ['shop box', 'cctv', 'camera', 'loss prevention',
              'shop security', 'theft', 'churi', 'dokan', 'store camera',
              'surveillance', 'alert camera']),
    ]),
  ];

  /// Returns sections (with items) matching [query]. Empty query -> [all].
  /// Matches the section TITLE, each item LABEL (localized bn OR en), and each
  /// item's ASCII [SidebarItem.synonyms]. Integrator uses this for the search box.
  static List<SidebarSection> filter(AppLocalizations t, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    final out = <SidebarSection>[];
    for (final s in allModes) {
      if (s.title(t).toLowerCase().contains(q)) {
        out.add(s);
        continue;
      }
      final hits = s.items.where((i) {
        if (i.label(t).toLowerCase().contains(q)) return true;
        // svcclean: the short tile name and the sections inside a tile
        if (i.tileLabel(t).toLowerCase().contains(q)) return true;
        if (i.alsoLabels.any((l) => l(t).toLowerCase().contains(q))) return true;
        return i.synonyms.any((syn) => syn.contains(q) || q.contains(syn));
      }).toList();
      if (hits.isNotEmpty) {
        out.add(SidebarSection(s.id, s.icon, s.title, hits));
      }
    }
    return out;
  }
}
